-- PERFORMANCE OPTIMIZATIONS APPLIED:
-- Optimization 3: Component caching - Minigame component cached and revalidated every 1 second
-- Optimization 5: Global variable caching - Reduced _G.GESTURE_BLOCK_ACTIVE lookups
-- Expected frame time savings: 0.05-0.1ms per frame

local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")

-- Performance optimization flags
local ENABLE_COMPONENT_CACHING = true

local config = {
    counterAimMethod = 0,
    blockDuration = 1.0, -- How long to keep counter aim after block starts (if no minigame)
    recoveryDuration = 2.5, -- How long to keep counter aim after minigame ends
}

local wasInCounter = false
local blockStartTime = 0
local minigameActivated = false
local minigameEndTime = 0
local lastMinigameActive = false
local blockButtonPressed = false
local lastBlockButtonState = false
local originalAimMethod = nil

-- Component cache (Optimization 3)
local componentCache = {
    minigameComponent = nil,
    lastValidationTime = 0,
    validationInterval = 1.0, -- Revalidate cache every 1 second
}

-- Function to get PlayerMinigameComponent from player
local function getMinigameComponent()
    if not ENABLE_COMPONENT_CACHING then
        -- Fallback to original implementation
        local componentClass = api:find_uobject("Class /Script/DeadIsland.PlayerMinigameComponent")
        if not componentClass then return end

        local controller = api:get_player_controller(0)
        if not controller then return end

        return controller:GetComponentByClass(componentClass)
    end

    local now = os.clock()

    -- Return cached component if still valid
    if componentCache.minigameComponent and (now - componentCache.lastValidationTime) < componentCache.validationInterval then
        return componentCache.minigameComponent
    end

    -- Cache expired or invalid - refresh it
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

-- Function to check if any minigame is active
local function isMinigameActive(minigameComp)
    if not minigameComp then return false end
    return minigameComp:IsMinigameInProgress()
end

-- Check if block button was just pressed (real button or gesture)
local function checkBlockButtonPress()
    -- Optimization 5: cache global variable lookup
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

-- Function to set aim method
local function setAimMethod(method)
    if vr.set_aim_method then
        vr.set_aim_method(method)
    end
end

-- Main update function
local function updateCounterDetection()
    local now = os.clock()

    -- Get minigame state
    local minigameComponent = getMinigameComponent()
    if not minigameComponent then return end
    local minigameActive = isMinigameActive(minigameComponent)

    -- Check for block button/gesture press
    local blockPressed = checkBlockButtonPress()

    -- Optimization 5: cache global variable lookup
    local gestureBlockActive = _G.GESTURE_BLOCK_ACTIVE or false
    -- Check if block is currently active (held or gesture active)
    local blockActive = blockButtonPressed or gestureBlockActive

    -- STATE 1: Block button/gesture pressed -> activate counter aim
    if blockPressed and not wasInCounter then
        -- Store original aim method (fallback to RIGHT_CONTROLLER if get not available)
        if vr.get_aim_method then
            originalAimMethod = vr.get_aim_method()
        else
            originalAimMethod = 2  -- RIGHT_CONTROLLER
        end

        setAimMethod(config.counterAimMethod)
        wasInCounter = true
        blockStartTime = now
        minigameActivated = false
        minigameEndTime = 0
    end

    -- Refresh timer while blocking is active in counter mode (and no minigame activated)
    if blockActive and wasInCounter and not minigameActivated then
        blockStartTime = now
    end

    -- STATE 2: Minigame activates during counter
    if wasInCounter and minigameActive and not lastMinigameActive then
        minigameActivated = true
        minigameEndTime = 0
    end

    -- STATE 3: Minigame ends
    if wasInCounter and minigameActivated and not minigameActive and lastMinigameActive then
        minigameEndTime = now
    end

    lastMinigameActive = minigameActive

    -- STATE 4: Revert conditions
    if wasInCounter then
        local shouldRevert = false

        if minigameActivated then
            -- If minigame happened, wait for it to end + recovery duration
            if minigameEndTime > 0 then
                local timeSinceEnd = now - minigameEndTime
                if timeSinceEnd >= config.recoveryDuration then
                    shouldRevert = true
                end
            end
        else
            -- If no minigame, just wait for block duration
            local timeSinceBlock = now - blockStartTime
            if timeSinceBlock >= config.blockDuration then
                shouldRevert = true
            end
        end

        if shouldRevert then
            if originalAimMethod then
                setAimMethod(originalAimMethod)
            end
            wasInCounter = false
            minigameActivated = false
            minigameEndTime = 0
            blockStartTime = 0
        end
    end
end

-- XInput callback to detect left shoulder button press (block button)
callbacks.on_xinput_get_state(function(retval, user_index, state)
    if state then
        blockButtonPressed = (state.Gamepad.wButtons & 0x0100) ~= 0
    end
end)

-- Register callback
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    updateCounterDetection()
end)
