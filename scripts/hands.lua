-- Cronos VR Profile - Main Entry Point
-- Manages VR hands (jbusfield libs) and weapon/flashlight attachments via attachments.lua.
-- Gun (MultiModeGun.RootComponent) â†’ right controller
-- Flashlight (Flashlight_Mesh)      â†’ left  controller
--
-- UObjectHook mc_state JSONs for the gun and flashlight have been disabled.
-- Attachment offsets are now saved in data/attachments_parameters.json
-- and tunable live via the "Attachments Config Dev" panel in the UEVR overlay.

local uevrUtils  = require('libs/uevr_utils')
local hands      = require('libs/hands')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local gestures    = require('libs/gestures')
local configui    = require('libs/configui')
local reticule    = require('libs/reticule')

uevrUtils.setLogLevel(LogLevel.Debug)
uevrUtils.setLogToFile(true)
hands.setLogLevel(LogLevel.Debug)
attachments.setLogLevel(LogLevel.Warning) -- Debug logs every attach / detach step

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Attachment options for both weapons
-- detachFromOriginOnGrip = false keeps the objects inside their
-- original game hierarchy (WeaponPlayerComponent / pawn) so the
-- game's own systems don't fight us. The motion-controller state
-- added by attachToRawController still overrides the final pose.
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local gunOptions = {
    detachFromOriginOnGrip              = false,
    maintainWorldPositionOnDetachFromOrigin = false,
    detachFromParentOnRelease           = false,
    maintainWorldPositionOnDetachFromParent = false,
    reattachToOriginOnRelease           = false,
    restoreTransformToOriginOnReattach  = false,
    useZeroTransformOnReattach          = false,
    allowChildVisibilityHandling        = false, -- gun visibility handled by game
    allowChildHiddenInGameHandling      = false,
    allowRenderInMainPassHandling       = false,
}

local flashlightOptions = {
    detachFromOriginOnGrip              = false,
    maintainWorldPositionOnDetachFromOrigin = false,
    detachFromParentOnRelease           = false,
    maintainWorldPositionOnDetachFromParent = false,
    reattachToOriginOnRelease           = false,
    restoreTransformToOriginOnReattach  = false,
    useZeroTransformOnReattach          = false,
    allowChildVisibilityHandling        = false, -- flashlight visibility handled by game
    allowChildHiddenInGameHandling      = false,
    allowRenderInMainPassHandling       = false,
}

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Initialize attachments with developer mode ON
-- â†’ shows "Attachments Config Dev" panel in UEVR overlay
-- â†’ loads / creates data/attachments_parameters.json
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
attachments.init(true)
reticule.init(false)

-- ─────────────────────────────────────────────────────────────────
-- Hands mode: VR hands (glove hands cut from the Traveler mesh) OR the
-- full-arm IK rig (libs/ik). Ported from the Hellraiser profile.
-- They are mutually exclusive: both register the same animation ids
-- with hands_animation, so only one may exist at a time.
-- The rig is parented to the HMD (ik_parameters.json parent_type 2),
-- not the pawn: character materials dither when the camera is close to
-- the root of their attachment chain, and anything rooted on the pawn
-- sits right next to the VR eye.
-- ─────────────────────────────────────────────────────────────────
local ik = require('libs/ik')

-- libs/ik.lua requires libs/input, whose tick / stereo / xinput callbacks run as soon as it's loaded
-- (init() only adds its panel): aim method, pawn rotation and position modes, controller rotation overrides,
-- stick turning of the root. Cronos's look direction and body yaw belong to roomscale_turn.lua (pawn.View),
-- so it is kept off through its own "isDisabledOverride" (true in data/input_parameters.json); the Input dev
-- panel (init(true)) shows its settings and can switch it on for testing.
require('libs/input').init(false, LogLevel.Warning) -- false = no Input dev panel

local HANDS_MODE_HANDS   = 1
local HANDS_MODE_IK      = 2

-- Section of the merged "Cronos VR" panel (built by zz_cronos_vr_panel.lua)
_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 1, label = "Hands", layout = {
    { widgetType = "combo", id = "hands_mode", label = "Hands", initialValue = HANDS_MODE_HANDS, selections = {"Hands", "IK Arms"} },
    { widgetType = "text", id = "hands_mode_status", label = "Status: -" },
    { widgetType = "text", label = "-- Flashlight on the IK forearm (lowerarm_twist_01_l)" },
    { widgetType = "slider_float", id = "ikFlOffX",     label = "IK Flashlight Offset X",  initialValue = 0.0, range = {-40.0, 40.0} },
    { widgetType = "slider_float", id = "ikFlOffY",     label = "IK Flashlight Offset Y",  initialValue = 0.0, range = {-40.0, 40.0} },
    { widgetType = "slider_float", id = "ikFlOffZ",     label = "IK Flashlight Offset Z",  initialValue = 0.0, range = {-40.0, 40.0} },
    { widgetType = "slider_float", id = "ikFlRotPitch", label = "IK Flashlight Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
    { widgetType = "slider_float", id = "ikFlRotYaw",   label = "IK Flashlight Rot Yaw",   initialValue = 0.0, range = {-180.0, 180.0} },
    { widgetType = "slider_float", id = "ikFlRotRoll",  label = "IK Flashlight Rot Roll",  initialValue = 0.0, range = {-180.0, 180.0} },
}})

-- IK Arms mode (the rig replaces the glove hands)
local function isIKMode()
    local v = configui.getValue("hands_mode")
    return v == HANDS_MODE_IK
end
_G.cronosIsIKMode = isIKMode

-- The component each hand's attachments hang off: the glove hand, or the
-- single IK rig mesh (it carries both arms and the same sockets).
local function getHandMesh(hand)
    if isIKMode() then
        return ik.getCurrentMesh()
    end
    return hands.getHandComponent(hand)
end
_G.cronosGetHandMesh = getHandMesh

