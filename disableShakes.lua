local uevrUtils = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local api = uevr.api

-- Utility
local function find_required_class(path)
    local obj = api:find_uobject(path)
    if not obj then
        uevrUtils.print("[DEBUG] Cannot find " .. path)
    end
    return obj
end

-- Classes
local DICameraShake_c =
    find_required_class("Class /Script/DeadIsland.DICameraShake")

local NotifyClasses = {
    find_required_class(
        "BlueprintGeneratedClass /Game/DI2/Animation/Notifies/Notifies/BP_AnimNotify_TriggerCameraAnimation.BP_AnimNotify_TriggerCameraAnimation_C"
    ),
    find_required_class(
        "BlueprintGeneratedClass /Game/DI2/Animation/Notifies/Notifies/BP_AnimNotify_TriggerCameraWindupAnimation.BP_AnimNotify_TriggerCameraWindupAnimation_C"
    ),
    find_required_class(
        "BlueprintGeneratedClass /Game/DI2/Animation/Notifies/Notifies/BP_AnimNotify_TriggerHeavyCameraAnimation.BP_AnimNotify_TriggerHeavyCameraAnimation_C"
    ),
}

-- Flag snapshots
local original_flags = {}
local hooked = false

local function hook_function(fn, hook_cb)
    if not fn then return end

    if not original_flags[fn] then
        original_flags[fn] = fn:get_function_flags()
        fn:set_function_flags(original_flags[fn] | 0x400)
    end

    fn:hook_ptr(hook_cb)
end

local function hook_camera_shake()
    if hooked then return end

    -- Camera shake suppression
    hook_function(
        DICameraShake_c:find_function("BlueprintUpdateCameraShake"),
        function(fn, obj)
            obj.ShakeScale = 0.0
            return false
        end
    )

    hook_function(
        DICameraShake_c:find_function("ReceivePlayShake"),
        function(fn, obj)
            obj.ShakeScale = 0.0
            return false
        end
    )

    -- Suppress all camera animation notifies
    for _, cls in ipairs(NotifyClasses) do
        hook_function(
            cls:find_function("Received_Notify"),
            function()
                return false
            end
        )
    end

    hooked = true
    uevrUtils.print("[disableShakes] Shake scales clamped to 0 and Notifies suppressed")
end

uevrUtils.registerPreEngineTickCallback(function()
    hook_camera_shake()
end)

-- Reset
uevr.sdk.callbacks.on_script_reset(function()
    for fn, flags in pairs(original_flags) do
        fn:set_function_flags(flags)
    end

    original_flags = {}
    hooked = false

    uevrUtils.print("[disableShakes] Hooks reset")
end)
