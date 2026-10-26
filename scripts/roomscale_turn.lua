-- Cronos VR - Roomscale turning
--
-- Cronos does not look through PlayerController.ControlRotation. The look
-- direction lives in the pawn's View component (SHCharacterPlayViewComponent),
-- which drives SpringArm -> Camera. The right stick rotates View; UEVR only
-- adds the HMD to the rendered image, so physical head/body turns never reach
-- the game (interaction prompts, look checks) and the capsule never follows.
--
-- Per tick:
--   * Any change to View since our last push (stick turn, game look-at) is
--     absorbed into baseYaw.
--   * View is pushed to the direction actually rendered last frame
--     (baseYaw + HMD), and the pawn capsule + ControlRotation are set to the
--     same yaw (1:1 body follow).
-- Per eye (early): the game camera yaw is replaced with baseYaw so UEVR's HMD
-- rotation lands exactly on View instead of turning twice. This also bypasses
-- the spring arm's rotation lag.
-- Per eye (post): the final rendered yaw/pitch is recorded for the next tick.
--
-- Requires the UObjectHook camera attach (uobjecthook/camera_state.json) to
-- have zero horizontal offset, otherwise the eye orbits the capsule when the
-- body turns.

local uevrUtils = require("libs/uevr_utils")
local configui  = require("libs/configui")

local configDef = {
    {
        panelLabel = "Cronos Roomscale",
        saveFile = "roomscale_config",
        layout = {
            { widgetType = "checkbox", id = "roomscaleEnabled", label = "Roomscale turning (head drives game view)", initialValue = true },
            { widgetType = "checkbox", id = "roomscaleBodyFollow", label = "Body follows head 1:1", initialValue = true },
            { widgetType = "checkbox", id = "roomscalePitch", label = "Head pitch drives game view", initialValue = true },
        }
    }
}
configui.create(configDef)

local function angDiff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

local active        = false  -- true while we own the view (not in cutscene/menu)
local baseYaw       = nil    -- stick/game yaw without HMD; fed to UEVR as camera yaw
local lastSetYaw    = nil    -- View yaw immediately after our last push
local renderedYaw   = nil    -- final eye yaw from the last stereo pass
local renderedPitch = nil

-- How far UEVR's HMD rotation turns the image away from the camera yaw it is
-- given (rendered yaw - input yaw). Measured every frame, including while we
-- are inactive, so a restart after a cutscene can subtract it; otherwise the
-- view snaps by however far the player has physically turned.
local stereoInputYaw = nil
local hmdYawOffset   = nil
local wasCutscene    = false

local function reset()
    active        = false
    baseYaw       = nil
    lastSetYaw    = nil
    renderedYaw   = nil
    renderedPitch = nil
end

local function isCutscene(pc, pawn)
    local ok, cine = pcall(function()
        local vt = pc:GetViewTarget()
        return vt ~= nil and vt:get_full_name():find("CineCamera", 1, true) ~= nil
    end)
    if ok and cine then return true end

    local ok2, wallWalk = pcall(function()
        local ww = pawn.WallWalkComponent
        return ww ~= nil and ww["isEnabled?"] == true
    end)
    return ok2 and wallWalk
end

-- ─── Throwable aiming ───
-- Trap mines (hold left grip, release to throw) are launched natively along the
-- game's aim rotation (View) plus ThrowAdditionalPitch, not through a weapon
-- trace, so CronosAimFix.dll can't redirect them. While the mine ability is
-- active, View follows the right controller instead of the head; rendering is
-- driven by baseYaw, so the player's view doesn't move.
local characterStatics    = nil
local rightController     = nil
local controllerClass     = nil

local function findRightController()
    if rightController ~= nil and UEVR_UObjectHook.exists(rightController) then
        return rightController
    end
    rightController = nil
    if controllerClass == nil then
        controllerClass = uevr.api:find_uobject("Class /Script/HeadMountedDisplay.MotionControllerComponent")
        if controllerClass == nil then return nil end
    end
    for _, c in ipairs(UEVR_UObjectHook.get_objects_by_class(controllerClass, false)) do
        local ok, source = pcall(function() return c.MotionSource:to_string() end)
        if ok and source == "Right" then
            rightController = c
            break
        end
    end
    return rightController