-- After a rebuild the hand components start in the open pose: hands_animation
-- only re-applies the weapon grip pose on a grip change or an input edge.
local function refreshWeaponPoses()
    for _, ms in ipairs({300, 1200}) do
        uevrUtils.setTimeout(ms, function()
            pcall(function()
                hands.updateAnimationState(Handed.Right)
                hands.updateAnimationState(Handed.Left)
            end)
        end)
    end
end

ik.registerOnMeshCreatedCallback(function(meshList, rig)
    refreshWeaponPoses()
    -- the flamethrower / harvester hang off the hand sockets; move them onto the new rig
    if _G.cronosAttachWeaponsToHands ~= nil then
        uevrUtils.setTimeout(100, function() pcall(_G.cronosAttachWeaponsToHands) end)
    end
end)
ik.init(false, LogLevel.Warning) -- false = no IK dev panel (true to tune the rig)
-- libs/ik auto-creates a rig by default; buildHands() turns it on only in the IK modes
ik.setAutoCreateArms(false)

local function buildHands()
    controllers.createController(0)  -- left  MotionControllerComponent
    controllers.createController(1)  -- right MotionControllerComponent
    controllers.createController(2)  -- HMD (the IK rig's parent)

    if isIKMode() then
        hands.setAutoCreateHands(false)
        hands.destroyHands()
        ik.setAutoCreateArms(true) -- the 1 s auto-create builds the rig from ik_parameters.json + hands_parameters.json
        configui.setLabel("hands_mode_status", "Status: IK Arms")
        return
    end

    ik.setAutoCreateArms(false)
    if ik.exists() then ik.destroyAll() end
    hands.destroyHands() -- hands.reset() only forgets a pair (leaks live components)
    hands.createFromConfig('hands_parameters', 'Main', 'Shared')
    hands.setAutoCreateHands(true)
    refreshWeaponPoses()
    configui.setLabel("hands_mode_status", "Status: Hands")
end

-- Switching the mode at runtime: tear down the current setup and build the other one in place.
configui.onUpdate("hands_mode", function(value)
    uevrUtils.setTimeout(1, function() -- configui callbacks run on the draw thread; build on the game thread
        buildHands()
        if _G.cronosAttachWeaponsToHands ~= nil then pcall(_G.cronosAttachWeaponsToHands) end
    end)
end)

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Pawn / mesh helpers
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local function getPawn()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    return uevrUtils.getValid(pawn)
end

-- MultiModeGun.RootComponent  (right hand)
local function getGunRoot(pawn)
    if pawn == nil then return nil end
    local ok, result = pcall(function()
        local wpc = pawn.WeaponPlayerComponent
        if wpc == nil then return nil end
        wpc = uevrUtils.getValid(wpc)
        if wpc == nil then return nil end

        local gun = wpc.MultiModeGun
        if gun == nil then return nil end
        gun = uevrUtils.getValid(gun)
        if gun == nil then return nil end

        local root = gun.RootComponent
        if root == nil then return nil end
        
        -- Disable Custom Depth to prevent screen-center occlusion fading
        local mesh = gun.Mesh
        if mesh ~= nil then
            mesh = uevrUtils.getValid(mesh)
            if mesh ~= nil and mesh.SetRenderCustomDepth ~= nil then
                mesh:SetRenderCustomDepth(false)
            end
        end

        return uevrUtils.getValid(root)
    end)
    if ok then return result end
    return nil
end

-- Flashlight_Mesh  (left hand)
local function getFlashlight(pawn)
    if pawn == nil then return nil end
    local ok, result = pcall(function()
        local fl = pawn.Flashlight_Mesh
        if fl == nil then return nil end
        fl = uevrUtils.getValid(fl)
        
        -- Disable Custom Depth to prevent screen-center occlusion fading
        if fl ~= nil and fl.SetRenderCustomDepth ~= nil then
            fl:SetRenderCustomDepth(false)
        end
        
        -- Disable animations on the flashlight mesh
        if fl ~= nil then
            pcall(function() fl.bPauseAnims = true end)
            pcall(function() fl.bNoSkeletonUpdate = true end)
        end
        
        return fl
    end)
    if ok then return result end
    return nil
end

-- IK modes: the flashlight rides the IK rig's forearm. The attachments library places it on the glove's
-- lowerarm_l with offsets tuned for the glove, whose arm bones are not anatomical (57 cm off the bone), so on
-- the IK arm it hung far from the hand and swung with every forearm move. Here it goes on
-- lowerarm_twist_01_l (near the wrist; libs/ik.lua rolls it with the wrist, like a strap) with its own
-- offsets (ikFl* in the Hands section).
local IK_FLASH_BONE = "lowerarm_twist_01_l"
local ikFlashBoneFName = nil
local ikFlashHit = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")

local function ensureFlashlightOnIKForearm(pawn)
    if not isIKMode() then return end
    local rig = uevrUtils.getValid(ik.getCurrentMesh())
    local fl = getFlashlight(pawn)
    if rig == nil or fl == nil then return end
    if ikFlashBoneFName == nil then ikFlashBoneFName = uevrUtils.fname_from_string(IK_FLASH_BONE) end
    if fl.AttachParent ~= rig or fl.AttachSocketName:to_string() ~= IK_FLASH_BONE then
        -- 0 = EAttachmentRule::KeepRelative (the relative transform is set right below)
        fl:K2_AttachToComponent(rig, ikFlashBoneFName, 0, 0, 0, false)
        print("[hands] Flashlight parented to the IK forearm")
    end
    fl:K2_SetRelativeLocationAndRotation(
        uevrUtils.vector(configui.getValue("ikFlOffX") or 0, configui.getValue("ikFlOffY") or 0, configui.getValue("ikFlOffZ") or 0),
        uevrUtils.rotator(configui.getValue("ikFlRotPitch") or 0, configui.getValue("ikFlRotYaw") or 0, configui.getValue("ikFlRotRoll") or 0),
        false, ikFlashHit, false)
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Flashlight SpotLight â†’ Left Controller via UObjectHook
-- We find the SpotLightComponent named 'Light' inside Flashlight_BP_C
-- and pin it to the left hand motion controller every tick.
-- This completely overrides the game's internal aim system.
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local cachedSpotLight      = nil
local spotLightSearchTime  = 0
local SPOTLIGHT_CLASS_NAME = "Class /Script/Engine.SpotLightComponent"
local inCutscene           = false  -- shared across both tick callbacks

local function findFlashlightSpot()
    local spotClass = uevr.api:find_uobject(SPOTLIGHT_CLASS_NAME)
    if spotClass == nil then
        print("[hands] SpotLightComponent class not found")
        return nil
    end

    local instances = UEVR_UObjectHook.get_objects_by_class(spotClass, false)
    if instances == nil then
        print("[hands] No SpotLightComponent instances found")
        return nil
    end

    for i, obj in ipairs(instances) do
        local ok, fullName = pcall(function() return obj:get_full_name() end)
        if ok and fullName then
            -- Must be inside a live Flashlight_BP_C actor (PersistentLevel, not the CDO)
            -- CDOs have "Default__" in their path â€” explicitly exclude them
            if fullName:find("Flashlight_BP_C")
            and fullName:match("%.Light$")
            and not fullName:find("Default__") then
                print("[hands] Found target spotlight: " .. fullName)
                return obj
            end
        end
    end
    print("[hands] Target SpotLightComponent not found yet")
    return nil
end

-- ─────────────────────────────────────────────────────────────────
-- Weapon reticule (2026-10-26, after the Hellraiser profile's uevrmenus.lua)
-- The game's own reticle for the active weapon mode (manageReticles below) is drawn as a 3D widget on the line from
-- the eye to where the gun is aimed: a trace from MuzzlePoint along the gun root's right vector - the same muzzle
-- and axis CronosAimFix fires along (root forward rotated 90 deg about root up), so the reticle shows where shots
-- land and follows the barrel when two-handing pivots the gun. It sits at the hit, or at the max distance along
-- the barrel when nothing is hit. (It used to be traced from the right controller's forward, which is not where
-- the barrel points.)
-- ─────────────────────────────────────────────────────────────────
_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 5, label = "Weapon Reticule", layout = {
    { widgetType = "checkbox", id = "enable3DReticle", label = "Enable VR weapon reticule", initialValue = true },
    { widgetType = "slider_float", id = "ret_brightness", label = "Reticule brightness", range = {1.0, 20.0}, initialValue = 10.0, speed = 0.1 },
    { widgetType = "slider_float", id = "ret_distance", label = "Reticule max distance (cm)", range = {100.0, 5000.0}, initialValue = 1000.0, speed = 10.0 },
    { widgetType = "checkbox", id = "ret_constant_size", label = "Keep the same apparent size at any distance", initialValue = true },
    { widgetType = "slider_float", id = "ret_size", label = "Reticule size", range = {0.2, 5.0}, initialValue = 1.0, speed = 0.01 },
}})
local RETICULE_SIZE_REFERENCE = 200 -- cm: with constant size on, "size 1" looks the way the reticule did at 200 cm
local RETICULE_COLLISION_PULLBACK = 10 -- cm: libs/reticule.lua draws it this far in front of a hit

