local uevrUtils   = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local controllers = require("libs/controllers")

local hmd_comp    = nil
local pc = uevr.api:get_player_controller(0)

local function try_pin()
    if hmd_comp == nil or not uevrUtils.validate_object(hmd_comp) then
        hmd_comp = controllers.createController(2)
        if hmd_comp == nil then
            hmd_comp = controllers.getController(2)
        end
    end
    if hmd_comp == nil then return end

    pc:SetAudioListenerOverride(hmd_comp, uevrUtils.vector(0,0,0), uevrUtils.rotator(0,0,0))
end

uevrUtils.registerLevelChangeCallback(function()
    hmd_comp = nil
    try_pin()
end)

-- Reset
uevr.sdk.callbacks.on_script_reset(function()
    pc:ClearAudioListenerOverride()
    uevrUtils.print("reset")
end)