end

local function isMineAiming(pawn)
    if characterStatics == nil then
        local cls = uevr.api:find_uobject("Class /Script/Cronos.SHCharacterStatics")
        if cls == nil then return false end
        characterStatics = cls:get_class_default_object()
        if characterStatics == nil then return false end
    end
    local ok, aiming = pcall(function() return characterStatics:IsInTrapMineAim(pawn) end)
    return ok and aiming == true
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not uevr.params.vr.is_hmd_active() or configui.getValue("roomscaleEnabled") == false then
        reset()
        return
    end

    local pawn = uevr.api:get_local_pawn(0)
    local pc   = uevr.api:get_player_controller(0)
    if pawn == nil or pc == nil then reset() return end

    -- On entering a cutscene/vent camera, recenter the VR view: the game's camera
    -- doesn't know about the player's physical turn, so without this the player
    -- can start the sequence facing sideways or backwards.
    local cutscene = isCutscene(pc, pawn)
    if cutscene and not wasCutscene then
        pcall(function() uevr.params.vr.recenter_view() end)
    end
    wasCutscene = cutscene

    local view = uevrUtils.getValid(pawn.View)
    if view == nil or cutscene then reset() return end

    local ok, viewRot = pcall(function() return view:GetViewRotation() end)
    if not ok or viewRot == nil then reset() return end

    if not active then
        -- (Re)start: the image currently renders at View + HMD offset. Taking
        -- the HMD offset off the base keeps the image where it is, and the push
        -- below then swings View onto the head with no visible snap.
        active     = true
        baseYaw    = viewRot.Yaw - (hmdYawOffset or 0)
        lastSetYaw = viewRot.Yaw
        return
    end

    -- Absorb stick turns and game-driven look changes since our last push
    local external = angDiff(viewRot.Yaw, lastSetYaw)
    baseYaw = baseYaw + external

    if renderedYaw == nil then return end

    -- The next frame renders at (new base + HMD) = last rendered + external
    local targetYaw   = renderedYaw + external
    local targetPitch = viewRot.Pitch
    if configui.getValue("roomscalePitch") ~= false and renderedPitch ~= nil then
        targetPitch = renderedPitch
    end

    if isMineAiming(pawn) then
        local controller = findRightController()
        if controller ~= nil then
            local ok3, ctrlRot = pcall(function() return controller:K2_GetComponentRotation() end)
            if ok3 and ctrlRot ~= nil then
                targetYaw   = ctrlRot.Yaw
                targetPitch = ctrlRot.Pitch
            end
        end
    end

    pcall(function()
        view:AddToControlRotation(uevrUtils.rotator(angDiff(targetPitch, viewRot.Pitch), angDiff(targetYaw, viewRot.Yaw), 0), nil)
    end)

    -- Read back so a blocked/scaled rotation isn't mistaken for a stick turn
    local ok2, after = pcall(function() return view:GetViewRotation() end)
    lastSetYaw = (ok2 and after ~= nil) and after.Yaw or viewRot.Yaw

    if configui.getValue("roomscaleBodyFollow") ~= false then
        pcall(function()
            pawn:K2_SetActorRotation(uevrUtils.rotator(0, targetYaw, 0), false)
            pc:SetControlRotation(uevrUtils.rotator(0, targetYaw, 0))
        end)
    end
end)

uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if active and baseYaw ~= nil then
        rotation.Yaw = baseYaw
    end
    stereoInputYaw = rotation.Yaw
end)

uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if stereoInputYaw ~= nil then
        hmdYawOffset = angDiff(rotation.Yaw, stereoInputYaw)
    end
    if not active then return end
    renderedYaw   = rotation.Yaw
    renderedPitch = rotation.Pitch
end)

uevr.sdk.callbacks.on_script_reset(function()
    reset()
end)