local function retNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

local function updateWeaponReticule()
    if not reticule.exists() then return end
    local pawn = getPawn()
    local root = pawn ~= nil and getGunRoot(pawn) or nil
    local muzzle = nil
    pcall(function() muzzle = uevrUtils.getValid(pawn.WeaponPlayerComponent.MultiModeGun.MuzzlePoint) end)
    if root == nil or muzzle == nil or inCutscene then
        reticule.setHidden(true)
        reticule.update() -- applies the hidden state
        return
    end
    reticule.setHidden(false)

    -- Brightness = the 3D component's tint (applied in its material, unclipped; Hellraiser does the same). The
    -- widget's own colour can't do it: it renders into an 8-bit target, so anything above 1.0 stayed dark grey.
    local component = reticule.getComponent()
    if component ~= nil and component.SetTintColorAndOpacity ~= nil then
        local b = retNum("ret_brightness", 10.0)
        local t = component.TintColorAndOpacity
        if t == nil or math.abs(t.R - b) > 0.001 then
            component:SetTintColorAndOpacity(uevrUtils.color_from_rgba(b, b, b, 1.0))
        end
    end

    local maxDistance = retNum("ret_distance", 1000.0)
    local origin = muzzle:K2_GetComponentLocation()
    local direction = root:GetRightVector()
    local ignore = { pawn }
    pcall(function() table.insert(ignore, pawn.WeaponPlayerComponent.MultiModeGun) end)
    local target = uevrUtils.getTargetLocation(origin, direction, 0, ignore, false, 10, maxDistance)
    if target == nil then
        target = uevrUtils.vector(origin.X + direction.X * maxDistance, origin.Y + direction.Y * maxDistance, origin.Z + direction.Z * maxDistance)
    end

    -- the library draws it on the eye -> target line, at most maxDistance away (nearer when the target is nearer)
    local eye = reticule.getOriginPositionFromController()
    local size = retNum("ret_size", 1.0)
    if configui.getValue("ret_constant_size") ~= false and eye ~= nil then
        local dx, dy, dz = target.X - eye.X, target.Y - eye.Y, target.Z - eye.Z
        local drawn = math.min(maxDistance, math.sqrt(dx * dx + dy * dy + dz * dz) - RETICULE_COLLISION_PULLBACK)
        size = size * math.max(drawn, 1.0) / RETICULE_SIZE_REFERENCE
    end
    reticule.update(eye, target, maxDistance, { size, size, size })
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    -- â”€â”€ Spotlight: find and pin to left controller â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    local now = os.clock()
    if cachedSpotLight == nil or not pcall(function() cachedSpotLight:get_full_name() end) then
        if now - spotLightSearchTime > 2.0 then
            spotLightSearchTime = now
            cachedSpotLight = findFlashlightSpot()
            if cachedSpotLight then
                print("[hands] Found flashlight SpotLightComponent: " .. cachedSpotLight:get_full_name())
            end
        end
    end

    if cachedSpotLight ~= nil and not inCutscene then
        -- Pin the spotlight to the left controller (hand 0) every tick
        -- and apply per-weapon location/rotation offsets from the Cronos VR config panel.
        local ok, err = pcall(function()
            local state = UEVR_UObjectHook.get_or_add_motion_controller_state(cachedSpotLight)
            state:set_hand(0)       -- 0 = left hand
            state:set_permanent(true)
            state:set_location_offset(Vector3f.new(
                configui.getValue("slOffX") or 0,
                configui.getValue("slOffY") or 0,
                configui.getValue("slOffZ") or 0
            ))
            state:set_rotation_offset(Vector3f.new(
                math.rad(configui.getValue("slRotPitch") or 0),
                math.rad(configui.getValue("slRotYaw")   or 0),
                math.rad(configui.getValue("slRotRoll")  or 0)
            ))
        end)
        if not ok then
            cachedSpotLight = nil   -- stale; re-search next interval
        end
    end

    -- â”€â”€ Cutscene: force pawn.Mesh visible every tick â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- UObjectHook JSON and the game both fight us, so we override every frame.
    if inCutscene then
        local pawn = getPawn()
        if pawn ~= nil then
            pcall(function()
                local mesh = pawn.Mesh
                if mesh ~= nil then
                    mesh:SetVisibility(true, true)
                    mesh:SetHiddenInGame(false, true)
                end
            end)
        end
    end

    -- â”€â”€ Reticle: update 3D position â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    pcall(updateWeaponReticule)
