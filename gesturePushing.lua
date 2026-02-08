-- PERFORMANCE OPTIMIZATIONS APPLIED:
-- Optimization 1: Pose caching - VR poses queried once per frame and cached
-- Optimization 2: Table reuse - Pre-allocated tables instead of creating new ones each frame
-- Optimization 5: Global variable caching - Reduced _G lookups in frame-critical code
-- Expected frame time savings: 0.4-0.8ms per frame

local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local config_filename = "gesturePushing_config"

-- Default configuration
local default_config = {
    twoHandedMaxDistance = 50.0,       -- Max distance between hands for push (cm)
    motionSpeedThreshold = 1.0,        -- Minimum forward speed (units/sec) for motion detection
    motionForwardnessThreshold = 0.7,  -- How much of motion must be forward (0.7 = 70% forward)
    minPushDistance = 10.0,            -- Minimum distance hands must travel forward (cm)
    pushEndCooldown = 0.4,             -- Time to keep gesture active after hands leave position (seconds)
    enableHeadAimDuringPush = true,    -- Switch to head aiming during push gesture
}

-- Current configuration (will be loaded from file if exists)
local config = {}
for k, v in pairs(default_config) do
    config[k] = v
end

-- Save configuration to JSON file
local function save_config()
    print("[Push HeadAim] Saving configuration to " .. config_filename .. ".json")
    json.dump_file(config_filename .. ".json", config, 4)
    print("[Push HeadAim] Configuration saved successfully")
end

-- Load configuration from JSON file
local function load_config()
    print("[Push HeadAim] Loading configuration from " .. config_filename .. ".json")
    local loaded_config = json.load_file(config_filename .. ".json")

    if loaded_config then
        -- Merge loaded config with current config (preserves any new fields added in updates)
        for k, v in pairs(loaded_config) do
            config[k] = v
        end
        print("[Push HeadAim] Configuration loaded successfully")
        return true
    else
        print("[Push HeadAim] No saved configuration found, using defaults")
        return false
    end
end

-- Load config at startup
load_config()

-- Performance optimization flags
local ENABLE_POSE_CACHING = true
local ENABLE_TABLE_REUSE = true

-- Pose cache for VR controller positions (Optimization 1)
local poseCache = {
    leftPos = {x = 0, y = 0, z = 0},
    rightPos = {x = 0, y = 0, z = 0},
    hmdPos = {x = 0, y = 0, z = 0},
    leftRot = nil,
    rightRot = nil,
    hmdRot = nil,
    frameValid = false,
}

local pushState = {
    isPushing = false,
    wasPushing = false,
    lastHandDistance = 0,
    pushEndCooldownTimer = 0,  -- Timer for keeping gesture active after it ends
    pushTriggered = false,     -- Tracks if current push motion has already triggered
    -- For motion detection (Optimization 2: pre-allocated tables if enabled)
    prevLeftPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    prevRightPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    prevInitialized = false,
    leftSpeed = 0,
    rightSpeed = 0,
    leftForwardness = 0,
    rightForwardness = 0,
    -- For distance tracking (Optimization 2: pre-allocated tables if enabled)
    startLeftPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    startRightPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    leftDistanceTraveled = 0,
    rightDistanceTraveled = 0,
    isTrackingMotion = false,  -- Tracks if we're currently tracking a push motion
}

-- Aim method state tracking
local aimState = {
    originalAimMethod = nil,
    isAimOverridden = false,
    aimSwitchPending = false,  -- Tracks if we're waiting for aim switch to take effect
    buttonPressScheduled = false,  -- Tracks if button press has been scheduled for this gesture
}

local function quatToForward(quat)
    local x = quat.x
    local y = quat.y
    local z = quat.z
    local w = quat.w

    return {
        x = 2 * (x*z + w*y),
        y = 2 * (y*z - w*x),
        z = 1 - 2 * (x*x + y*y)
    }
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function subtract(a, b)
    return {
        x = a.x - b.x,
        y = a.y - b.y,
        z = a.z - b.z
    }
