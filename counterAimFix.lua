local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")

local ENABLE_COMPONENT_CACHING = true

local config = {
    counterAimMethod = 1,
    blockDuration = 2.0, 
    recoveryDuration = 2.5, 
}

local wasInCounter = false
local blockStartTime = 0
local minigameActivated = false
local minigameEndTime = 0
local lastMinigameActive = false
local blockButtonPressed = false
local lastBlockButtonState = false
local originalAimMethod = 2

local componentCache = {
    minigameComponent = nil,
    lastValidationTime = 0,
    validationInterval = 1.0, 
}

local function getMinigameComponent()
    if not ENABLE_COMPONENT_CACHING then
        local componentClass = api:find_uobject("Class /Script/DeadIsland.PlayerMinigameComponent")
        if not componentClass then return end

        local controller = api:get_player_controller(0)
        if not controller then return end

        return controller:GetComponentByClass(componentClass)
    end

    local now = os.clock()

    if componentCache.minigameComponent and (now - componentCache.lastValidationTime) < componentCache.validationInterval then
        return componentCache.minigameComponent
    end

    local componentClass = api:find_uobject("Class /Script/DeadIsland.PlayerMinigameComponent")
    if not componentClass then
        componentCache.minigameComponent = nil
        return nil
    end

    local controller = api:get_player_controller(0)
    if not controller then
        componentCache.minigameComponent = nil
        return nil
    end

    componentCache.minigameComponent = controller:GetComponentByClass(componentClass)
    componentCache.lastValidationTime = now

    return componentCache.minigameComponent
end

local function isMinigameActive(minigameComp)
    if not minigameComp then return false end
    return minigameComp:IsMinigameInProgress()
end

local function checkBlockButtonPress()
    local gestureBlocking = _G.GESTURE_BLOCK_ACTIVE or false
    local anyBlocking = blockButtonPressed or gestureBlocking

    if anyBlocking and not lastBlockButtonState then
        lastBlockButtonState = true
        return true
    elseif not anyBlocking then
        lastBlockButtonState = false
    end

    return false
end

local function setAimMethod(method)
    if vr.set_aim_method then
        vr.set_aim_method(method)
    end
end

local function updateCounterDetection()
    local now = os.clock()

    local minigameComponent = getMinigameComponent()
    if not minigameComponent then return end
    local minigameActive = isMinigameActive(minigameComponent)

    local blockPressed = checkBlockButtonPress()

    local gestureBlockActive = _G.GESTURE_BLOCK_ACTIVE or false
    local blockActive = blockButtonPressed or gestureBlockActive

    if blockPressed and not wasInCounter then
        setAimMethod(config.counterAimMethod)
        wasInCounter = true
        blockStartTime = now
        minigameActivated = false
        minigameEndTime = 0
    end

    if blockActive and wasInCounter and not minigameActivated then
        blockStartTime = now
    end

    if wasInCounter and minigameActive and not lastMinigameActive then
        minigameActivated = true
        minigameEndTime = 0
    end

    if wasInCounter and minigameActivated and not minigameActive and lastMinigameActive then
        minigameEndTime = now
    end

    lastMinigameActive = minigameActive

    if wasInCounter then
        local shouldRevert = false

        if minigameActivated then
            if minigameEndTime > 0 then
                local timeSinceEnd = now - minigameEndTime
                if timeSinceEnd >= config.recoveryDuration then
                    shouldRevert = true
                end
            end
        else
            local timeSinceBlock = now - blockStartTime
            if timeSinceBlock >= config.blockDuration then
                shouldRevert = true
            end
        end

        if shouldRevert then
            setAimMethod(originalAimMethod)
            wasInCounter = false
            minigameActivated = false
            minigameEndTime = 0
            blockStartTime = 0
        end
    end
end

callbacks.on_xinput_get_state(function(retval, user_index, state)
    if state then
        blockButtonPressed = (state.Gamepad.wButtons & 0x0100) ~= 0
    end
end)

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    updateCounterDetection()
end)
