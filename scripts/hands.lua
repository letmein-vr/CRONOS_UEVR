-- Cronos VR Profile - Main Entry Point
-- Manages VR hands (jbusfield libs) and weapon/flashlight attachments via attachments.lua.
-- Gun (MultiModeGun.RootComponent) → right controller
-- Flashlight (Flashlight_Mesh)      → left  controller
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
attachments.setLogLevel(LogLevel.Debug)

-- ─────────────────────────────────────────────────────────────────
-- Attachment options for both weapons
-- detachFromOriginOnGrip = false keeps the objects inside their
-- original game hierarchy (WeaponPlayerComponent / pawn) so the
-- game's own systems don't fight us. The motion-controller state
-- added by attachToRawController still overrides the final pose.
-- ─────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────
-- Initialize attachments with developer mode ON
-- → shows "Attachments Config Dev" panel in UEVR overlay
-- → loads / creates data/attachments_parameters.json
-- ─────────────────────────────────────────────────────────────────
attachments.init(true)
reticule.init(false)

-- ─────────────────────────────────────────────────────────────────
-- Pawn / mesh helpers
-- ─────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────
-- Flashlight SpotLight → Left Controller via UObjectHook
-- We find the SpotLightComponent named 'Light' inside Flashlight_BP_C
-- and pin it to the left hand motion controller every tick.
-- This completely overrides the game's internal aim system.
-- ─────────────────────────────────────────────────────────────────
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
            -- CDOs have "Default__" in their path — explicitly exclude them
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

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    -- ── Spotlight: find and pin to left controller ──────────────────
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

    -- ── Cutscene: force pawn.Mesh visible every tick ─────────────────
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

    -- ── Reticle: update 3D position ──────────────────────────────────
    if reticule.exists() then
        pcall(function()
            reticule.update(nil, reticule.getTargetLocationFromController(Handed.Right))
        end)
    end
end)


-- ─────────────────────────────────────────────────────────────────
-- Cutscene detection & handling
--
-- Uses player:GetViewTarget() to detect view target changes.
-- When the target contains "CineCamera" we disable UObjectHook
-- entirely (UEVR_UObjectHook.set_disabled), hide VR hands, and
-- re-parent weapon meshes back to pawn.Mesh.  On exit, everything
-- is restored and UObjectHook re-enabled.
-- ─────────────────────────────────────────────────────────────────

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

    -- Flamethrower → Flamethrower_Attachment socket (same name as on the hand PMC)
    local flamethrower = uevrUtils.getValid(pawn.FlamethrowerSM)
    if flamethrower ~= nil then
        pcall(function()
            flamethrower:DetachFromParent(false, false)
            flamethrower:K2_AttachTo(mesh, uevrUtils.fname_from_string("Flamethrower_Attachment"), 0, false)
        end)
    end

    -- Harvester → Harvester_Attachment socket (same name as on the hand PMC)
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

local function enterCutscene(pawn)
    if inCutscene then return end
    inCutscene = true
    print("[hands] Cutscene started")

    -- 1. Cleanly remove all UObjectHook motion controller states AND clear
    --    meshAttachmentList. Must happen BEFORE set_disabled so the remove
    --    calls still work.
    pcall(function() attachments.detachAllAttachments() end)

    -- 2. Disable UObjectHook (stops JSON persistent props like bVisible=0)
    setObjHookDisabled(true)

    -- 3. Hide VR hand PMCs
    hands.hideHands(true)

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
end

local function exitCutscene()
    if not inCutscene then return end
    inCutscene = false  -- set FIRST so grip callback unblocks immediately
    print("[hands] Cutscene ended")

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

    if prevViewTarget ~= currentVT then
        prevViewTarget = currentVT

        local ok2, fullName = pcall(function() return currentVT:get_full_name() end)
        if not ok2 then return end

        local isCinematic = fullName:find("CineCamera", 1, true) ~= nil
        print("[hands] ViewTarget changed: " .. fullName .. " | cinematic=" .. tostring(isCinematic))

        if isCinematic then
            enterCutscene(getPawn())
        else
            exitCutscene()
        end
    end

    -- FORCE WEAPON VISIBILITY AFTER NATIVE GAME TICK
    if not inCutscene then
        local pawn = getPawn()
        if pawn ~= nil then
            pcall(function()
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
            end)
        end
    end
end)



-- ─────────────────────────────────────────────────────────────────
-- Grip update callback — runs every 200 ms (attachments.lua interval)
--
-- Return order:
--   rightAttachment, rightMesh, rightSocket,
--   leftAttachment,  leftMesh,  leftSocket,
--   attachOptionsRight, attachOptionsLeft
--
-- Passing nil for rightMesh / leftMesh routes through
-- attachToRawController (UObjectHook motion-controller state).
-- ─────────────────────────────────────────────────────────────────
attachments.registerOnGripUpdateCallback(function()
    -- During cutscenes all attachments should be detached — return nil to
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
    
    local leftHandMesh = hands.getHandComponent(Handed.Left)

    return gunRoot,    nil, nil,                   -- right: raw controller
           flashlight, leftHandMesh, "lowerarm_l", -- left:  poseable mesh component
           gunOptions, flashlightOptions
end)

-- ─────────────────────────────────────────────────────────────────
-- Attach FlamethrowerSM  → right hand PMC (Flamethrower_Attachment socket)
--        HarvesterSK     → left  hand PMC (Harvester_Attachment socket)
-- ─────────────────────────────────────────────────────────────────
attachWeaponsToHands = function()
    local p = getPawn()
    if p == nil then return false end

    local rightPMC = hands.getHandComponent(Handed.Right)
    local leftPMC  = hands.getHandComponent(Handed.Left)
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

-- ─────────────────────────────────────────────────────────────────
-- Manage reticles: forces native reticles to 100% opacity and
-- extracts the active one into the 3D VR world using reticule.lua.
-- ─────────────────────────────────────────────────────────────────
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
                            -- Crank RGB to 10.0 for HDR brightness so it's stark white in VR.
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

-- ─────────────────────────────────────────────────────────────────
-- Level change — recreate controllers and VR hands every load
-- ─────────────────────────────────────────────────────────────────
local attachTimer  = nil
local reticleTimer = nil

function on_level_change(level)
    controllers.createController(0)  -- left  MotionControllerComponent
    controllers.createController(1)  -- right MotionControllerComponent
    hands.reset()

    local paramsFile    = 'hands_parameters'
    local configName    = 'Main'
    local animationName = 'Shared'
    hands.createFromConfig(paramsFile, configName, animationName)

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

    -- Crosshair projection (continuous polling to catch weapon switching)
    if reticleTimer ~= nil then
        uevrUtils.clearInterval(reticleTimer)
        reticleTimer = nil
    end
    reticleTimer = uevrUtils.setInterval(200, function()
        manageReticles()
    end)
end

-- ─────────────────────────────────────────────────────────────────
-- Right Hand PUNCH Gesture -> R1 (Melee) mapping
-- ─────────────────────────────────────────────────────────────────
gestures.autoDetectGesture(gestures.Gesture.PUNCH, true, Handed.Right)

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