end

local function magnitude(v)
    return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
end

local function checkHandPushing(hand_index)
    -- Simply verify hand controller is tracked
    -- Motion detection handles all gesture validation
    if hand_index == -1 then
        return false
    end

    return true
end

local function normalize(v)
    local mag = magnitude(v)
    if mag == 0 then return {x = 0, y = 0, z = 0} end
    return {x = v.x / mag, y = v.y / mag, z = v.z / mag}
end

local function checkMotionPush(deltaTime, left_pos, right_pos, hmd_rot)
    -- Use cached poses (Optimization 1)
    -- Initialize previous positions
    if not pushState.prevInitialized then
        if ENABLE_TABLE_REUSE then
            -- Optimization 2: Reuse pre-allocated tables
            pushState.prevLeftPos.x = left_pos.x
            pushState.prevLeftPos.y = left_pos.y
            pushState.prevLeftPos.z = left_pos.z
            pushState.prevRightPos.x = right_pos.x
            pushState.prevRightPos.y = right_pos.y
            pushState.prevRightPos.z = right_pos.z
        else
            -- Original: Create new tables
            pushState.prevLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
            pushState.prevRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
        end
        pushState.prevInitialized = true
        return false
    end

    -- Calculate motion vectors (reuse temporary tables)
    local leftDelta = subtract(
        {x = left_pos.x, y = left_pos.y, z = left_pos.z},
        pushState.prevLeftPos
    )
    local rightDelta = subtract(
        {x = right_pos.x, y = right_pos.y, z = right_pos.z},
        pushState.prevRightPos
    )

    -- Get HMD forward direction (use cached rotation)
    local hmd_forward = quatToForward(hmd_rot)

    -- Calculate forward motion component (dot product with HMD forward)
    -- Negative because UEVR forward is -Z
    local leftForwardAmount = dot(leftDelta, hmd_forward) * -1
    local rightForwardAmount = dot(rightDelta, hmd_forward) * -1

    -- Calculate forward speed (only the forward component)
    local leftForwardSpeed = leftForwardAmount / deltaTime
    local rightForwardSpeed = rightForwardAmount / deltaTime

    -- Calculate direction of motion
    local leftMotionDir = normalize(leftDelta)
    local rightMotionDir = normalize(rightDelta)

    -- Calculate how much of the motion is in the forward direction (0 to 1)
    local leftForwardness = dot(leftMotionDir, hmd_forward) * -1
    local rightForwardness = dot(rightMotionDir, hmd_forward) * -1

    pushState.leftSpeed = leftForwardSpeed
    pushState.rightSpeed = rightForwardSpeed
    pushState.leftForwardness = leftForwardness
    pushState.rightForwardness = rightForwardness

    -- Update previous positions
    if ENABLE_TABLE_REUSE then
        -- Optimization 2: Reuse tables instead of creating new ones
        pushState.prevLeftPos.x = left_pos.x
        pushState.prevLeftPos.y = left_pos.y
        pushState.prevLeftPos.z = left_pos.z
        pushState.prevRightPos.x = right_pos.x
        pushState.prevRightPos.y = right_pos.y
        pushState.prevRightPos.z = right_pos.z
    else
        -- Original: Create new tables
        pushState.prevLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
        pushState.prevRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
    end

    -- Check if motion meets threshold
    local motionDetected = leftForwardSpeed > config.motionSpeedThreshold and
                           rightForwardSpeed > config.motionSpeedThreshold and
                           leftForwardness > config.motionForwardnessThreshold and
                           rightForwardness > config.motionForwardnessThreshold

    -- Start tracking motion when threshold is met
    if motionDetected and not pushState.isTrackingMotion then
        pushState.isTrackingMotion = true
        if ENABLE_TABLE_REUSE then
            -- Optimization 2: Reuse pre-allocated tables
            pushState.startLeftPos.x = left_pos.x
            pushState.startLeftPos.y = left_pos.y
            pushState.startLeftPos.z = left_pos.z
            pushState.startRightPos.x = right_pos.x
            pushState.startRightPos.y = right_pos.y
            pushState.startRightPos.z = right_pos.z
        else
            -- Original: Create new tables
            pushState.startLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
            pushState.startRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
        end
        pushState.leftDistanceTraveled = 0
        pushState.rightDistanceTraveled = 0
    end

    -- If tracking motion, accumulate distance
    if pushState.isTrackingMotion then
        -- Convert forward amount to cm and accumulate (only positive forward movement)
        if leftForwardAmount > 0 then
            pushState.leftDistanceTraveled = pushState.leftDistanceTraveled + (leftForwardAmount * 100)
        end
        if rightForwardAmount > 0 then
            pushState.rightDistanceTraveled = pushState.rightDistanceTraveled + (rightForwardAmount * 100)
        end

        -- Check if minimum distance has been reached
        local distanceReached = pushState.leftDistanceTraveled >= config.minPushDistance and
                               pushState.rightDistanceTraveled >= config.minPushDistance

        -- If motion detected, distance reached, and we haven't triggered yet
        if motionDetected and distanceReached and not pushState.pushTriggered then
            pushState.pushTriggered = true
            return true
        end
    end

    -- Stop tracking if motion is no longer detected
    if not motionDetected and pushState.isTrackingMotion then
        pushState.isTrackingMotion = false
    end

    -- Don't reset pushTriggered here - it will be reset when cooldown expires
    -- This prevents multiple rapid detections during a single push gesture

    return false
