local api = uevr.api
local vr = uevr.params.vr
local callbacks = uevr.sdk.callbacks
local uevrUtils = require("libs/uevr_utils")

local config = {
    originalAimMethod = 2,
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


-- Function to get PlayerMinigameComponent from player
local function getMinigameComponent()
    local componentClass = api:find_uobject("Class /Script/DeadIsland.PlayerMinigameComponent")
    if not componentClass then return end

    local controller = api:get_player_controller(0)
    if not controller then return end

    return controller:GetComponentByClass(componentClass)
end

-- Function to check if any minigame is active
local function isMinigameActive(minigameComp)
    if not minigameComp then return false end
    return minigameComp:IsMinigameInProgress()
end

-- Check if block button was just pressed (real button or gesture)
local function checkBlockButtonPress()
    -- Check gesture blocking (from global variable set by gestureBlocking.lua)
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

    -- Check if block is currently active (held or gesture active)
    local blockActive = blockButtonPressed or (_G.GESTURE_BLOCK_ACTIVE or false)

    -- STATE 1: Block button/gesture pressed -> activate counter aim
    if blockPressed and not wasInCounter then
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
            setAimMethod(config.originalAimMethod)
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
