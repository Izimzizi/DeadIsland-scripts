local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks

local config = {
    blockMinForwardDistance = 10.0,    -- Minimum forward distance (cm)
    blockMaxForwardDistance = 40.0,    -- Maximum forward distance (cm)
    blockMaxRadialDistance = 30.0,     -- Max distance from center line (cm)
    requirePalmOutward = true,         -- Hand must face away from HMD
    palmDotThreshold = 0.0,            -- How strict the palm check is (more negative = stricter)
    blockHand = Handed.Left,           -- Primary blocking hand
    enableTwoHandedBlock = false,      -- If true, requires BOTH hands in position
    twoHandedMaxDistance = 25.0,       -- Max distance between hands for two-handed block (cm)
    showDebugWindow = false,           -- Show real-time distance values in GUI
}

local blockState = {
    isBlocking = false,
    wasBlocking = false,
    isTwoHandedBlock = false,
    lastForwardDistance = 0,
    lastRadialDistance = 0,
    lastPalmDot = 0,
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

local function quatToUp(quat)
    local x = quat.x
    local y = quat.y
    local z = quat.z
    local w = quat.w
    
    return {
        x = 2 * (x*y - w*z),
        y = 1 - 2 * (x*x + z*z),
        z = 2 * (y*z + w*x)
    }
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function checkHandBlocking(hand_index, hmd_pos, hmd_rot, hmd_forward, debugPrefix)
    if hand_index == -1 then
        return false
    end
    
    local hand_pos = UEVR_Vector3f.new()
    local hand_rot = UEVR_Quaternionf.new()
    vr.get_pose(hand_index, hand_pos, hand_rot)
    
    local offset = {
        x = hand_pos.x - hmd_pos.x,
        y = hand_pos.y - hmd_pos.y,
        z = hand_pos.z - hmd_pos.z
    }
    
    local forwardDistance = dot(offset, hmd_forward) * -100
    
    local forwardProjection = {
        x = hmd_forward.x * dot(offset, hmd_forward),
        y = hmd_forward.y * dot(offset, hmd_forward),
        z = hmd_forward.z * dot(offset, hmd_forward)
    }
    
    local radial = {
        x = offset.x - forwardProjection.x,
        y = offset.y - forwardProjection.y,
        z = offset.z - forwardProjection.z
    }
    
    local radialDistance = math.sqrt(radial.x*radial.x + radial.y*radial.y + radial.z*radial.z) * 100
    
    blockState.lastForwardDistance = forwardDistance
    blockState.lastRadialDistance = radialDistance

    if forwardDistance < config.blockMinForwardDistance or forwardDistance > config.blockMaxForwardDistance then
        return false
    end
    
    if radialDistance > config.blockMaxRadialDistance then
        return false
    end
    
    if config.requirePalmOutward then
        local hand_up = quatToUp(hand_rot)
        local palmDot = dot(hand_up, hmd_forward)
        
        blockState.lastPalmDot = palmDot
        
        if palmDot > config.palmDotThreshold then
            return false
        end
    end

    return true
end

local function detectBlockGesture()
    local hmd_index = vr.get_hmd_index()
    
    if hmd_index == -1 then
        return false
    end
    
    local hmd_pos = UEVR_Vector3f.new()
    local hmd_rot = UEVR_Quaternionf.new()
    vr.get_pose(hmd_index, hmd_pos, hmd_rot)
    
    local hmd_forward = quatToForward(hmd_rot)
    
    if config.enableTwoHandedBlock then
        -- TWO-HANDED BLOCKING MODE
        local left_index = vr.get_left_controller_index()
        local right_index = vr.get_right_controller_index()
        
        local leftBlocking = checkHandBlocking(left_index, hmd_pos, hmd_rot, hmd_forward, "LEFT")
        local rightBlocking = checkHandBlocking(right_index, hmd_pos, hmd_rot, hmd_forward, "RIGHT")
        
        if leftBlocking and rightBlocking then
            if config.twoHandedMaxDistance > 0 then
                local left_pos = UEVR_Vector3f.new()
                local left_rot = UEVR_Quaternionf.new()
                vr.get_pose(left_index, left_pos, left_rot)
                
                local right_pos = UEVR_Vector3f.new()
                local right_rot = UEVR_Quaternionf.new()
                vr.get_pose(right_index, right_pos, right_rot)
                
                local dx = (left_pos.x - right_pos.x) * 100
                local dy = (left_pos.y - right_pos.y) * 100
                local dz = (left_pos.z - right_pos.z) * 100
                local handDistance = math.sqrt(dx*dx + dy*dy + dz*dz)
                
                if handDistance > config.twoHandedMaxDistance then
                    return false
                end
            end
            
            blockState.isTwoHandedBlock = true
            return true
        end
        
        blockState.isTwoHandedBlock = false
        return false
        
    else
        -- SINGLE-HANDED BLOCKING MODE
        local hand_index = config.blockHand == Handed.Left and vr.get_left_controller_index() or vr.get_right_controller_index()
        blockState.isTwoHandedBlock = false
        return checkHandBlocking(hand_index, hmd_pos, hmd_rot, hmd_forward, config.blockHand == Handed.Left and "LEFT" or "RIGHT")
    end
end

callbacks.on_xinput_get_state(function(retval, user_index, state)
    if not state then
        return
    end
    
    local gestureActive = detectBlockGesture()
    
    blockState.isBlocking = gestureActive
    
    if gestureActive and not blockState.wasBlocking then
        if blockState.isTwoHandedBlock then
            print("[Block] TWO-HANDED BLOCKING ACTIVATED")
        else
            print("[Block] BLOCKING ACTIVATED")
        end
    elseif not gestureActive and blockState.wasBlocking then
        print("[Block] BLOCKING DEACTIVATED")
    end
    
    blockState.wasBlocking = gestureActive
    
    if gestureActive then
        state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_LEFT_SHOULDER
    end
end)

-- ImGui Configuration Window
uevr.lua.add_script_panel("Gesture based blocking", function()
    
    imgui.text("=== BLOCKING MODE ===")
    
    local twoHandedChanged, twoHandedValue = imgui.checkbox("Two-Handed Block", config.enableTwoHandedBlock)
    if twoHandedChanged then
        config.enableTwoHandedBlock = twoHandedValue
        print(string.format("[Block] Two-handed mode: %s", twoHandedValue and "ENABLED" or "DISABLED"))
    end
    
    if not config.enableTwoHandedBlock then
        imgui.text("Block Hand:")
        
        local handOptions = {"Left", "Right"}
        local currentHandIndex = config.blockHand == Handed.Left and 1 or 2
        
        local handChanged, newHandIndex = imgui.combo("##BlockHand", currentHandIndex, handOptions)
        if handChanged then
            config.blockHand = newHandIndex == 1 and Handed.Left or Handed.Right
            print(string.format("[Block] Block hand: %s", newHandIndex == 1 and "LEFT" or "RIGHT"))
        end
    end
    
    imgui.spacing()
    imgui.separator()
    imgui.spacing()
    
    imgui.text("=== DISTANCE SETTINGS ===")
    
    imgui.text("Forward Distance (how far in front of face)")
    local minForwardChanged, minForwardValue = imgui.drag_float("Min Forward (cm)", config.blockMinForwardDistance, 1.0, 5.0, 100.0)
    if minForwardChanged then
        config.blockMinForwardDistance = minForwardValue
    end
    
    local maxForwardChanged, maxForwardValue = imgui.drag_float("Max Forward (cm)", config.blockMaxForwardDistance, 1.0, 5.0, 100.0)
    if maxForwardChanged then
        config.blockMaxForwardDistance = maxForwardValue
    end
    
    imgui.spacing()
    
    imgui.text("Radial Distance (left/right/up/down from center)")
    local maxRadialChanged, maxRadialValue = imgui.drag_float("Max Radial (cm)", config.blockMaxRadialDistance, 1.0, 5.0, 100.0)
    if maxRadialChanged then
        config.blockMaxRadialDistance = maxRadialValue
    end
    
    if config.enableTwoHandedBlock then
        imgui.spacing()
        imgui.text("Two-Handed Settings")
        local maxHandDistChanged, maxHandDistValue = imgui.drag_float("Max Hand Distance (cm)", config.twoHandedMaxDistance, 1.0, 0.0, 100.0)
        if maxHandDistChanged then
            config.twoHandedMaxDistance = maxHandDistValue
        end
    end
    
    imgui.spacing()
    imgui.separator()
    imgui.spacing()
    
    imgui.text("=== PALM ORIENTATION ===")
    
    local palmCheckChanged, palmCheckValue = imgui.checkbox("Require Palm Outward", config.requirePalmOutward)
    if palmCheckChanged then
        config.requirePalmOutward = palmCheckValue
    end
    
    if config.requirePalmOutward then
        local palmThresholdChanged, palmThresholdValue = imgui.drag_float("Palm Threshold", config.palmDotThreshold, 0.01, -1.0, 1.0)
        if palmThresholdChanged then
            config.palmDotThreshold = palmThresholdValue
        end
        imgui.text("(More negative = stricter palm check)")
    end
    
    imgui.spacing()
    imgui.separator()
    imgui.spacing()
    
    imgui.text("=== DEBUG OPTIONS ===")
    
    local debugWindowChanged, debugWindowValue = imgui.checkbox("Show Debug Window", config.showDebugWindow)
    if debugWindowChanged then
        config.showDebugWindow = debugWindowValue
    end
    
    imgui.spacing()
    imgui.separator()
    imgui.spacing()
    
    -- Quick Presets
    imgui.text("=== QUICK PRESETS ===")
    
    if imgui.button("Default") then
        config.blockMinForwardDistance = 10.0
        config.blockMaxForwardDistance = 40.0
        config.blockMaxRadialDistance = 30.0
        config.requirePalmOutward = true
        config.palmDotThreshold = 0.0 
        config.blockHand = Handed.Left 
        config.twoHandedMaxDistance = 25.0 
        config.enableTwoHandedBlock = false
        config.showDebugWindow = false
        print("[Block] Preset: Default")
    end
    
    imgui.same_line()
    
    if imgui.button("Tight Block (Close Range)") then
        config.blockMinForwardDistance = 10.0
        config.blockMaxForwardDistance = 30.0
        config.blockMaxRadialDistance = 20.0
        config.requirePalmOutward = true
        config.palmDotThreshold = -0.2 
        config.twoHandedMaxDistance = 25.0 
        print("[Block] Preset: Tight Block")
    end
    
    imgui.same_line()
    
    if imgui.button("Loose Block (Wide Range)") then
        config.blockMinForwardDistance = 10.0
        config.blockMaxForwardDistance = 60.0
        config.blockMaxRadialDistance = 40.0
        config.requirePalmOutward = true
        config.palmDotThreshold = 0.2 
        config.twoHandedMaxDistance = 50.0 
        print("[Block] Preset: Loose Block")
    end
    
    -- Debug Window (if enabled)
    if config.showDebugWindow then
        imgui.begin_window("Blocking Debug Values", true, 0)
        
        imgui.text("=== REAL-TIME VALUES ===")
        imgui.text(string.format("Forward Distance: %.1f cm", blockState.lastForwardDistance))
        imgui.text(string.format("Radial Distance: %.1f cm", blockState.lastRadialDistance))
        imgui.text(string.format("Palm Dot: %.2f", blockState.lastPalmDot))
        
        imgui.spacing()
        imgui.separator()
        imgui.spacing()
        
        imgui.text("=== CURRENT THRESHOLDS ===")
        imgui.text(string.format("Forward Range: %.1f - %.1f cm", config.blockMinForwardDistance, config.blockMaxForwardDistance))
        imgui.text(string.format("Max Radial: %.1f cm", config.blockMaxRadialDistance))
        if config.requirePalmOutward then
            imgui.text(string.format("Palm Threshold: %.2f", config.palmDotThreshold))
        end
        

        imgui.end_window()
    end
end)