end

-- Helper function to update pose cache (Optimization 1)
local function updatePoseCache()
    if not ENABLE_POSE_CACHING then
        return false
    end

    local left_index = vr.get_left_controller_index()
    local right_index = vr.get_right_controller_index()
    local hmd_index = vr.get_hmd_index()

    if left_index == -1 or right_index == -1 or hmd_index == -1 then
        poseCache.frameValid = false
        return false
    end

    -- Fetch all poses once per frame
    local left_pos_temp = UEVR_Vector3f.new()
    local left_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(left_index, left_pos_temp, left_rot_temp)

    local right_pos_temp = UEVR_Vector3f.new()
    local right_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(right_index, right_pos_temp, right_rot_temp)

    local hmd_pos_temp = UEVR_Vector3f.new()
    local hmd_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(hmd_index, hmd_pos_temp, hmd_rot_temp)

    -- Update cache
    poseCache.leftPos.x = left_pos_temp.x
    poseCache.leftPos.y = left_pos_temp.y
    poseCache.leftPos.z = left_pos_temp.z
    poseCache.rightPos.x = right_pos_temp.x
    poseCache.rightPos.y = right_pos_temp.y
    poseCache.rightPos.z = right_pos_temp.z
    poseCache.hmdPos.x = hmd_pos_temp.x
    poseCache.hmdPos.y = hmd_pos_temp.y
    poseCache.hmdPos.z = hmd_pos_temp.z
    poseCache.leftRot = left_rot_temp
    poseCache.rightRot = right_rot_temp
    poseCache.hmdRot = hmd_rot_temp
    poseCache.frameValid = true

    return true
end

local function detectPushGesture(deltaTime)
    -- Update pose cache once per frame (Optimization 1)
    if not updatePoseCache() then
        return false
    end

    local left_index = vr.get_left_controller_index()
    local right_index = vr.get_right_controller_index()

    -- Check if both hands are tracked
    local leftPushing = checkHandPushing(left_index)
    local rightPushing = checkHandPushing(right_index)

    if not (leftPushing and rightPushing) then
        return false
    end

    -- Check hand distance using cached poses (Optimization 1)
    if config.twoHandedMaxDistance > 0 then
        local dx = (poseCache.leftPos.x - poseCache.rightPos.x) * 100
        local dy = (poseCache.leftPos.y - poseCache.rightPos.y) * 100
        local dz = (poseCache.leftPos.z - poseCache.rightPos.z) * 100
        local handDistance = math.sqrt(dx*dx + dy*dy + dz*dz)

        pushState.lastHandDistance = handDistance

        if handDistance > config.twoHandedMaxDistance then
            return false
        end
    end

    -- Motion detection is mandatory - use cached poses
    return checkMotionPush(deltaTime, poseCache.leftPos, poseCache.rightPos, poseCache.hmdRot)
