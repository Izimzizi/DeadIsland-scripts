local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local config_filename = "gesturePushing_config"

local default_config = {
    twoHandedMaxDistance = 50.0,       
    motionSpeedThreshold = 1.0,        
    motionForwardnessThreshold = 0.7,  
    minPushDistance = 10.0,            
    pushEndCooldown = 0.4,             
    enableHeadAimDuringPush = true,   
}

local config = {}
for k, v in pairs(default_config) do
    config[k] = v
end

local function save_config()
    json.dump_file(config_filename .. ".json", config, 4)
end

local function load_config()
    local loaded_config = json.load_file(config_filename .. ".json")

    if loaded_config then
        for k, v in pairs(loaded_config) do
            config[k] = v
        end
        return true
    else
        return false
    end
end

load_config()

local ENABLE_POSE_CACHING = true
local ENABLE_TABLE_REUSE = true

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
    pushEndCooldownTimer = 0,  
    pushTriggered = false,   
    prevLeftPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    prevRightPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    prevInitialized = false,
    leftSpeed = 0,
    rightSpeed = 0,
    leftForwardness = 0,
    rightForwardness = 0,
    startLeftPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    startRightPos = ENABLE_TABLE_REUSE and {x = 0, y = 0, z = 0} or nil,
    leftDistanceTraveled = 0,
    rightDistanceTraveled = 0,
    isTrackingMotion = false, 
}