end)


-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Cutscene detection & handling
--
-- Uses player:GetViewTarget() to detect view target changes.
-- When the target contains "CineCamera" we disable UObjectHook
-- entirely (UEVR_UObjectHook.set_disabled), hide VR hands, and
-- re-parent weapon meshes back to pawn.Mesh.  On exit, everything
-- is restored and UObjectHook re-enabled.
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local attachWeaponsToHands  -- forward declaration (defined later in file)

local objHookDisabled = false
local prevViewTarget  = nil

local function setObjHookDisabled(state)
    if state ~= objHookDisabled then
        objHookDisabled = state
        UEVR_UObjectHook.set_disabled(state)
        print("[hands] UObjectHook disabled: " .. tostring(state))
    end
end

local function attachWeaponsToPawnMesh(pawn)
    if pawn == nil then return end
    local mesh = uevrUtils.getValid(pawn.Mesh)
    if mesh == nil then return end

    -- Flamethrower â†’ Flamethrower_Attachment socket (same name as on the hand PMC)
    local flamethrower = uevrUtils.getValid(pawn.FlamethrowerSM)
    if flamethrower ~= nil then
        pcall(function()
            flamethrower:DetachFromParent(false, false)
            flamethrower:K2_AttachTo(mesh, uevrUtils.fname_from_string("Flamethrower_Attachment"), 0, false)
        end)
    end

    -- Harvester â†’ Harvester_Attachment socket (same name as on the hand PMC)
    local harvester = uevrUtils.getValid(pawn.HarvesterSK)
    if harvester ~= nil then
        pcall(function()
            harvester:DetachFromParent(false, false)
            harvester:K2_AttachTo(mesh, uevrUtils.fname_from_string("Harvester_Attachment"), 0, false)
        end)
    end

    -- Flashlight_Mesh and MultiModeGun are native weapons.
    -- We deliberately DO NOT detach them or re-attach them to "None",
    -- because that breaks their native animation state machines and
    -- causes the game to aggressively hide them.
end

-- ─────────────────────────────────────────────────────────────────
-- Gun parenting
-- Natively the gun root hangs off CharacterMesh0. The character
-- materials dither out when the camera is close to the root of their
-- attachment chain, and the VR eye sits on the capsule axis, so the gun
-- (and the right hand PMC attached to it) rendered dithered.
-- The game's own logic (reload activation, ignoring the player in weapon
-- traces) only needs the gun's parent component to be owned by the
-- character. So the gun hangs off a proxy SceneComponent that the
-- character owns but that is attached to the right motion controller:
-- owned by the pawn for gameplay, rooted on the controller for rendering.
-- UObjectHook still drives the gun's pose. The game re-attaches the gun
-- to its body socket for melee etc., so this is re-applied every tick.
-- The native parent, socket and relative transform are restored for
-- cutscenes.
-- ─────────────────────────────────────────────────────────────────
local gunNativeAttach = nil  -- { root, parent, socket, loc, rot }
local gunProxy = nil
local gunProxyPawn = nil

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 4, label = "Weapon", layout = {
    { widgetType = "checkbox", id = "gunOnController", label = "Gun on controller (fixes gun/right hand dither)", initialValue = true },
}})

local restoreGunToNativeParent  -- forward declaration (defined below)

local function getGunProxy(pawn, controller)
    if gunProxy ~= nil and (gunProxyPawn ~= pawn or uevrUtils.getValid(gunProxy) == nil) then
        gunProxy = nil
    end
    if gunProxy == nil then
        local cls = uevr.api:find_uobject("Class /Script/Engine.SceneComponent")
        if cls == nil then return nil end
        gunProxy = uevr.api:add_component_by_class(pawn, cls)
        gunProxyPawn = pawn
        if gunProxy == nil then return nil end
        print("[hands] Created gun proxy component on pawn")
    end
    -- IK modes: the proxy hangs on the IK arm mesh, not on the controller. A MotionControllerComponent moves
    -- everything under it to the newest controller pose on the render thread (low latency update); the IK arm
    -- has no such update, so a gun under the controller was always drawn ahead of the arm holding it.
    -- two_handed_integration.lua (IK weapon lock) puts the proxy where the controller was when the arm pose
    -- was solved.
    local rig = isIKMode() and uevrUtils.getValid(ik.getCurrentMesh()) or nil
    if rig ~= nil then
        if gunProxy.AttachParent ~= rig then
            -- 1 = EAttachmentRule::KeepWorld (stays put until the lock places it)
            gunProxy:K2_AttachToComponent(rig, uevrUtils.fname_from_string("None"), 1, 1, 1, false)
            print("[hands] Gun proxy parented to the IK arm mesh")
        end
    elseif gunProxy.AttachParent ~= controller then
        -- 2 = EAttachmentRule::SnapToTarget
        gunProxy:K2_AttachToComponent(controller, uevrUtils.fname_from_string("None"), 2, 2, 2, false)
    end
    return gunProxy
