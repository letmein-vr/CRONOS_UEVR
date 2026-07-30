local uevrUtils   = require("libs/uevr_utils")
uevrUtils.initUEVR(uevr)

local controllers = require("libs/controllers")

local hmd_comp    = nil
local pc = nil

local function try_pin()
    if hmd_comp == nil or not uevrUtils.validate_object(hmd_comp) then
        hmd_comp = controllers.createController(2)
        if hmd_comp == nil then
            hmd_comp = controllers.getController(2)
        end
    end
    if hmd_comp == nil then return end

    pc = uevr.api:get_player_controller(0)
    if pc ~= nil and uevrUtils.validate_object(pc) then
        pc:SetAudioListenerOverride(hmd_comp, uevrUtils.vector(0,0,0), uevrUtils.rotator(0,0,0))
        uevrUtils.print("[hmd_audio] Audio listener pinned to HMD.")
    end
end

-- Call initially when the script loads
try_pin()

-- Re-apply when the level changes
uevrUtils.registerLevelChangeCallback(function()
    hmd_comp = nil
    try_pin()
end)

-- Clean up on script reset
uevr.sdk.callbacks.on_script_reset(function()
    if pc ~= nil and uevrUtils.validate_object(pc) then
        pc:ClearAudioListenerOverride()
        uevrUtils.print("[hmd_audio] Audio listener override cleared on reset.")
    end
end)