local aimState = {
    originalAimMethod = 2,
    isAimOverridden = false,
    aimSwitchPending = false,  
    buttonPressScheduled = false, 
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
    if not pushState.prevInitialized then
        if ENABLE_TABLE_REUSE then
            pushState.prevLeftPos.x = left_pos.x
            pushState.prevLeftPos.y = left_pos.y
            pushState.prevLeftPos.z = left_pos.z
            pushState.prevRightPos.x = right_pos.x
            pushState.prevRightPos.y = right_pos.y
            pushState.prevRightPos.z = right_pos.z
        else
            pushState.prevLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
            pushState.prevRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
        end
        pushState.prevInitialized = true
        return false
    end

    local leftDelta = subtract(
        {x = left_pos.x, y = left_pos.y, z = left_pos.z},
        pushState.prevLeftPos
    )
    local rightDelta = subtract(
        {x = right_pos.x, y = right_pos.y, z = right_pos.z},
        pushState.prevRightPos
    )

    local hmd_forward = quatToForward(hmd_rot)

    local leftForwardAmount = dot(leftDelta, hmd_forward) * -1
    local rightForwardAmount = dot(rightDelta, hmd_forward) * -1

    local leftForwardSpeed = leftForwardAmount / deltaTime
    local rightForwardSpeed = rightForwardAmount / deltaTime

    local leftMotionDir = normalize(leftDelta)
    local rightMotionDir = normalize(rightDelta)

    local leftForwardness = dot(leftMotionDir, hmd_forward) * -1
    local rightForwardness = dot(rightMotionDir, hmd_forward) * -1

    pushState.leftSpeed = leftForwardSpeed
    pushState.rightSpeed = rightForwardSpeed
    pushState.leftForwardness = leftForwardness
    pushState.rightForwardness = rightForwardness

    if ENABLE_TABLE_REUSE then
        pushState.prevLeftPos.x = left_pos.x
        pushState.prevLeftPos.y = left_pos.y
        pushState.prevLeftPos.z = left_pos.z
        pushState.prevRightPos.x = right_pos.x
        pushState.prevRightPos.y = right_pos.y
        pushState.prevRightPos.z = right_pos.z
    else
        pushState.prevLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
        pushState.prevRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
    end

    local motionDetected = leftForwardSpeed > config.motionSpeedThreshold and
                           rightForwardSpeed > config.motionSpeedThreshold and
                           leftForwardness > config.motionForwardnessThreshold and
                           rightForwardness > config.motionForwardnessThreshold

    if motionDetected and not pushState.isTrackingMotion then
        pushState.isTrackingMotion = true
        if ENABLE_TABLE_REUSE then
            pushState.startLeftPos.x = left_pos.x
            pushState.startLeftPos.y = left_pos.y
            pushState.startLeftPos.z = left_pos.z
            pushState.startRightPos.x = right_pos.x
            pushState.startRightPos.y = right_pos.y
            pushState.startRightPos.z = right_pos.z
        else
            pushState.startLeftPos = {x = left_pos.x, y = left_pos.y, z = left_pos.z}
            pushState.startRightPos = {x = right_pos.x, y = right_pos.y, z = right_pos.z}
        end
        pushState.leftDistanceTraveled = 0
        pushState.rightDistanceTraveled = 0
    end

    if pushState.isTrackingMotion then
        if leftForwardAmount > 0 then
            pushState.leftDistanceTraveled = pushState.leftDistanceTraveled + (leftForwardAmount * 100)
        end
        if rightForwardAmount > 0 then
            pushState.rightDistanceTraveled = pushState.rightDistanceTraveled + (rightForwardAmount * 100)
        end

        local distanceReached = pushState.leftDistanceTraveled >= config.minPushDistance and
                               pushState.rightDistanceTraveled >= config.minPushDistance

        if motionDetected and distanceReached and not pushState.pushTriggered then
            pushState.pushTriggered = true
            return true
        end
    end

    if not motionDetected and pushState.isTrackingMotion then
        pushState.isTrackingMotion = false
    end

    return false
end

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

    local left_pos_temp = UEVR_Vector3f.new()
    local left_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(left_index, left_pos_temp, left_rot_temp)

    local right_pos_temp = UEVR_Vector3f.new()
    local right_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(right_index, right_pos_temp, right_rot_temp)

    local hmd_pos_temp = UEVR_Vector3f.new()
    local hmd_rot_temp = UEVR_Quaternionf.new()
    vr.get_pose(hmd_index, hmd_pos_temp, hmd_rot_temp)

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
    if not updatePoseCache() then
        return false
    end

    local left_index = vr.get_left_controller_index()
    local right_index = vr.get_right_controller_index()

    local leftPushing = checkHandPushing(left_index)
    local rightPushing = checkHandPushing(right_index)

    if not (leftPushing and rightPushing) then
        return false
    end

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

    return checkMotionPush(deltaTime, poseCache.leftPos, poseCache.rightPos, poseCache.hmdRot)
end

local lastTime = 0

callbacks.on_xinput_get_state(function(retval, user_index, state)
    if not state then
        return
    end

    local currentTime = os.clock()
    local deltaTime = lastTime > 0 and (currentTime - lastTime) or 0.016
    lastTime = currentTime

    local gestureActive = detectPushGesture(deltaTime)

    pushState.isPushing = gestureActive

    if not gestureActive and pushState.wasPushing then
        pushState.pushEndCooldownTimer = config.pushEndCooldown
    end

    if pushState.pushEndCooldownTimer > 0 then
        pushState.pushEndCooldownTimer = pushState.pushEndCooldownTimer - deltaTime
        if pushState.pushEndCooldownTimer < 0 then
            pushState.pushEndCooldownTimer = 0
        end
    end

    if pushState.pushEndCooldownTimer <= 0 and pushState.pushTriggered and not gestureActive then
        pushState.pushTriggered = false
        pushState.isTrackingMotion = false
        pushState.leftDistanceTraveled = 0
        pushState.rightDistanceTraveled = 0
    end

    local gesturePushActive = gestureActive or (pushState.pushEndCooldownTimer > 0)
    _G.GESTURE_PUSH_ACTIVE = gesturePushActive

    if config.enableHeadAimDuringPush then
        if gestureActive and not aimState.isAimOverridden then   

            if vr.set_aim_method then
                vr.set_aim_method(1)  
            end

            aimState.isAimOverridden = true
            aimState.aimSwitchPending = true  
            aimState.buttonPressScheduled = false  

            setTimeout(16, function()
                aimState.aimSwitchPending = false
                local pushActive = _G.GESTURE_PUSH_ACTIVE
                if pushActive then
                    aimState.buttonPressScheduled = true
                end
            end)
        elseif not gesturePushActive and aimState.isAimOverridden then
            if vr.set_aim_method then
                vr.set_aim_method(aimState.originalAimMethod)
            end

            aimState.isAimOverridden = false
            aimState.aimSwitchPending = false 
            aimState.buttonPressScheduled = false  
        end
    end

    pushState.wasPushing = gestureActive

    if config.enableHeadAimDuringPush then
        if aimState.buttonPressScheduled then
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_RIGHT_THUMB
            aimState.buttonPressScheduled = false  
        end
    else
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