end

-- two_handed_integration.lua (IK weapon lock) places the gun by moving this proxy: the proxy while the gun
-- hangs on it, else nil
_G.cronosGetGunProxy = function()
    if gunProxy == nil or uevrUtils.getValid(gunProxy) == nil or inCutscene then return nil end
    local pawn = getPawn()
    local root = pawn ~= nil and getGunRoot(pawn) or nil
    if root == nil or root.AttachParent ~= gunProxy then return nil end
    return gunProxy
end

-- The gun is an attachments-library attachment on the proxy (see the grip callback): the library recognises
-- it (Attachments Config, grip animation) and owns its offset on the proxy. This keeps the proxy (and so the
-- gun's place relative to the hand) up to date and records the gun's native parent for cutscenes.
-- (It used to go through attachToRawController, whose UObjectHook state re-placed the gun on the raw
-- controller at render time: in IK modes that drew it ahead of the IK arm.)
local function ensureGunOnController(pawn)
    local root = getGunRoot(pawn)
    local controller = controllers.getController(1)
    if root == nil or controller == nil then return end

    local proxy = getGunProxy(pawn, controller)
    if proxy == nil then return end

    local parent = root.AttachParent
    if configui.getValue("gunOnController") == false then
        if parent == proxy then restoreGunToNativeParent() end
        return
    end
    if parent == proxy then return end

    if parent ~= nil then
        gunNativeAttach = {
            root   = root,
            parent = parent,
            socket = root.AttachSocketName,
            loc    = { X = root.RelativeLocation.X, Y = root.RelativeLocation.Y, Z = root.RelativeLocation.Z },
            rot    = { Pitch = root.RelativeRotation.Pitch, Yaw = root.RelativeRotation.Yaw, Roll = root.RelativeRotation.Roll },
        }
    end

    -- the game re-parented the gun (equip, melee): the library puts it back on the proxy with its offsets now
    pcall(attachments.forceGripUpdate)
end

-- ─────────────────────────────────────────────────────────────────
-- Muzzle point
-- MultiModeGun.MuzzlePoint is parked on the pistol's "GG_muzzle"
-- socket and the game never moves it when the mesh changes (flat
-- play shoots from the screen, so it doesn't care). CronosAimFix.dll
-- uses MuzzlePoint as the shot origin, so on meshes without that
-- socket (shotgun, rifle, ...) shots started at the mesh origin in
-- the player's hand, inside the capsule. Re-snap it to the current
-- mesh's own muzzle socket whenever the mesh asset changes.
-- ─────────────────────────────────────────────────────────────────
local MUZZLE_SOCKET_FALLBACKS = { "GG_muzzle", "SprdG_muzzle", "SmrtG_muzzle", "AnnG_muzzle" }
local lastMuzzleMeshAsset = nil
local lastMuzzleComponent = nil

local function findMuzzleSocket(mesh)
    local ok, names = pcall(function() return mesh:GetAllSocketNames() end)
    if ok and names ~= nil then
        for _, name in ipairs(names) do
            local str = type(name) == "string" and name or name:to_string()
            if str:lower():match("_muzzle$") then
                return str
            end
        end
    end
    for _, socket in ipairs(MUZZLE_SOCKET_FALLBACKS) do
        if mesh:DoesSocketExist(uevrUtils.fname_from_string(socket)) then
            return socket
        end
    end
    return nil
end

local function ensureMuzzleOnBarrel(pawn)
    local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
    if wpc == nil then return end
    local gun = uevrUtils.getValid(wpc.MultiModeGun)
    if gun == nil then return end
    local muzzle = uevrUtils.getValid(gun.MuzzlePoint)
    local mesh = uevrUtils.getValid(gun.SkeletalMesh or gun.Mesh)
    if muzzle == nil or mesh == nil then return end

    local asset = mesh.SkeletalMesh
    if asset == nil or (asset == lastMuzzleMeshAsset and muzzle == lastMuzzleComponent) then return end

    local socket = findMuzzleSocket(mesh)
    if socket == nil then return end

    -- 2 = EAttachmentRule::SnapToTarget
    muzzle:K2_AttachToComponent(mesh, uevrUtils.fname_from_string(socket), 2, 2, 2, false)
    lastMuzzleMeshAsset = asset
    lastMuzzleComponent = muzzle
    print("[hands] MuzzlePoint snapped to " .. socket .. " on " .. asset:get_fname():to_string())
end

restoreGunToNativeParent = function()
    local a = gunNativeAttach
    if a == nil then return end
    if uevrUtils.getValid(a.root) == nil or uevrUtils.getValid(a.parent) == nil then return end

    -- 0 = EAttachmentRule::KeepRelative, then put back the native offset
    a.root:K2_AttachToComponent(a.parent, a.socket, 0, 0, 0, false)
    uevrUtils.set_component_relative_transform(a.root, a.loc, a.rot)
    print("[hands] Gun root restored to native parent")
end

local function enterCutscene(pawn)
    if inCutscene then return end
    inCutscene = true
    print("[hands] Cutscene started")
    pcall(function() uevr.params.vr.set_decoupled_pitch_enabled(false) end)

    -- 1. Cleanly remove all UObjectHook motion controller states AND clear
    --    meshAttachmentList. Must happen BEFORE set_disabled so the remove
    --    calls still work.
    pcall(function() attachments.detachAllAttachments() end)

    -- 2. Disable UObjectHook (stops JSON persistent props like bVisible=0)
    setObjHookDisabled(true)

    -- 3. Hide VR hand PMCs
    hands.hideHands(true)
    pcall(function() ik.hide(true) end)

    -- 4. Show pawn.Mesh (per-tick also enforces this every frame)
    if pawn ~= nil then
        local mesh = uevrUtils.getValid(pawn.Mesh)
        if mesh ~= nil then
            pcall(function()
                mesh:SetVisibility(true, true)
                mesh:SetHiddenInGame(false, true)
            end)
        end
    end

    -- 5. Re-parent all weapons to pawn.Mesh
    attachWeaponsToPawnMesh(pawn)
    pcall(restoreGunToNativeParent)
end

local function exitCutscene()
    if not inCutscene then return end
    inCutscene = false  -- set FIRST so grip callback unblocks immediately
    print("[hands] Cutscene ended")
    pcall(function() uevr.params.vr.set_decoupled_pitch_enabled(true) end)

    local pawn = getPawn()

    -- 1. Detach VR-only weapons from pawn.Mesh so they can attach to PMCs.
    --    Native weapons (Gun, Flashlight) are left in their native sockets.
    if pawn ~= nil then
        pcall(function()
            local gun = getGunRoot(pawn)
            if gun ~= nil then
                gun:SetVisibility(true, true)
                gun:SetHiddenInGame(false, true)

                -- The engine hides the MultiModeGun *Actor* during cutscenes/interactions.
                -- We explicitly unhide it so it's ready when gameplay resumes.
                local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
                if wpc ~= nil then
                    local gunActor = uevrUtils.getValid(wpc.MultiModeGun)
                    if gunActor ~= nil then
                        gunActor.bHidden = false
                        pcall(function() gunActor:call("SetActorHiddenInGame", false) end)
                        print("[hands] Successfully forced MultiModeGun visible")
                    end
                end
            end
        end)
        pcall(function()
            local fl = getFlashlight(pawn)
            if fl ~= nil then
                fl:SetVisibility(true, true)
                fl:SetHiddenInGame(false, true)
            end
        end)
        pcall(function()
            local ft = uevrUtils.getValid(pawn.FlamethrowerSM)
            if ft ~= nil then ft:DetachFromParent(false, false) end
            local hv = uevrUtils.getValid(pawn.HarvesterSK)
            if hv ~= nil then hv:DetachFromParent(false, false) end
        end)
    end

    -- 2. Re-enable UObjectHook
    setObjHookDisabled(false)

    -- Force spotlight re-pin: clear the cache so the per-tick search
    -- immediately finds and re-attaches it to the left controller.
    if cachedSpotLight ~= nil then
        local savedSpotlight = cachedSpotLight
        uevrUtils.setTimeout(500, function()
            pcall(function()
                savedSpotlight:SetVisibility(true, true)
                savedSpotlight:SetHiddenInGame(false, true)
            end)
        end)
    end
    cachedSpotLight = nil
    spotLightSearchTime = 0

    -- 3. Hide pawn.Mesh
    if pawn ~= nil then
        local mesh = uevrUtils.getValid(pawn.Mesh)
        if mesh ~= nil then
            pcall(function()
                mesh:SetVisibility(false, true)
                mesh:SetHiddenInGame(true, true)
                
                -- The above propagated to all children, hiding the native weapons.
                -- We must immediately unhide them so they remain visible in VR.
                local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
                if wpc ~= nil then
                    local gunActor = uevrUtils.getValid(wpc.MultiModeGun)
                    if gunActor ~= nil then
                        local gunMesh = gunActor.SkeletalMesh
                        if not gunMesh then gunMesh = gunActor.Mesh end
                        gunMesh = uevrUtils.getValid(gunMesh)
                        if gunMesh ~= nil then
                            gunMesh:SetVisibility(true, true)
                            gunMesh:SetHiddenInGame(false, true)
                        end
                    end
                end
                
                local flm = uevrUtils.getValid(pawn.Flashlight_Mesh)
                if flm ~= nil then
                    flm:SetVisibility(true, true)
                    flm:SetHiddenInGame(false, true)
                end
            end)
        end
    end

    -- 4. Show VR hand PMCs
    hands.hideHands(false)
    pcall(function() ik.hide(false) end)

    -- 5. Re-attach flamethrower + harvester to hand PMCs.
    --    Delayed 200 ms to let UObjectHook fully re-enable first.
    uevrUtils.setTimeout(200, function()
        if not attachWeaponsToHands() then
            local retryTimer = nil
            retryTimer = uevrUtils.setInterval(500, function()
                if attachWeaponsToHands() then
                    uevrUtils.clearInterval(retryTimer)
                end
            end)
        end
    end)

    -- Gun (right) and flashlight (left): meshAttachmentList was cleared in
    -- enterCutscene, so the grip callback (now unblocked) will rebuild their
    -- UObjectHook / K2_AttachTo states from scratch on its next 200 ms cycle.
end


uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local player = uevr.api:get_player_controller(0)
    if player == nil then return end

    local ok, currentVT = pcall(function() return player:GetViewTarget() end)
    if not ok or currentVT == nil then return end

    local isCinematic = false
    if prevViewTarget ~= currentVT then
        prevViewTarget = currentVT
        local ok2, fullName = pcall(function() return currentVT:get_full_name() end)
        if ok2 then
            isCinematic = fullName:find("CineCamera", 1, true) ~= nil
            print("[hands] ViewTarget changed: " .. fullName .. " | cinematic=" .. tostring(isCinematic))
        end
    else
        -- If view target hasn't changed, we still need to know if it's cinematic
        local ok2, fullName = pcall(function() return currentVT:get_full_name() end)
        if ok2 then
            isCinematic = fullName:find("CineCamera", 1, true) ~= nil
        end
    end

    local pawn = getPawn()
    local isWallWalking = false
    if pawn ~= nil then
        local wallWalk = pawn.WallWalkComponent
        if wallWalk ~= nil then
            isWallWalking = wallWalk["isEnabled?"]
        end
    end

    local shouldBeInCutscene = isCinematic or isWallWalking

    if shouldBeInCutscene ~= inCutscene then
        if shouldBeInCutscene then
            enterCutscene(pawn)
        else
            exitCutscene()
        end
    end

    -- FORCE WEAPON VISIBILITY AFTER NATIVE GAME TICK
    if not inCutscene then
        local pawn = getPawn()
        if pawn ~= nil then
            pcall(ensureGunOnController, pawn)
            pcall(ensureMuzzleOnBarrel, pawn)
            pcall(ensureFlashlightOnIKForearm, pawn)
            pcall(function()
                -- 1. Force pawn.Mesh hidden
                local pawnMesh = uevrUtils.getValid(pawn.Mesh)
                if pawnMesh ~= nil then
                    if not pawnMesh.bHiddenInGame then
                        pawnMesh:SetHiddenInGame(true, true)
                    end
                    pawnMesh:SetVisibility(false, true)
                end

                -- 2. Force MultiModeGun visible (propagate true hides it, we unhide)
                local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
                if wpc ~= nil then
                    local gunActor = uevrUtils.getValid(wpc.MultiModeGun)
                    if gunActor ~= nil then
                        if gunActor.bHidden then
                            gunActor.bHidden = false
                            pcall(function() gunActor:call("SetActorHiddenInGame", false) end)
                        end
                        local mesh = gunActor.SkeletalMesh
                        if not mesh then mesh = gunActor.Mesh end
                        mesh = uevrUtils.getValid(mesh)
                        if mesh ~= nil then
                            if mesh.bHiddenInGame then
                                mesh:SetHiddenInGame(false, true)
                            end
                            mesh:SetVisibility(true, true)
                        end
                    end
                end

                -- 3. Force Flashlight_Mesh visible
                local flm = uevrUtils.getValid(pawn.Flashlight_Mesh)
                if flm ~= nil then
                    if flm.bHiddenInGame then
                        flm:SetHiddenInGame(false, true)
                    end
                    flm:SetVisibility(true, true)
                end

                -- 4. Force FlamethrowerSM and HarvesterSK visible
                local ft = uevrUtils.getValid(pawn.FlamethrowerSM)
                if ft ~= nil then
                    if ft.bHiddenInGame then
                        ft:SetHiddenInGame(false, true)
                    end
                    ft:SetVisibility(true, true)
                end

                local hv = uevrUtils.getValid(pawn.HarvesterSK)
                if hv ~= nil then
                    if hv.bHiddenInGame then
                        hv:SetHiddenInGame(false, true)
                    end
                    hv:SetVisibility(true, true)
                end
            end)
        end
    end
end)



-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Grip update callback â€” runs every 200 ms (attachments.lua interval)
--
-- Return order:
--   rightAttachment, rightMesh, rightSocket,
--   leftAttachment,  leftMesh,  leftSocket,
--   attachOptionsRight, attachOptionsLeft
--
-- Passing nil for rightMesh / leftMesh routes through
-- attachToRawController (UObjectHook motion-controller state).
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
attachments.registerOnGripUpdateCallback(function()
    -- During cutscenes all attachments should be detached â€” return nil to
    -- prevent the 200 ms interval from immediately re-attaching everything.
    if inCutscene then
        return nil, nil, nil, nil, nil, nil
    end

    local pawn = getPawn()
    if pawn == nil then
        return nil, nil, nil, nil, nil, nil
    end

    local gunRoot    = getGunRoot(pawn)    -- right hand
    local flashlight = getFlashlight(pawn) -- left  hand
    -- IK modes: the flashlight goes on the IK forearm instead (ensureFlashlightOnIKForearm); nil makes the
    -- library release it, and flashlightOptions leave it where it is
    if isIKMode() then flashlight = nil end
    -- Right: the gun on the pawn-owned proxy (getGunProxy: on the right controller in Hands mode, on the IK
    -- arm mesh in IK modes), like Atomic Heart attaches to its hand meshes. Not the raw controller: its
    -- UObjectHook state re-placed the gun on the controller at render time, ahead of the IK arm.
    -- "Gun on controller" off: the old raw-controller path.
    local gunMesh = nil
    if gunRoot ~= nil and configui.getValue("gunOnController") ~= false then
        gunMesh = getGunProxy(pawn, controllers.getController(1))
    end

    local leftHandMesh = getHandMesh(Handed.Left)

    return gunRoot,    gunMesh, "",                -- right: gun proxy (nil mesh = raw controller)
           flashlight, leftHandMesh, "lowerarm_l", -- left:  poseable mesh component
           gunOptions, flashlightOptions
end)

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Attach FlamethrowerSM  â†’ right hand PMC (Flamethrower_Attachment socket)
--        HarvesterSK     â†’ left  hand PMC (Harvester_Attachment socket)
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
attachWeaponsToHands = function()
    local p = getPawn()
    if p == nil then return false end

    local rightPMC = getHandMesh(Handed.Right)
    local leftPMC  = getHandMesh(Handed.Left)
    if rightPMC == nil or leftPMC == nil then return false end

    local flamethrower = uevrUtils.getValid(p.FlamethrowerSM)
    if flamethrower == nil then return false end

    local harvester = uevrUtils.getValid(p.HarvesterSK)
    if harvester == nil then return false end

    flamethrower:DetachFromParent(false, false)
    harvester:DetachFromParent(false, false)

    flamethrower:K2_AttachTo(rightPMC, uevrUtils.fname_from_string("Flamethrower_Attachment"), 0, false)
    harvester:K2_AttachTo(leftPMC,     uevrUtils.fname_from_string("Harvester_Attachment"),   0, false)

    uevrUtils.set_component_relative_transform(flamethrower, {X=0,Y=0,Z=0}, {Pitch=0,Yaw=0,Roll=0})
    uevrUtils.set_component_relative_transform(harvester,    {X=0,Y=0,Z=0}, {Pitch=0,Yaw=0,Roll=0})

    return true
end
_G.cronosAttachWeaponsToHands = attachWeaponsToHands

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Manage reticles: forces native reticles to 100% opacity and
-- extracts the active one into the 3D VR world using reticule.lua.
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- -----------------------------------------------------------------
local lastActiveWidget = nil

local function manageReticles()
    local pawn = getPawn()
    if pawn == nil then return false end
    
    local wpc = pawn.WeaponPlayerComponent
    if wpc ~= nil then
        -- Check the config toggle
        if not configui.getValue("enable3DReticle") then
            -- Destroy 3D reticle if it exists
            if reticule.exists() then
                reticule.destroy()
                lastActiveWidget = nil
            end
            -- Old behavior: agressively hide the native 2D crosshairs so they don't stick to the player's face
            local widgets = uevrUtils.find_all_of("Class /Script/Cronos.CronosWeaponRecticleWidget", false)
            if widgets ~= nil and #widgets > 0 then
                for _, w in ipairs(widgets) do
                    local valid = uevrUtils.getValid(w)
                    if valid ~= nil and valid.SetVisibility ~= nil then
                        pcall(function() valid:SetVisibility(1) end) -- ESlateVisibility::Hidden
                    end
                end
            end
            return true
        end

        -- 1. Force color and opacity to 100% for all reticles
        local containers = wpc.WeaponModesContainers
        if containers ~= nil then
            for _, container in ipairs(containers) do
                local ok, err = pcall(function()
                    local retComp = container.ReticleComponent
                    if retComp ~= nil then
                        local widget = retComp.ReticleWidget
                        if widget ~= nil then
                            -- Use a raw Lua table so UEVR auto-casts it to the exact struct type expected.
                            -- Crank RGB to 10.0 so the widget's own image renders fully white (it is drawn into
                            -- an 8-bit render target, so this clips at white; the VR brightness is the 3D
                            -- reticule component's tint, see updateWeaponReticule).
                            local color = {R = 10.0, G = 10.0, B = 10.0, A = 1.0}
                            pcall(function() widget:SetColorAndOpacity(color) end)
                            pcall(function() widget:SetRenderOpacity(100) end)
                        end
                    end
                end)
                if not ok then
                    print("[hands] Error setting reticle color: " .. tostring(err))
                end
            end
        end

        -- 2. Project active reticle into 3D
        pcall(function()
            local weapon_mode = wpc:GetWeaponModeContainer()
            if weapon_mode ~= nil then
                local activeWidget = weapon_mode:GetReticleWidget()
                if uevrUtils.getValid(activeWidget) ~= nil then
                    -- If the weapon switched, the active widget changed. 
                    -- Destroy the old 3D reticle so it can be recreated.
                    if activeWidget ~= lastActiveWidget then
                        reticule.destroy()
                        lastActiveWidget = activeWidget
                    end

                    if not reticule.exists() then
                        local options = { removeFromViewport = true, twoSided = true }
                        reticule.createFromWidget(activeWidget, options)
                    end
                end
            end
        end)
    end
    return true
end


-- -----------------------------------------------------------------
-- Level change — recreate controllers and VR hands every load
-- -----------------------------------------------------------------
local attachTimer  = nil
local reticleTimer = nil

function on_level_change(level)
    buildHands()

    -- Weapon PMC attachments
    if attachTimer ~= nil then
        uevrUtils.clearInterval(attachTimer)
        attachTimer = nil
    end
    if not attachWeaponsToHands() then
        attachTimer = uevrUtils.setInterval(500, function()
            if attachWeaponsToHands() then
                uevrUtils.clearInterval(attachTimer)
                attachTimer = nil
            end
        end)
    end

    -- UI State and Crosshair projection (continuous polling)
    if reticleTimer ~= nil then
        uevrUtils.clearInterval(reticleTimer)
        reticleTimer = nil
    end
    reticleTimer = uevrUtils.setInterval(200, function()
        manageReticles()
    end)
end

-- -----------------------------------------------------------------
-- Right Hand PUNCH Gesture -> R1 (Melee) mapping
-- -----------------------------------------------------------------
gestures.autoDetectGesture(gestures.Gesture.PUNCH, true, Handed.Right)

-- Punch trigger speed (libs/gestures "punch.minThresholdSpeed", default 180): how fast the right controller must
-- move forward for the melee punch. Set through the library's own config channel ("on_gesture_config_param_change",
-- which saves the parameter and re-applies it to the punch detectors); getConfigurationWidgets registers that
-- listener (its widgets aren't shown). Not persisted in gesture_parameters.json: the panel value is the source.
_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 6, label = "Melee", layout = {
    { widgetType = "slider_int", id = "punch_min_speed", label = "Punch speed needed (cm/s, higher = harder to trigger)", initialValue = 180, range = {50, 800} },
}})
pcall(gestures.getConfigurationWidgets)
configui.onCreateOrUpdate("punch_min_speed", function(value)
    if type(value) ~= "number" then return end
    uevrUtils.executeUEVRCallbacks("on_gesture_config_param_change", {"punch", "minThresholdSpeed"}, value, false)
end)

local punchResetTimer = nil

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local hasPunch = gestures.getGesture(gestures.Gesture.PUNCH)
    if hasPunch then
        local handsAnimation = require("libs/hands_animation")
        handsAnimation.setHoldingAttachment(Handed.Right, "punch")

        if punchResetTimer ~= nil then
            uevrUtils.clearTimeout(punchResetTimer)
        end

        punchResetTimer = uevrUtils.setTimeout(1500, function()
            handsAnimation.setHoldingAttachment(Handed.Right, nil)
            punchResetTimer = nil
        end)
    end
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    local hasPunch = gestures.getGesture(gestures.Gesture.PUNCH)
    if hasPunch then
        -- 0x0200 = XINPUT_GAMEPAD_RIGHT_SHOULDER (R1)
        uevrUtils.pressButton(state, 0x0200)
    end
end)