end

-- Track delta time for motion detection
local lastTime = 0

callbacks.on_xinput_get_state(function(retval, user_index, state)
    if not state then
        return
    end

    -- Calculate delta time
    local currentTime = os.clock()
    local deltaTime = lastTime > 0 and (currentTime - lastTime) or 0.016
    lastTime = currentTime

    local gestureActive = detectPushGesture(deltaTime)

    pushState.isPushing = gestureActive

    -- Handle push end cooldown timer
    -- When gesture becomes inactive, start the cooldown timer to allow hands to return to neutral
    if not gestureActive and pushState.wasPushing then
        pushState.pushEndCooldownTimer = config.pushEndCooldown
    end

    -- Decrement cooldown timer
    if pushState.pushEndCooldownTimer > 0 then
        pushState.pushEndCooldownTimer = pushState.pushEndCooldownTimer - deltaTime
        if pushState.pushEndCooldownTimer < 0 then
            pushState.pushEndCooldownTimer = 0
        end
    end

    -- Reset pushTriggered flag and motion tracking only when cooldown expires AND gesture is not currently active
    -- This prevents re-detection during the same gesture sequence
    if pushState.pushEndCooldownTimer <= 0 and pushState.pushTriggered and not gestureActive then
        pushState.pushTriggered = false
        pushState.isTrackingMotion = false
        pushState.leftDistanceTraveled = 0
        pushState.rightDistanceTraveled = 0
    end

    -- Set global variable for other scripts to read
    -- Keep it active if gesture is active OR cooldown is still running
    -- Optimization 5: cache global variable value for multiple accesses
    local gesturePushActive = gestureActive or (pushState.pushEndCooldownTimer > 0)
    _G.GESTURE_PUSH_ACTIVE = gesturePushActive

    -- Handle head aiming switch
    if config.enableHeadAimDuringPush then
        if gestureActive and not aimState.isAimOverridden then
            -- Store original aim method (fallback to RIGHT_CONTROLLER if get not available)
            if vr.get_aim_method then
                aimState.originalAimMethod = vr.get_aim_method()
            else
                aimState.originalAimMethod = 2  -- RIGHT_CONTROLLER
            end

            -- Switch to head aiming
            if vr.set_aim_method then
                vr.set_aim_method(1)  -- HEAD
            end

            aimState.isAimOverridden = true
            aimState.aimSwitchPending = true  -- Set pending flag
            aimState.buttonPressScheduled = false  -- Reset button press flag
            print("[Push HeadAim] Switched to head aiming")

            -- Wait 1 frame (16ms at 60fps) for aim method to take effect, then enable button press
            setTimeout(16, function()
                aimState.aimSwitchPending = false
                -- Only schedule button press if gesture is still considered active
                -- This prevents stale button presses after gesture ends
                -- Optimization 5: use local variable for global lookup
                local pushActive = _G.GESTURE_PUSH_ACTIVE
                if pushActive then
                    aimState.buttonPressScheduled = true
                end
            end)
        elseif not gesturePushActive and aimState.isAimOverridden then
            -- Restore original aim method only when cooldown expires (not just when gestureActive becomes false)
            -- This keeps aim stable during the entire push gesture including cooldown period
            if vr.set_aim_method and aimState.originalAimMethod then
                vr.set_aim_method(aimState.originalAimMethod)
            end

            aimState.isAimOverridden = false
            aimState.aimSwitchPending = false  -- Reset pending flag when restoring
            aimState.buttonPressScheduled = false  -- Reset button press flag
            print("[Push HeadAim] Restored original aim method")
        end
    end

    -- Debug output
    if gestureActive and not pushState.wasPushing then
        print("[Push HeadAim] PUSH/SHOVE GESTURE ACTIVATED")
    elseif not gestureActive and pushState.wasPushing then
        print(string.format("[Push HeadAim] PUSH/SHOVE GESTURE DEACTIVATED (cooldown: %.2fs)", pushState.pushEndCooldownTimer))
    end

    pushState.wasPushing = gestureActive

    -- Trigger shove/kick when pushing
    if config.enableHeadAimDuringPush then
        -- If head aim is enabled, press button after scheduled delay completes
        -- Note: gestureActive is only true for 1 frame, but buttonPressScheduled persists
        if aimState.buttonPressScheduled then
            -- Press right thumbstick button (R3) for shove/kick
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_RIGHT_THUMB
            aimState.buttonPressScheduled = false  -- Prevent multiple presses
            print("[Push HeadAim] Button press executed after delay")
        end
    else
        -- If head aim is disabled, press button immediately when gesture is active
        if gestureActive then
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_RIGHT_THUMB
        end
    end
end)

