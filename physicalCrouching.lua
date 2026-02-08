local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local config_filename = "physicalCrouching_config"

local default_config = {
    crouchThreshold = 30.0,            
    standThreshold = 25.0,            
    debounceTime = 0.3,               
    heightSmoothingFrames = 5,       
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
        
        save_config()
        return false
    end
end

load_config()

local ENABLE_POSE_CACHING = true
local ENABLE_HEIGHT_SMOOTHING = true

local poseCache = {
    hmdPos = {x = 0, y = 0, z = 0},
    standingOrigin = {x = 0, y = 0, z = 0},
    frameValid = false,
}

local crouchState = {
    isCrouched = false,                 
    baselineHeight = nil,               
    currentHeight = 0,                
    heightHistory = {},               
    heightHistoryIndex = 1,           
    debounceTimer = 0,                 
    calibrated = false,             
}

local playerCache = {
    player = nil,
    lastUpdateTime = 0,
    updateInterval = 1.0,            
}


for i = 1, config.heightSmoothingFrames do
    crouchState.heightHistory[i] = 0
end

local crouchOffsetActive = false

local function getPlayer()
    local currentTime = os.clock()

    if playerCache.player ~= nil and (currentTime - playerCache.lastUpdateTime) < playerCache.updateInterval then
        if uevrUtils.getValid(playerCache.player) then
            return playerCache.player
        end
    end

    local player = api:get_local_pawn(0)
    if player ~= nil then
        playerCache.player = player
        playerCache.lastUpdateTime = currentTime
    end

    return player
end

local function updatePoseCache()
    if not ENABLE_POSE_CACHING then
        poseCache.frameValid = false
        return
    end

    local hmd_index = vr.get_hmd_index()
    if hmd_index then
        vr.get_pose(hmd_index, temp_vec3f, temp_quatf)
        poseCache.hmdPos.x = temp_vec3f.x
        poseCache.hmdPos.y = temp_vec3f.y
        poseCache.hmdPos.z = temp_vec3f.z
        poseCache.frameValid = true
    else
        poseCache.frameValid = false
    end
end

local function getHMDHeight()
    if not poseCache.frameValid then
        return nil
    end

    return poseCache.hmdPos.y
end

local function getSmoothedHeight(rawHeightMeters)
    if not ENABLE_HEIGHT_SMOOTHING then
        return rawHeightMeters
    end

    crouchState.heightHistory[crouchState.heightHistoryIndex] = rawHeightMeters
    crouchState.heightHistoryIndex = crouchState.heightHistoryIndex + 1
    if crouchState.heightHistoryIndex > config.heightSmoothingFrames then
        crouchState.heightHistoryIndex = 1
    end

    local sum = 0
    for i = 1, config.heightSmoothingFrames do
        sum = sum + crouchState.heightHistory[i]
    end

    return sum / config.heightSmoothingFrames
end

local function calibrateHeight()
    local rawHeightMeters = getHMDHeight()
    if rawHeightMeters == nil then
        return false
    end

    crouchState.baselineHeight = getSmoothedHeight(rawHeightMeters)
    crouchState.calibrated = true

    return true
end


local function maintainCapsuleHeight()
    if not crouchOffsetActive then
        return
    end

    local player = getPlayer()
    if player == nil or player.CapsuleComponent == nil then
        return
    end


end

local function executeCrouch(shouldCrouch)
    local player = getPlayer()
    if player == nil then
        return false
    end

    if shouldCrouch then
        if player.CapsuleComponent ~= nil and player.CapsuleComponent.GetUnscaledCapsuleHalfHeight ~= nil then
            crouchOffsetActive = true

            -- Crouch
            if player.DoCrouch ~= nil then
                player:DoCrouch()
            end
        end
    else
        if player.UnCrouch ~= nil then
            player:UnCrouch()
            crouchOffsetActive = false
        end
    end

    return true
end

local function updatePhysicalCrouch(deltaTime)
    if crouchState.debounceTimer > 0 then
        crouchState.debounceTimer = crouchState.debounceTimer - deltaTime
    end

    local rawHeightMeters = getHMDHeight()
    if rawHeightMeters == nil then
        return
    end

    crouchState.currentHeight = getSmoothedHeight(rawHeightMeters)

    if not crouchState.calibrated then
        calibrateHeight()
        return
    end

    local heightDiffMeters = crouchState.baselineHeight - crouchState.currentHeight
    local heightDiffCm = heightDiffMeters * 100.0

    local crouchThresholdMeters = config.crouchThreshold / 100.0
    local standThresholdMeters = config.standThreshold / 100.0

    if crouchState.debounceTimer <= 0 then
        if not crouchState.isCrouched and heightDiffMeters >= crouchThresholdMeters then
            print("[physicalCrouch] *** CROUCH DETECTED ***")
            executeCrouch(true)
            crouchState.isCrouched = true
            crouchState.debounceTimer = config.debounceTime
        elseif crouchState.isCrouched and heightDiffMeters < standThresholdMeters then
            print("[physicalCrouch] *** STAND DETECTED ***")
            executeCrouch(false)
            crouchState.isCrouched = false
            crouchState.debounceTimer = config.debounceTime
        end
    end
end

local function onPreEngineTick(engine, delta)
    updatePoseCache()
    maintainCapsuleHeight()
    updatePhysicalCrouch(delta)
end

callbacks.on_pre_engine_tick(onPreEngineTick)

uevrUtils.registerLevelChangeCallback(function(level)
    crouchOffsetActive = false

    crouchState.isCrouched = false
    crouchState.calibrated = false
    crouchState.baselineHeight = nil
    crouchState.debounceTimer = 0

    for i = 1, config.heightSmoothingFrames do
        crouchState.heightHistory[i] = 0
    end

    playerCache.player = nil
end)

-- ImGui Configuration Panel
uevr.lua.add_script_panel("Physical Crouching", function()
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

    imgui.text("Tip: Adjust settings below, then click 'Save Config' to persist")

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    if imgui.button("Recalibrate Height") then
        crouchState.calibrated = false
        crouchState.baselineHeight = nil
    end

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.text("=== CROUCH DETECTION THRESHOLDS ===")

    local crouchThresholdChanged, crouchThresholdValue = imgui.drag_float("Crouch Threshold (cm)", config.crouchThreshold, 1.0, 5.0, 100.0)
    if crouchThresholdChanged then
        config.crouchThreshold = crouchThresholdValue
    end
    imgui.text("Height drop required to trigger crouch")

    local standThresholdChanged, standThresholdValue = imgui.drag_float("Stand Threshold (cm)", config.standThreshold, 1.0, 5.0, 100.0)
    if standThresholdChanged then
        config.standThreshold = standThresholdValue
    end
    imgui.text("Height rise required to trigger stand")
end)

crouchOffsetActive = false