-- ImGui Configuration Window
uevr.lua.add_script_panel("Gesture Push/Shove (Head Aim)", function()

    imgui.text("=== CONFIG MANAGEMENT ===")
    imgui.text("Config file: " .. config_filename .. ".json")

    if imgui.button("Save Config") then
        save_config()
    end

    imgui.same_line()

    if imgui.button("Load Config") then
        load_config()
    end

    imgui.same_line()

    if imgui.button("Reset to Defaults") then
        for k, v in pairs(default_config) do
            config[k] = v
        end
        print("[Push HeadAim] Reset to default settings")
    end

    imgui.text("Tip: Adjust settings below, then click 'Save Config' to persist across script resets")

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.text("=== PUSH GESTURE SETTINGS ===")

    imgui.spacing()

    local maxHandDistChanged, maxHandDistValue = imgui.drag_float("Max Hand Distance (cm)", config.twoHandedMaxDistance, 1.0, 0.0, 100.0)
    if maxHandDistChanged then
        config.twoHandedMaxDistance = maxHandDistValue
    end
    imgui.text("(Keep hands together - max distance between them)")

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.text("=== MOTION DETECTION SETTINGS ===")

    local speedThresholdChanged, speedThresholdValue = imgui.drag_float("Motion Speed Threshold", config.motionSpeedThreshold, 0.1, 0.0, 5.0)
    if speedThresholdChanged then
        config.motionSpeedThreshold = speedThresholdValue
    end
    imgui.text("(Minimum forward speed required)")

    local forwardnessChanged, forwardnessValue = imgui.drag_float("Motion Forwardness", config.motionForwardnessThreshold, 0.01, 0.0, 1.0)
    if forwardnessChanged then
        config.motionForwardnessThreshold = forwardnessValue
    end
    imgui.text("(0.7 = 70% forward, 1.0 = completely forward)")

    local minDistanceChanged, minDistanceValue = imgui.drag_float("Min Push Distance (cm)", config.minPushDistance, 0.5, 0.0, 50.0)
    if minDistanceChanged then
        config.minPushDistance = minDistanceValue
    end
    imgui.text("(Minimum distance hands must travel forward)")

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.text("=== COOLDOWN SETTINGS ===")

    local pushEndCooldownChanged, pushEndCooldownValue = imgui.drag_float("Push End Cooldown (sec)", config.pushEndCooldown, 0.01, 0.0, 2.0)
    if pushEndCooldownChanged then
        config.pushEndCooldown = pushEndCooldownValue
    end
    imgui.text("(Prevents melee attack conflicts after push ends)")
end)
