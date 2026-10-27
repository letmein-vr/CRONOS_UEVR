-- Cronos two-handed weapon aiming (reworked 2026-10-26 after the Hellraiser profile's two_handed.lua).
--
-- A weapon can be two-handed when its profile has a left-hand socket (lhSocket). To grab: bring the left
-- controller to the grip point (the lhSocket on the weapon mesh plus the per-weapon grip offset) and hold the
-- grab button (left grip by default). While held:
--   * the gun root is turned every view so its barrel points from the right hand towards the left hand
--     (libs/two_handed_aiming.lua). It is put back on its un-pivoted base transform first each time, so the
--     pivot is idempotent (the gun lives on the controller proxy from hands.lua, which nothing resets);
--   * Hands mode: the left glove glides onto the lhSocket (per-weapon lhPmc offsets); the right glove already
--     sits on the gun's GG_handle socket, so both follow the pivot;
--   * IK modes: libs/ik.lua's accessory targets. These are virtual controllers (ik.lua still applies the
--     solver's end-bone offsets on top), so the left target is the LEFT CONTROLLER's pose in the socket's
--     space and the right target is the right controller's pose in the un-pivoted gun's space. Both hands
--     stay exactly where they were at the moment of the grab, and the right hand turns with the gun;
--   * the left hand holds the weapon's captured grip pose (or the built-in fallback pose);
--   * the grab button is hidden from the game while two-handing or near the grip point (left grip = mines).
-- Releasing the button, or moving the left controller beyond the release radius, glides the hand back.
--
-- Flashlight toggle: put the right controller inside the flashlight zone (a sphere at the left hand plus the
-- fl offsets, radius flDetectRadius) and press right grip. The grip is hidden from the game (no melee).
--
-- Debug spheres ("Show debug spheres" in Dev Config) mark the grip point and the flashlight zone centre.

local twoHandedAiming = require("libs/two_handed_aiming")
local controllers = require("libs/controllers")
local uevrUtils = require("libs/uevr_utils")
local configui = require("libs/configui")
local hands = require("libs/hands")
local animation = require("libs/animation")
local gestures = require("libs/gestures")
local ik = require("libs/ik")
local api = uevr.api
local vr = uevr.params.vr

local BTN_LEFT_GRIP  = 0x0100 -- XINPUT_GAMEPAD_LEFT_SHOULDER
local BTN_RIGHT_GRIP = 0x0200 -- XINPUT_GAMEPAD_RIGHT_SHOULDER

-- hands.lua owns the Hands / IK mode; it loads first and exports this
local function isIKMode()
    return _G.cronosIsIKMode ~= nil and _G.cronosIsIKMode() == true
end

local weaponProfiles = {}
local profilesFile = "cronos_weapon_profiles"
local currentWeapon = "None"

local function loadProfiles()
    local params = json.load_file(profilesFile .. ".json")
    if params ~= nil then
        weaponProfiles = params
    end
end
local function saveProfiles()
    json.dump_file(profilesFile .. ".json", weaponProfiles, 4)
end
loadProfiles()

local function getEquippedWeaponForCronos(pawn)
    if not pawn then return nil, nil, nil end
    local ok, result1, result2, result3 = pcall(function()
        local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
        if wpc == nil then return nil, nil, nil end

        local gun = uevrUtils.getValid(wpc.MultiModeGun)
        if gun == nil then return nil, nil, nil end

        -- The engine leaves the weapon hidden after mantling. Force it visible!
        if gun.bHidden then
            gun.bHidden = false
            pcall(function() gun:call("SetActorHiddenInGame", false) end)
        end

        local root = uevrUtils.getValid(gun.RootComponent)

        local mesh = gun.SkeletalMesh  -- the SkeletalMeshComponent on the actor
        if not mesh then mesh = gun.Mesh end

        if mesh then
            mesh = uevrUtils.getValid(mesh)
            if mesh then
                -- CRITICAL: Prevent the engine from freezing bone evaluation when it natively hides the mesh!
                -- 0 = EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones
                mesh.VisibilityBasedAnimTickOption = 0

                -- The game also hides the mesh, which stops bone animation,
                -- causing both the gun and the hand PMC to collapse to origin.
                pcall(function()
                    mesh:SetHiddenInGame(false, true)
                    mesh:SetVisibility(true, true)
                end)
            end
        end

        local skelName = "Unknown"
        if mesh then
            local skelMesh = mesh.SkeletalMesh  -- the actual asset inside the component
            if skelMesh then
                -- fname is like "SK_ShotGun_01": strip the trailing _NN suffix and the SK_ prefix
                local fname = skelMesh:get_fname():to_string()
                skelName = string.gsub(fname, "_%d+$", "")
                skelName = string.gsub(skelName, "^SK_", "")
            end
        end
        return root, mesh, skelName
    end)
    if ok then return result1, result2, result3 end
    return nil, nil, nil
end

local isAlive = function(obj)
    if obj == nil then return false end
    local ok, alive = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and alive
end

-- for components we create ourselves (exists() can reject freshly created objects)
local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local hitResult = nil
local function getHitResult()
    if hitResult == nil then
        hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
    end
    return hitResult
end

-- ==========================================
-- Per-level state, reset whenever the pawn changes
-- ==========================================
local lastPawn             = nil
local handParentedToGun    = false
local pmcBaseTransform     = nil
local flashlightOn         = true  -- current spotlight visibility state
local rightGripWasDown     = false -- edge-detection for right grip
local cachedFlashFL        = nil   -- cached SpotLightComponent for toggle
local flSearchTime         = 0
local punchAnimationActive = false -- true for 1.5s after a punch fires
local cachedFlashShaft     = nil   -- cached FlashlightShaft StaticMeshComponent
local flashZoneOverlapping = false -- true when the right controller is inside the flashlight zone

-- two-handing
local active          = false   -- two-handing right now
local activeInIKMode  = false
local grabDown        = false   -- configured grab button, raw (before the game sees it)
local inGrabZone      = false   -- left controller within the grab radius of a two-handable weapon
local lastLeftButtons = 0
local pivotArgs       = nil     -- { root, rightHand, leftHand } while two-handing
local gunBase         = nil     -- { root, parent, loc, rot } the gun root's un-pivoted relative transform
local markers         = {}      -- [name] = debug sphere

-- Once-per-tick gate for the stereo callback: on_post_calculate_stereo_view_offset fires once per view
-- (2x in Native Stereo, 1x in AFW/AFR/Synced Sequential). Reset in on_pre_engine_tick.
local stereoRanThisTick = false

-- Find the flashlight SpotLightComponent (same criteria as hands.lua)
local FLASH_SPOT_CLASS = "Class /Script/Engine.SpotLightComponent"
local function findSpotlightForToggle()
    local cls = uevr.api:find_uobject(FLASH_SPOT_CLASS)
    if not cls then return nil end
    local instances = UEVR_UObjectHook.get_objects_by_class(cls, false)
    if not instances then return nil end
    for _, obj in ipairs(instances) do
        local ok, name = pcall(function() return obj:get_full_name() end)
        if ok and name
        and name:find("Flashlight_BP_C")
        and name:match("%.Light$")
        and not name:find("Default__") then
            return obj
        end
    end
    return nil
end

-- Find the FlashlightShaft StaticMeshComponent on the player character
local FLASH_SHAFT_CLASS = "Class /Script/Engine.StaticMeshComponent"
local function findFlashlightShaftForToggle()
    local cls = uevr.api:find_uobject(FLASH_SHAFT_CLASS)
    if not cls then return nil end
    local instances = UEVR_UObjectHook.get_objects_by_class(cls, false)
    if not instances then return nil end
    for _, obj in ipairs(instances) do
        local ok, name = pcall(function() return obj:get_full_name() end)
        if ok and name
        and name:find("CronosCharacterPlay_BP_C")
        and name:match("%.FlashlightShaft$")
        and not name:find("Default__") then
            return obj
        end
    end
    return nil
end

-- ==========================================
-- Left hand grip poses
-- ==========================================
-- Bone-space finger rotations forced onto the left hand while two-handing, used when the weapon has no
-- captured pose. Format: { boneName = { rotation = {Pitch, Yaw, Roll} } }
local LH_GRIP_POSE = {
    middle_01_l = { rotation = {  2.25,    -87.75,    0.0     } },
    middle_02_l = { rotation = { -1.1251,  -60.1441,  0.0     } },
    middle_03_l = { rotation = {  0.0,     -51.625,   0.0     } },
    pinky_01_l  = { rotation = { 30.3749,  -87.75,    0.0     } },
    pinky_02_l  = { rotation = { -1.125,   -60.1441,  0.0     } },
    pinky_03_l  = { rotation = {  0.0,     -51.625,   0.0     } },
    ring_01_l   = { rotation = { 12.3749,  -87.75,    0.0     } },
    ring_02_l   = { rotation = { -1.1251,  -60.1441,  0.0     } },
    ring_03_l   = { rotation = {  0.0,     -51.625,   0.0     } },
    thumb_01_l  = { rotation = {-36.0,     -23.8841,  73.5643 } },
    thumb_02_l  = { rotation = {  4.5,     -49.121,   3.5306  } },
    thumb_03_l  = { rotation = {  0.0,     -49.3751,  0.0     } },
    index_01_l  = { rotation = { -1.1251,  -67.2481,  0.0     } },
    index_02_l  = { rotation = {  0.0,     -65.518,   0.0     } },
    index_03_l  = { rotation = {  0.0,     -35.016,   0.0     } },
}

local LH_GRIP_POSE_SHOTGUN = {
    middle_01_l = { rotation = { 0.0,      -31.5727,  0.0     } },
    middle_02_l = { rotation = { 0.0,      -20.7693,  0.0     } },
    middle_03_l = { rotation = { 0.0,      -10.0001,  0.0     } },
    pinky_01_l  = { rotation = {-0.6051,   -14.8338,  10.4916 } },
    pinky_02_l  = { rotation = { 0.0,      -21.2871,  0.0     } },
    pinky_03_l  = { rotation = { 0.0,       -4.917,   0.0     } },
    ring_01_l   = { rotation = { 0.1169,   -29.4145,  6.3958  } },
    ring_02_l   = { rotation = { 0.0,      -18.9641,  0.0     } },
    ring_03_l   = { rotation = { 0.0,       -9.168,   0.0     } },
    thumb_01_l  = { rotation = {-39.9042,  -20.5087,  73.5643 } },
    thumb_02_l  = { rotation = { 1.9323,   -23.2461,  3.5307  } },
    thumb_03_l  = { rotation = { 0.0,      -10.0001,  0.0     } },
    index_01_l  = { rotation = { 0.0,      -23.373,   0.0     } },
    index_02_l  = { rotation = { 0.0,      -14.8926,  0.0     } },
    index_03_l  = { rotation = { 0.0,      -12.5164,  0.0     } },
}

-- fallback poses keyed by skelName (same as currentWeapon)
local LH_WEAPON_POSES = {
    ShotGun = LH_GRIP_POSE_SHOTGUN,
}

-- ==========================================
-- Right hand (Hands mode): glove PMC on the gun's GG_handle socket
-- ==========================================
local GUN_SOCKET = "GG_handle"

local function captureBaseTransform(pmc)
    if pmcBaseTransform then return end  -- only capture once
    pcall(function()
        pmcBaseTransform = {
            locX = pmc.RelativeLocation.X,
            locY = pmc.RelativeLocation.Y,
            locZ = pmc.RelativeLocation.Z,
            rotPitch = pmc.RelativeRotation.Pitch,
            rotYaw   = pmc.RelativeRotation.Yaw,
            rotRoll  = pmc.RelativeRotation.Roll,
        }
    end)
end

-- IK modes have no right glove PMC: the IK right hand targets the controller, and the gun is
-- on the controller proxy (hands.lua), so they line up without parenting
local function getRightPMC()
    if isIKMode() then return nil end
    return hands.getHandComponent(Handed.Right)
end

local function setPMCOffsetFromConfig(pmc)
    local loc = uevrUtils.vector(
        configui.getValue("pmcOffX") or 0,
        configui.getValue("pmcOffY") or 0,
        configui.getValue("pmcOffZ") or 0
    )
    local rot = uevrUtils.rotator(
        configui.getValue("pmcRotPitch") or 0,
        configui.getValue("pmcRotYaw")   or 0,
        configui.getValue("pmcRotRoll")  or 0
    )
    pmc:K2_SetRelativeLocation(loc, false, getHitResult(), false)
    pmc:K2_SetRelativeRotation(rot, false, getHitResult(), false)
end

local function attachPMCToGun(pmc, weaponMesh)
    -- SnapToTarget (2), then the per-weapon offsets
    local ok = pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(GUN_SOCKET), 2, false)
    if ok then
        setPMCOffsetFromConfig(pmc)
        pmc.RelativeScale3D.X = 1.0
        pmc.RelativeScale3D.Y = 1.0
        pmc.RelativeScale3D.Z = 1.0
    end
end

local function attachPMCToController(pmc)
    controllers.attachComponentToController(1, pmc)
    if pmcBaseTransform then
        local loc = uevrUtils.vector(pmcBaseTransform.locX, pmcBaseTransform.locY, pmcBaseTransform.locZ)
        local rot = uevrUtils.rotator(pmcBaseTransform.rotPitch, pmcBaseTransform.rotYaw, pmcBaseTransform.rotRoll)
        pmc:K2_SetRelativeLocation(loc, false, getHitResult(), false)
        pmc:K2_SetRelativeRotation(rot, false, getHitResult(), false)
    end
    pmc.RelativeScale3D.X = 1.0
    pmc.RelativeScale3D.Y = 1.0
    pmc.RelativeScale3D.Z = 1.0
end

-- Apply live PMC offset changes while gun-parented
local function applyPMCOffset(pmc)
    if not isAlive(pmc) or not handParentedToGun then return end
    pcall(function() setPMCOffsetFromConfig(pmc) end)
end

-- ==========================================
-- Config UI
-- ==========================================
-- Section of the merged "Cronos VR" panel (built by zz_cronos_vr_panel.lua; its DEV_RULES pick what stays in
-- the main panel, the rest goes under Dev Config). Values marked "per weapon" are saved into
-- data/cronos_weapon_profiles.json under the weapon's mesh name.
_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 2, label = "Two-Handed Aiming", layout = {
            { widgetType = "checkbox", id = "twoHandEnabled", label = "Enable 2-Handing", initialValue = true },
            { widgetType = "slider_float", id = "lhGlide", label = "Left hand glide onto / off the gun (s, 0 = snap)", initialValue = 0.15, range = {0.0, 0.6} },
            { widgetType = "combo", id = "th_grab_button", label = "Grab button", initialValue = 1, selections = {"Left grip", "Left trigger"} },
            { widgetType = "checkbox", id = "th_suppress_grab", label = "Hide grab button from game near the grip / while two-handing", initialValue = true },
            { widgetType = "checkbox", id = "th_snap_left_hand", label = "Snap left hand to grip", initialValue = true },
            { widgetType = "slider_float", id = "th_grab_radius", label = "Grab radius (cm)", initialValue = 16.0, range = {3.0, 40.0} },
            { widgetType = "slider_float", id = "th_release_radius", label = "Release radius (cm)", initialValue = 40.0, range = {5.0, 100.0} },
            { widgetType = "spacing" },
            { widgetType = "text", id = "weapon_label", label = "Current Weapon: None" },
            { widgetType = "text", id = "th_status_label", label = "Status: idle" },
            { widgetType = "checkbox", id = "th_show_markers", label = "Show debug spheres (grip point, flashlight zone)", initialValue = false },
            { widgetType = "checkbox", id = "forceTwoHand", label = "Force 2-Handing ON (dev)", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Grip point (per weapon): LH socket + offset in the socket's space" },
            { widgetType = "input_text", id = "lhSocket", label = "LH Socket Name (blank = not two-handable)", initialValue = "", width = 280 },
            { widgetType = "slider_float", id = "gripOffX", label = "Grip Offset X", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "slider_float", id = "gripOffY", label = "Grip Offset Y", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "slider_float", id = "gripOffZ", label = "Grip Offset Z", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left hand pose while two-handing (per weapon)" },
            { widgetType = "text", id = "th_pose_label", label = "Pose: none" },
            { widgetType = "checkbox", id = "th_apply_pose", label = "Apply grip pose while two-handing", initialValue = true },
            { widgetType = "button", id = "th_capture_pose", label = "Get left hand pose from game body mesh", size = {280, 24} },
            { widgetType = "button", id = "th_clear_pose", label = "Clear left hand pose", size = {180, 24} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Right Hand, Hands mode (glove -> GG_handle socket, per weapon)" },
            { widgetType = "slider_float", id = "pmcOffX",    label = "PMC Offset X",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcOffY",    label = "PMC Offset Y",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcOffZ",    label = "PMC Offset Z",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcRotPitch",label = "PMC Rot Pitch",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "pmcRotYaw",  label = "PMC Rot Yaw",     initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "pmcRotRoll", label = "PMC Rot Roll",    initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Right Hand, IK modes (moves the IK hand on the gun; controller space, per weapon)" },
            { widgetType = "slider_float", id = "ikRhOffX",    label = "IK RH Offset X",  initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "ikRhOffY",    label = "IK RH Offset Y",  initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "ikRhOffZ",    label = "IK RH Offset Z",  initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "ikRhRotPitch",label = "IK RH Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "ikRhRotYaw",  label = "IK RH Rot Yaw",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "ikRhRotRoll", label = "IK RH Rot Roll",  initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left Hand, Hands mode (glove -> LH socket when snapping, per weapon)" },
            { widgetType = "slider_float", id = "lhPmcOffX",    label = "LH PMC Offset X",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcOffY",    label = "LH PMC Offset Y",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcOffZ",    label = "LH PMC Offset Z",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcRotPitch",label = "LH PMC Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "lhPmcRotYaw",  label = "LH PMC Rot Yaw",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "lhPmcRotRoll", label = "LH PMC Rot Roll",  initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left Hand, IK modes (left controller pose in the LH socket's space when snapping;" },
            { widgetType = "text", label = "   per weapon, set from the first grab)" },
            { widgetType = "slider_float", id = "ikLhOffX",    label = "IK LH Offset X",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "ikLhOffY",    label = "IK LH Offset Y",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "ikLhOffZ",    label = "IK LH Offset Z",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "ikLhRotPitch",label = "IK LH Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "ikLhRotYaw",  label = "IK LH Rot Yaw",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "ikLhRotRoll", label = "IK LH Rot Roll",  initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Flashlight toggle zone (left hand offset; right controller + right grip)" },
            { widgetType = "slider_float", id = "flOffX",    label = "FL Offset X",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flOffY",    label = "FL Offset Y",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flOffZ",    label = "FL Offset Z",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flDetectRadius", label = "FL Zone Radius (cm)", initialValue = 15.0, range = {3.0, 40.0} },
}})

-- The flashlight's spotlight on the left controller (applied by hands.lua), saved per weapon
table.insert(_G.CRONOS_SECTIONS, { order = 4.5, label = "Flashlight Spotlight", layout = {
            { widgetType = "text", id = "sl_weapon_label", label = "Saved for weapon: None" },
            { widgetType = "slider_float", id = "slOffX",    label = "Spotlight Offset X",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slOffY",    label = "Spotlight Offset Y",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slOffZ",    label = "Spotlight Offset Z",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slRotPitch",label = "Spotlight Rot Pitch",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "slRotYaw",  label = "Spotlight Rot Yaw",     initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "slRotRoll", label = "Spotlight Rot Roll",    initialValue = 0.0, range = {-180.0, 180.0} },
}})

-- Saved per weapon. GEOMETRY ids (the weapon's own values) fall back to their default when a weapon has none;
-- the flashlight toggle zone ids keep the previous weapon's value instead.
local GEOMETRY_DEFAULTS = {
    pmcOffX = 0, pmcOffY = 0, pmcOffZ = 0, pmcRotPitch = 0, pmcRotYaw = 0, pmcRotRoll = 0,
    lhPmcOffX = 0, lhPmcOffY = 0, lhPmcOffZ = 0, lhPmcRotPitch = 0, lhPmcRotYaw = 0, lhPmcRotRoll = 0,
    lhSocket = "", gripOffX = 0, gripOffY = 0, gripOffZ = 0,
    ikLhOffX = 0, ikLhOffY = 0, ikLhOffZ = 0, ikLhRotPitch = 0, ikLhRotYaw = 0, ikLhRotRoll = 0,
    ikRhOffX = 0, ikRhOffY = 0, ikRhOffZ = 0, ikRhRotPitch = 0, ikRhRotYaw = 0, ikRhRotRoll = 0,
    slOffX = 0, slOffY = 0, slOffZ = 0, slRotPitch = 0, slRotYaw = 0, slRotRoll = 0,
}
local CARRY_IDS = {
    "flOffX","flOffY","flOffZ","flDetectRadius",
}
local IK_GRIP_IDS = { "ikLhOffX", "ikLhOffY", "ikLhOffZ", "ikLhRotPitch", "ikLhRotYaw", "ikLhRotRoll" }

local function status(text)
    configui.setLabel("th_status_label", "Status: " .. text)
end

local function snapLeft()
    return configui.getValue("th_snap_left_hand") ~= false
end

local function getLHSocket()
    local socketName = configui.getValue("lhSocket")
    if socketName == nil then return "" end
    return socketName
end

local function updatePoseLabel()
    local profile = weaponProfiles[currentWeapon]
    local pose = profile and profile.leftPose
    local n = 0
    if pose ~= nil then for _ in pairs(pose) do n = n + 1 end end
    if pose ~= nil then
        configui.setLabel("th_pose_label", "Pose: " .. n .. " bones captured")
    elseif LH_WEAPON_POSES[currentWeapon] ~= nil then
        configui.setLabel("th_pose_label", "Pose: built-in " .. currentWeapon .. " pose")
    else
        configui.setLabel("th_pose_label", "Pose: built-in default pose")
    end
end

local function applyProfileValues(weaponName)
    local profile = weaponProfiles[weaponName] or {}
    for id, default in pairs(GEOMETRY_DEFAULTS) do
        local v = profile[id]
        if v == nil then v = default end
        configui.setValue(id, v, true)
    end
    for _, id in ipairs(CARRY_IDS) do
        if profile[id] ~= nil then configui.setValue(id, profile[id], true) end
    end
    updatePoseLabel()
end

local function saveProfileValue(id, value)
    if currentWeapon == "None" then return end
    if weaponProfiles[currentWeapon] == nil then weaponProfiles[currentWeapon] = {} end
    weaponProfiles[currentWeapon][id] = value
    saveProfiles()
end

-- ==========================================
-- Transform helpers. Socket frames are built WITHOUT scale, matching libs/ik.lua's accessory target
-- (socket location + offset rotated by the socket rotation).
-- ==========================================
local function unitTransform(loc, rot)
    return kismet_math_library:MakeTransform(loc, rot, uevrUtils.vector(1, 1, 1))
end

local function socketTransform(comp, socket)
    local name = uevrUtils.fname_from_string(socket or "")
    return unitTransform(comp:GetSocketLocation(name), comp:GetSocketRotation(name))
end

local function componentTransform(comp)
    return unitTransform(comp:K2_GetComponentLocation(), comp:K2_GetComponentRotation())
end

local function toLocal(xf, worldLoc, worldRot)
    local l = kismet_math_library:InverseTransformLocation(xf, worldLoc)
    local r = kismet_math_library:InverseTransformRotation(xf, worldRot)
    return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

local function fromLocal(xf, loc, rot)
    local l = kismet_math_library:TransformLocation(xf, uevrUtils.vector(loc.X, loc.Y, loc.Z))
    local r = kismet_math_library:TransformRotation(xf, uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll))
    return l, r
end

local function relativeOf(comp)
    local l, r = comp.RelativeLocation, comp.RelativeRotation
    return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- World-space grip point: the weapon's LH socket plus the per-weapon grip offset in the socket's space
local function getGripPoint(weaponMesh)
    local xf = socketTransform(weaponMesh, getLHSocket())
    return kismet_math_library:TransformLocation(xf, uevrUtils.vector(
        configui.getValue("gripOffX") or 0, configui.getValue("gripOffY") or 0, configui.getValue("gripOffZ") or 0))
end

-- ==========================================
-- Debug spheres (2 cm engine spheres, no collision)
-- ==========================================
local function setMarker(name, point)
    local m = markers[name]
    if point == nil or configui.getValue("th_show_markers") ~= true then
        if m ~= nil then
            if alive(m) then pcall(function() uevrUtils.destroyComponent(m, true, true) end) end
            markers[name] = nil
        end
        return
    end
    if not alive(m) then
        m = nil
        pcall(function()
            m = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/EngineMeshes/Sphere.Sphere", { visible = true, collisionEnabled = false })
            if m ~= nil then
                uevrUtils.set_component_relative_transform(m, nil, nil, { X = 0.02, Y = 0.02, Z = 0.02 })
            end
        end)
        markers[name] = m
    end
    if m ~= nil then
        pcall(function() m:K2_SetWorldLocation(point, false, getHitResult(), false) end)
    end
end

local function destroyMarkers()
    for name, m in pairs(markers) do
        if alive(m) then pcall(function() uevrUtils.destroyComponent(m, true, true) end) end
        markers[name] = nil
    end
end

-- ==========================================
-- Glide (cubic ease-out over lhGlide seconds, 0 = snap)
-- ==========================================
local function glideTime()
    local v = configui.getValue("lhGlide")
    return type(v) == "number" and v or 0.15
end

local function easeOut(t0, dur)
    local a = math.min(1.0, (os.clock() - t0) / dur)
    return 1 - (1 - a) ^ 3, a >= 1.0
end

local function lerpLoc(s, e, t)
    return { X = s.X + (e.X - s.X) * t, Y = s.Y + (e.Y - s.Y) * t, Z = s.Z + (e.Z - s.Z) * t }
end

local function lerpRot(s, e, t)
    local r = kismet_math_library:RLerp(uevrUtils.rotator(s.Pitch, s.Yaw, s.Roll), uevrUtils.rotator(e.Pitch, e.Yaw, e.Roll), t, true)
    return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

-- ==========================================
-- Left hand, Hands mode: the glove PMC is re-parented onto the gun. The glide runs in the parent's space,
-- so the pivoting gun never makes the hand chase.
-- ==========================================
local leftGlide = nil -- { pmc, sLoc, sRot, eLoc, eRot, t0, dur }
local leftHome  = nil -- { pmc, parent, socket, loc, rot }: the glove's place on the controller

local function setRelative(pmc, loc, rot)
    uevrUtils.set_component_relative_transform(pmc, loc, rot, { X = 1, Y = 1, Z = 1 })
end

local function startLeftGlide(pmc, sLoc, sRot, eLoc, eRot)
    local dur = glideTime()
    if dur <= 0 then
        leftGlide = nil
        pcall(setRelative, pmc, eLoc, eRot)
        return
    end
    leftGlide = { pmc = pmc, sLoc = sLoc, sRot = sRot, eLoc = eLoc, eRot = eRot, t0 = os.clock(), dur = dur }
    pcall(setRelative, pmc, sLoc, sRot)
end

local function updateLeftGlide()
    local g = leftGlide
    if g == nil then return end
    if not isAlive(g.pmc) then leftGlide = nil return end
    local e, done = easeOut(g.t0, g.dur)
    local ok = pcall(setRelative, g.pmc, lerpLoc(g.sLoc, g.eLoc, e), lerpRot(g.sRot, g.eRot, e))
    if not ok or done then leftGlide = nil end
end

-- While idle, remember where the hands lib keeps the glove on the controller
local function updateLeftHome(pmc)
    if active or leftGlide ~= nil or not isAlive(pmc) then return end
    pcall(function()
        local loc, rot = relativeOf(pmc)
        leftHome = { pmc = pmc, parent = pmc.AttachParent, socket = pmc.AttachSocketName, loc = loc, rot = rot }
    end)
end

local function lhPmcTarget()
    return { X = configui.getValue("lhPmcOffX") or 0, Y = configui.getValue("lhPmcOffY") or 0, Z = configui.getValue("lhPmcOffZ") or 0 },
           { Pitch = configui.getValue("lhPmcRotPitch") or 0, Yaw = configui.getValue("lhPmcRotYaw") or 0, Roll = configui.getValue("lhPmcRotRoll") or 0 }
end

local function attachLeftGloveToGun(pmc, weaponMesh)
    -- KeepWorld (1): the hand stays where the controller put it, now in the socket's space (glide start)
    pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(getLHSocket()), 1, false)
    local sLoc, sRot = relativeOf(pmc)
    local eLoc, eRot = sLoc, sRot
    if snapLeft() then eLoc, eRot = lhPmcTarget() end
    startLeftGlide(pmc, sLoc, sRot, eLoc, eRot)
end

local function releaseLeftGlove(pmc)
    leftGlide = nil
    if not isAlive(pmc) then return end
    local home = (leftHome ~= nil and leftHome.pmc == pmc) and leftHome or nil
    local parent = (home ~= nil and isAlive(home.parent)) and home.parent or controllers.getController(0)
    if parent == nil then return end
    local ok = pcall(function()
        -- back onto the controller without moving, then glide home
        pmc:K2_AttachTo(parent, home ~= nil and home.socket or uevrUtils.fname_from_string(""), 1, false)
        local sLoc, sRot = relativeOf(pmc)
        if home ~= nil then
            startLeftGlide(pmc, sLoc, sRot, home.loc, home.rot)
        end
    end)
    if not ok or home == nil then
        pcall(function()
            pmc:DetachFromParent(false, false)
            controllers.attachComponentToController(0, pmc)
        end)
    end
end

-- live lhPmc slider changes while gripping
local function refreshLeftGlove()
    if not active or activeInIKMode or not snapLeft() then return end
    local pmc = hands.getHandComponent(Handed.Left)
    if not isAlive(pmc) then return end
    leftGlide = nil
    local loc, rot = lhPmcTarget()
    pcall(setRelative, pmc, loc, rot)
end

-- ==========================================
-- IK modes: accessory targets in libs/ik.lua
-- ==========================================
local ikLeft = nil          -- { parent, socket, loc, rot, glide = {sLoc,sRot,eLoc,eRot,t0,dur}, releasing }
local ikRightAttached = false

local function sendIK(hand, parent, socket, loc, rot)
    uevrUtils.executeUEVRCallbacks("on_accessory_attach", hand, parent, socket, 0,
        { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll })
end

local function detachIKLeft()
    local was = ikLeft ~= nil
    ikLeft = nil
    if was then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
end

local ikRightParent = nil -- what the right IK target is attached to (right controller or gun root)
local ikRightKey = nil    -- offsets last sent while on the controller

local function detachIKRight()
    ikRightParent, ikRightKey = nil, nil
    if not ikRightAttached then return end
    ikRightAttached = false
    pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right) end)
end

-- the weapon's IK right-hand offset (controller space; hands.lua puts the gun proxy on hand_r with the inverse)
local function ikRightOffset()
    return { X = configui.getValue("ikRhOffX") or 0, Y = configui.getValue("ikRhOffY") or 0, Z = configui.getValue("ikRhOffZ") or 0 },
           { Pitch = configui.getValue("ikRhRotPitch") or 0, Yaw = configui.getValue("ikRhRotYaw") or 0, Roll = configui.getValue("ikRhRotRoll") or 0 }
end

-- IK modes, not two-handing: the right target is the controller moved by the weapon's offset (none when zero)
local function syncIKRightOffset()
    if not isIKMode() or active then return end
    local loc, rot = ikRightOffset()
    local zero = loc.X == 0 and loc.Y == 0 and loc.Z == 0 and rot.Pitch == 0 and rot.Yaw == 0 and rot.Roll == 0
    local controller = controllers.getController(1)
    if zero or controller == nil then
        if ikRightAttached then detachIKRight() end
        return
    end
    local key = string.format("%.3f %.3f %.3f %.3f %.3f %.3f", loc.X, loc.Y, loc.Z, rot.Pitch, rot.Yaw, rot.Roll)
    if ikRightAttached and ikRightParent == controller and ikRightKey == key then return end
    local ok = pcall(sendIK, Handed.Right, controller, "", loc, rot)
    if ok then ikRightAttached, ikRightParent, ikRightKey = true, controller, key end
end

local function ikGripTarget()
    return { X = configui.getValue("ikLhOffX") or 0, Y = configui.getValue("ikLhOffY") or 0, Z = configui.getValue("ikLhOffZ") or 0 },
           { Pitch = configui.getValue("ikLhRotPitch") or 0, Yaw = configui.getValue("ikLhRotYaw") or 0, Roll = configui.getValue("ikLhRotRoll") or 0 }
end

local function startIKLeftGlide(sLoc, sRot, eLoc, eRot)
    local s = ikLeft
    local dur = glideTime()
    if dur <= 0 then
        s.loc, s.rot, s.glide = eLoc, eRot, nil
    else
        s.loc, s.rot = sLoc, sRot
        s.glide = { sLoc = sLoc, sRot = sRot, eLoc = eLoc, eRot = eRot, t0 = os.clock(), dur = dur }
    end
    sendIK(Handed.Left, s.parent, s.socket, s.loc, s.rot)
end

local function attachIKLeftToGun(weaponMesh)
    local controller = controllers.getController(0)
    if controller == nil then return end
    local socket = getLHSocket()
    -- the left controller in the socket's space: as a virtual controller this puts the hand exactly where it is
    local sLoc, sRot = toLocal(socketTransform(weaponMesh, socket), controller:K2_GetComponentLocation(), controller:K2_GetComponentRotation())

    -- First grab of this weapon in an IK mode: the grab pose becomes its grip (fine-tune with the sliders)
    local profile = weaponProfiles[currentWeapon]
    if snapLeft() and currentWeapon ~= "None" and (profile == nil or profile.ikLhOffX == nil) then
        local vals = { sLoc.X, sLoc.Y, sLoc.Z, sRot.Pitch, sRot.Yaw, sRot.Roll }
        for i, id in ipairs(IK_GRIP_IDS) do
            configui.setValue(id, vals[i], true)
            if weaponProfiles[currentWeapon] == nil then weaponProfiles[currentWeapon] = {} end
            weaponProfiles[currentWeapon][id] = vals[i]
        end
        saveProfiles()
    end

    local eLoc, eRot = sLoc, sRot
    if snapLeft() then eLoc, eRot = ikGripTarget() end
    ikLeft = { parent = weaponMesh, socket = socket }
    startIKLeftGlide(sLoc, sRot, eLoc, eRot)
end

-- glide back into the left controller's space (towards the controller itself), then detach
local function releaseIKLeft()
    local s = ikLeft
    local controller = controllers.getController(0)
    if s == nil or s.loc == nil or controller == nil or glideTime() <= 0 or not isAlive(s.parent) then
        detachIKLeft()
        return
    end
    local ok, cLoc, cRot = pcall(function()
        local wLoc, wRot = fromLocal(socketTransform(s.parent, s.socket), s.loc, s.rot)
        return toLocal(componentTransform(controller), wLoc, wRot)
    end)
    if not ok then detachIKLeft() return end
    ikLeft = { parent = controller, socket = "", releasing = true }
    startIKLeftGlide(cLoc, cRot, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
end

-- per tick: advance the glide (on or off the gun)
local function updateIKLeft()
    local s = ikLeft
    if s == nil or s.glide == nil then return end
    if not isAlive(s.parent) then detachIKLeft() return end
    local g = s.glide
    local e, done = easeOut(g.t0, g.dur)
    local ok = pcall(function()
        s.loc, s.rot = lerpLoc(g.sLoc, g.eLoc, e), lerpRot(g.sRot, g.eRot, e)
        sendIK(Handed.Left, s.parent, s.socket, s.loc, s.rot)
    end)
    if not ok then detachIKLeft() return end
    if done then
        s.glide = nil
        if s.releasing then detachIKLeft() end -- the controller now gives the hand this same pose
    end
end

-- live slider changes while gripping in an IK mode
local function refreshIKLeftTarget()
    local s = ikLeft
    if s == nil or s.releasing or not snapLeft() then return end
    local eLoc, eRot = ikGripTarget()
    if s.glide ~= nil then
        s.glide.eLoc, s.glide.eRot = eLoc, eRot
    else
        s.loc, s.rot = eLoc, eRot
        pcall(sendIK, Handed.Left, s.parent, s.socket, eLoc, eRot)
    end
end

-- The right IK hand follows the pivoting gun: its target is the right controller (moved by the weapon's IK
-- right-hand offset) in the UN-PIVOTED gun root's space (called before the first pivot, so the hand doesn't
-- move at the grab). The gun returns to that base on release, where the target is back on the controller.
local function attachIKRightToGun(root)
    local controller = controllers.getController(1)
    if controller == nil then return end
    local ok, err = pcall(function()
        local oLoc, oRot = ikRightOffset()
        local wLoc, wRot = fromLocal(componentTransform(controller), oLoc, oRot)
        local lLoc, lRot = toLocal(socketTransform(root, ""), wLoc, wRot)
        sendIK(Handed.Right, root, "", lLoc, lRot)
        ikRightAttached, ikRightParent, ikRightKey = true, root, nil
    end)
    if not ok then print("[two_handed] IK right attach failed: " .. tostring(err)) end
end

-- ==========================================
-- Left hand pose (finger bones only, so it works on the glove and on the IK rig)
-- ==========================================
local function getLeftPose()
    local profile = weaponProfiles[currentWeapon]
    if profile ~= nil and profile.leftPose ~= nil then return profile.leftPose end
    return LH_WEAPON_POSES[currentWeapon] or LH_GRIP_POSE
end

local function leftHandMesh()
    if isIKMode() then return ik.getCurrentMesh() end
    return hands.getHandComponent(Handed.Left)
end

local function applyLeftPose()
    if not active or configui.getValue("th_apply_pose") == false then return end
    local mesh = leftHandMesh()
    if mesh == nil or not isAlive(mesh) then return end
    pcall(function() animation.initializeBones(mesh, getLeftPose()) end)
end

-- Copies the game's body mesh (pawn.Mesh, animated with the weapon's real two-handed grip) into a temporary
-- poseable mesh and records the bone-space rotation of every bone below hand_l for the current weapon.
local function captureLeftPose()
    if currentWeapon == "None" then status("capture: no weapon") return end
    local pawn = api:get_local_pawn(0)
    local source = pawn ~= nil and uevrUtils.getValid(pawn.Mesh) or nil
    if source == nil then status("capture: body mesh not found") return end
    local temp = uevrUtils.createPoseableMeshFromSkeletalMesh(source, { useDefaultPose = false, showDebug = false })
    if temp == nil then status("capture: could not copy the body mesh") return end
    local pose, count = {}, 0
    local ok, err = pcall(function()
        for _, boneName in ipairs(animation.getDescendantBones(temp, "hand_l", false) or {}) do
            local rot = animation.getBoneSpaceLocalTransform(temp, uevrUtils.fname_from_string(boneName), 0)
            if rot ~= nil then
                pose[boneName] = { rotation = { rot.Pitch, rot.Yaw, rot.Roll } }
                count = count + 1
            end
        end
    end)
    pcall(function() uevrUtils.destroyComponent(temp, true, true) end)
    if not ok then status("capture failed: " .. tostring(err)) return end
    if count == 0 then status("capture: no bones found below hand_l") return end
    saveProfileValue("leftPose", pose)
    updatePoseLabel()
    status("captured " .. count .. " bones for " .. currentWeapon)
    applyLeftPose()
end

configui.onUpdate("th_capture_pose", function(value)
    -- button callbacks run on the draw thread; the capture spawns a temp component -> defer
    uevrUtils.setTimeout(1, captureLeftPose)
end)

configui.onUpdate("th_clear_pose", function(value)
    local profile = weaponProfiles[currentWeapon]
    if profile ~= nil and profile.leftPose ~= nil then
        profile.leftPose = nil
        saveProfiles()
    end
    updatePoseLabel()
    uevrUtils.setTimeout(1, applyLeftPose)
end)

-- ==========================================
-- Gun pivot
-- ==========================================
-- The gun root sits on the controller proxy (hands.lua) with a fixed relative transform that nothing
-- resets each frame, and libs/two_handed_aiming.lua turns the gun's CURRENT rotation. So each application
-- starts from the un-pivoted base captured at the grab; repeating it (every view) is idempotent.
local function captureGunBase(root)
    gunBase = nil
    pcall(function()
        local loc, rot = relativeOf(root)
        gunBase = { root = root, parent = root.AttachParent, loc = loc, rot = rot }
    end)
end

local function resetGunToBase()
    local b = gunBase
    if b == nil or not isAlive(b.root) then return false end
    if b.root.AttachParent ~= b.parent then
        -- re-parented by the game / hands.lua: its new relative transform is the base
        captureGunBase(b.root)
        return gunBase ~= nil
    end
    b.root:K2_SetRelativeLocationAndRotation(uevrUtils.vector(b.loc.X, b.loc.Y, b.loc.Z),
        uevrUtils.rotator(b.rot.Pitch, b.rot.Yaw, b.rot.Roll), false, getHitResult(), false)
    return true
end

local function applyPivot()
    local a = pivotArgs
    if a == nil or not isAlive(a.root) then return end
    if not resetGunToBase() then return end
    twoHandedAiming.applyTwoHandedRotation(a.root, a.rightHand, a.leftHand)
end

-- ==========================================
-- Activation
-- ==========================================
local function activate(root, weaponMesh)
    if active then return end
    active = true
    activeInIKMode = isIKMode()
    _G.isTwoHandingActive = true
    captureGunBase(root)
    if activeInIKMode then
        pcall(attachIKLeftToGun, weaponMesh)
        attachIKRightToGun(root)
    else
        local pmc = hands.getHandComponent(Handed.Left)
        if isAlive(pmc) then
            updateLeftHome(pmc)
            local ok, err = pcall(attachLeftGloveToGun, pmc, weaponMesh)
            if not ok then print("[two_handed] left glove attach failed: " .. tostring(err)) end
        end
    end
    pcall(function() hands.setHoldingAttachment(Handed.Left, true) end)
    status("two-handing")
end

local function deactivate(reason)
    if not active then return end
    active = false
    pivotArgs = nil
    pcall(resetGunToBase) -- straighten the gun back onto the controller
    gunBase = nil
    detachIKRight()
    if activeInIKMode then
        pcall(releaseIKLeft)
    else
        pcall(releaseLeftGlove, hands.getHandComponent(Handed.Left))
    end
    pcall(function() hands.setHoldingAttachment(Handed.Left, false) end)
    _G.isTwoHandingActive = false
    if activeInIKMode then
        -- right target back onto the controller (with the weapon's offset)
        syncIKRightOffset()
    end
    status("idle (" .. tostring(reason) .. ")")
end

-- drop all two-handing state without touching objects that may be gone (pawn / level change)
local function forgetTwoHanding()
    active = false
    pivotArgs = nil
    gunBase = nil
    leftGlide = nil
    leftHome = nil
    detachIKLeft()
    detachIKRight()
    _G.isTwoHandingActive = false
end

-- Stop the left hand's mesh-driven animation while two-handing, so the grip pose isn't overwritten
hands.registerIsAnimatingFromMeshCallback(function(hand, isAnimating)
    if hand == Handed.Left and active then
        return false
    end
    return nil
end)

local function resetLevelState()
    forgetTwoHanding()
    handParentedToGun     = false
    pmcBaseTransform      = nil
    cachedFlashFL         = nil
    cachedFlashShaft      = nil
    flashZoneOverlapping  = false
    flSearchTime          = 0
    rightGripWasDown      = false
    punchAnimationActive  = false
    inGrabZone            = false
    destroyMarkers()
    currentWeapon         = "None"
    configui.setLabel("weapon_label", "Current Weapon: None")
    configui.setLabel("sl_weapon_label", "Saved for weapon: None")
    pcall(function() hands.setHoldingAttachment(Handed.Left, false) end)
end

-- ==========================================
-- Slider callbacks: save per weapon, live-apply
-- ==========================================
local PROFILE_IDS = {}
for id in pairs(GEOMETRY_DEFAULTS) do table.insert(PROFILE_IDS, id) end
for _, id in ipairs(CARRY_IDS) do table.insert(PROFILE_IDS, id) end

for _, id in ipairs(PROFILE_IDS) do
    configui.onUpdate(id, function(value)
        saveProfileValue(id, value)
        uevrUtils.setTimeout(1, function() -- draw thread -> game thread
            if id:sub(1, 3) == "pmc" then
                local pmc = getRightPMC()
                if pmc then applyPMCOffset(pmc) end
            elseif id:sub(1, 5) == "lhPmc" then
                refreshLeftGlove()
            elseif id:sub(1, 4) == "ikLh" then
                refreshIKLeftTarget()
            elseif id == "lhSocket" then
                deactivate("socket changed")
            end
        end)
    end)
end

-- Reset scripts: our debug spheres outlive this Lua state; release the hands and the gun first
uevr.sdk.callbacks.on_script_reset(function()
    pcall(deactivate, "script reset")
    detachIKLeft()
    detachIKRight()
    destroyMarkers()
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    forgetTwoHanding()
    destroyMarkers() -- still alive here; the level takes their owner with it
end)

-- ==========================================
-- Per-tick body
-- ==========================================
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    stereoRanThisTick = false
end)

-- ==========================================
-- IK weapon lock
-- ==========================================
-- In IK modes the gun used to be drawn ahead of the IK arm holding it, by a lot:
--   * a MotionControllerComponent moves everything under it to the newest controller pose on the render thread
--     (low latency update, bDisableLowLatencyUpdate = false on the right controller). The gun hung under it;
--     the IK arm doesn't (the rig hangs off a plain scene component), so the arm never got that update;
--   * the rig solves in an engine tick callback (the POST tick with Enhanced Stabilization, as in
--     data/ik_parameters.json) and its bones are drawn in the following frame.
-- (Hands mode never showed it: the glove sits under the controller too and gets the same late update.)
-- Neither parenting to the hand_r bone nor redrawing the gun in post stereo (the Stalker 2 method) helped while
-- the gun stayed under the controller. So in IK modes hands.lua hangs the gun proxy on the IK arm MESH, and
-- here it is put where the controller was when the arm pose being drawn was solved:
--   * right after the rig solves, the right controller's pose is recorded RELATIVE TO THE RIG MESH and the
--     proxy's relative transform is set to it. The solved arm is bones in that mesh's space, so this is where
--     the hand holds the gun no matter how the rig moves later. The gun and everything on it then move with the
--     arm mesh until the next solve. Shots and traces (CronosAimFix reads the gun root) use that same pose, i.e.
--     the gun the player sees.
-- The proxy's pose comes from the controller, not from the hand, so the right IK hand can still follow the
-- (pivoting) gun while two-handing without a feedback loop.
local LOCK_AFTER_SOLVE = -1000 -- engine tick callbacks: after the rig's solve (libs/ik.lua registers at 0)
local LOCK_BEFORE_SOLVE = 1000 -- and before it

local postTickSolve, postTickSolveRead = false, -10

-- Enhanced Stabilization = the rig solves in the post engine tick (libs/ik.lua); re-read every 2 s
local function rigSolvesPostTick()
    local now = os.clock()
    if now - postTickSolveRead > 2.0 then
        postTickSolveRead = now
        pcall(function()
            local params = json.load_file("ik_parameters.json")
            local profileName = params and params["_profileState"] and params["_profileState"]["currentEditingProfile"] or "default"
            local profile = params and (params[profileName] or params["default"])
            postTickSolve = profile ~= nil and profile["enhanced_stabilization"] == true
        end)
    end
    return postTickSolve
end

-- the gun proxy while it hangs on the IK arm mesh (hands.lua), else nil
local function lockProxy()
    if not isIKMode() or not ik.exists() or _G.cronosGetGunProxy == nil then return nil end
    local proxy = _G.cronosGetGunProxy()
    local rig = ik.getCurrentMesh()
    if proxy == nil or rig == nil or proxy.AttachParent ~= rig then return nil end
    return proxy
end

-- the right controller's pose in the rig mesh's space, with the rig where it is now
local function controllerRelativeToRig()
    local rig, controller = ik.getCurrentMesh(), controllers.getController(1)
    if rig == nil or controller == nil then return nil end
    return { toLocal(componentTransform(rig), controller:K2_GetComponentLocation(), controller:K2_GetComponentRotation()) }
end

-- Right AFTER the rig's solve, in whichever engine tick it solves (libs/ik.lua registers at priority 0): the rig
-- mesh then stands where the solve used it (with Enhanced Stabilization the tick first re-rotates the mesh, so a
-- pose recorded before the tick was relative to last frame's rotation and the gun trailed every smooth turn) and
-- the controller hasn't moved since. The proxy is placed at once; it rides the mesh from there.
local proxyHeldInWorld = nil -- the proxy while placeProxyBeforeSolve holds it in world space

local function placeProxyAfterSolve()
    local proxy = lockProxy()
    if proxyHeldInWorld ~= nil then
        local held = proxyHeldInWorld
        proxyHeldInWorld = nil
        pcall(function() held:SetAbsolute(false, false, false) end)
    end
    if proxy == nil then return end
    local ok, rel = pcall(controllerRelativeToRig)
    if not ok or rel == nil then return end
    pcall(function()
        proxy:K2_SetRelativeLocationAndRotation(uevrUtils.vector(rel[1].X, rel[1].Y, rel[1].Z),
            uevrUtils.rotator(rel[2].Pitch, rel[2].Yaw, rel[2].Roll), false, getHitResult(), false)
    end)
end

-- Two-handing (IK): the left IK hand is solved towards the gun's grip socket (on_accessory_attach), so the gun must
-- already stand where it will be drawn when the rig solves. Otherwise the hand reached for last frame's gun and
-- floated / lagged on it. Right BEFORE the solve, the proxy is put on the right controller in WORLD space
-- (SetAbsolute: the rig re-rotates at the start of its tick with Enhanced Stabilization and must not carry the gun
-- along), and this frame's pivot is applied. placeProxyAfterSolve then hands it back to the rig at the same pose.
-- The pivot is not re-applied at render time in IK modes, so gun, left hand and right hand all come from this moment.
local function placeProxyBeforeSolve()
    if not (active and activeInIKMode and pivotArgs ~= nil) then return end
    local proxy = lockProxy()
    local controller = controllers.getController(1)
    if proxy == nil or controller == nil then return end
    local ok = pcall(function()
        proxy:SetAbsolute(true, true, false)
        proxyHeldInWorld = proxy
        proxy:K2_SetWorldLocationAndRotation(controller:K2_GetComponentLocation(), controller:K2_GetComponentRotation(), false, getHitResult(), false)
    end)
    if ok then pcall(applyPivot) end
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    if not rigSolvesPostTick() then placeProxyBeforeSolve() end
end, LOCK_BEFORE_SOLVE)

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    if not rigSolvesPostTick() then placeProxyAfterSolve() end
end, LOCK_AFTER_SOLVE)

uevrUtils.registerPostEngineTickCallback(function(engine, delta)
    if rigSolvesPostTick() then placeProxyBeforeSolve() end
end, LOCK_BEFORE_SOLVE)

uevrUtils.registerPostEngineTickCallback(function(engine, delta)
    if rigSolvesPostTick() then placeProxyAfterSolve() end
end, LOCK_AFTER_SOLVE)


local lastIKMode = nil

local function updateFlashlight(rightHand)
    -- toggle zone: around the left glove (Hands mode) or the left controller (IK modes)
    flashZoneOverlapping = false
    local anchor, socket = nil, ""
    if not isIKMode() then
        anchor, socket = hands.getHandComponent(Handed.Left), "root"
        if not isAlive(anchor) then anchor = nil end
    end
    if anchor == nil then anchor, socket = controllers.getController(0), "" end
    local center = nil
    if anchor ~= nil then
        pcall(function()
            center = kismet_math_library:TransformLocation(socketTransform(anchor, socket), uevrUtils.vector(
                configui.getValue("flOffX") or 0, configui.getValue("flOffY") or 0, configui.getValue("flOffZ") or 0))
            flashZoneOverlapping = distance(rightHand:K2_GetComponentLocation(), center) <= (configui.getValue("flDetectRadius") or 15)
        end)
    end
    setMarker("flash", center)

    -- spotlight / shaft visibility enforcement
    local now = os.clock()
    if cachedFlashFL == nil or cachedFlashShaft == nil then
        if now - flSearchTime > 2.0 then
            flSearchTime = now
            if cachedFlashFL == nil then pcall(function() cachedFlashFL = findSpotlightForToggle() end) end
            if cachedFlashShaft == nil then pcall(function() cachedFlashShaft = findFlashlightShaftForToggle() end) end
        end
    end
    if cachedFlashFL ~= nil and not pcall(function() cachedFlashFL:get_full_name() end) then cachedFlashFL = nil end
    if cachedFlashShaft ~= nil and not pcall(function() cachedFlashShaft:get_full_name() end) then cachedFlashShaft = nil end
    for _, comp in pairs({ cachedFlashFL or false, cachedFlashShaft or false }) do
        if comp then
            pcall(function()
                comp:SetVisibility(flashlightOn, true)
                comp:SetHiddenInGame(not flashlightOn, true)
            end)
        end
    end
end

local function doStereoBody()
    local pawn = api:get_local_pawn(0)
    if not pawn then return end

    if pawn ~= lastPawn then
        lastPawn = pawn
        resetLevelState()
    end

    -- Hands <-> IK switch: the hand components were replaced; release and start clean
    local ikMode = isIKMode()
    if ikMode ~= lastIKMode then
        if lastIKMode ~= nil then
            pcall(resetGunToBase)
            forgetTwoHanding()
            handParentedToGun = false
            pmcBaseTransform  = nil
            pcall(function() hands.setHoldingAttachment(Handed.Left, false) end)
            status("idle (hands mode changed)")
        end
        lastIKMode = ikMode
    end

    -- glides keep running even when the gun goes away mid-release
    updateLeftGlide()
    updateIKLeft()

    local rightHand, leftHand = controllers.getController(1), controllers.getController(0)
    if not rightHand or not leftHand then return end

    local root, weaponMesh, skelName = getEquippedWeaponForCronos(pawn)
    local gunEquipped = root ~= nil and weaponMesh ~= nil

    if gestures.getGesture(gestures.Gesture.PUNCH) and not punchAnimationActive then
        punchAnimationActive = true
        deactivate("melee")
        uevrUtils.setTimeout(1500, function() punchAnimationActive = false end)
        print("[PMC] Punch detected - freeing PMC from gun for 1.5s")
    end

    -- Right glove on the gun (Hands mode)
    local rightPMC = getRightPMC()
    if rightPMC and isAlive(rightPMC) then
        captureBaseTransform(rightPMC)
        if punchAnimationActive and handParentedToGun then
            pcall(attachPMCToController, rightPMC)
            handParentedToGun = false
        elseif gunEquipped and not handParentedToGun and not punchAnimationActive then
            pcall(attachPMCToGun, rightPMC, weaponMesh)
            handParentedToGun = true
        elseif not gunEquipped and handParentedToGun then
            pcall(attachPMCToController, rightPMC)
            handParentedToGun = false
        end
    end

    updateFlashlight(rightHand)

    if not ikMode then updateLeftHome(hands.getHandComponent(Handed.Left)) end

    if not gunEquipped then
        deactivate("no weapon")
        inGrabZone = false
        setMarker("grip", nil)
        return
    end

    -- Weapon switch: release first, then load the new weapon's profile
    if skelName ~= nil and skelName ~= currentWeapon then
        deactivate("weapon changed")
        currentWeapon = skelName
        configui.setLabel("weapon_label", "Current Weapon: " .. currentWeapon)
        configui.setLabel("sl_weapon_label", "Saved for weapon: " .. currentWeapon)
        applyProfileValues(currentWeapon)
        if rightPMC and isAlive(rightPMC) and handParentedToGun then
            pcall(attachPMCToGun, rightPMC, weaponMesh)
        end
    end

    -- IK modes: the weapon's right-hand offset (the gun proxy in hands.lua uses the same values)
    syncIKRightOffset()

    -- Two-handing
    if configui.getValue("twoHandEnabled") == false or getLHSocket() == "" then
        deactivate(configui.getValue("twoHandEnabled") == false and "disabled" or "no LH socket")
        inGrabZone = false
        setMarker("grip", nil)
        if getLHSocket() == "" then status("not two-handable (no LH socket)") end
        return
    end
    if active and activeInIKMode ~= ikMode then deactivate("hands mode changed") end

    local ok, gripPoint = pcall(getGripPoint, weaponMesh)
    if not ok or gripPoint == nil then return end
    setMarker("grip", gripPoint)

    local dist = distance(leftHand:K2_GetComponentLocation(), gripPoint)
    local force = configui.getValue("forceTwoHand") == true
    inGrabZone = dist <= (configui.getValue("th_grab_radius") or 16)

    if not active then
        if not punchAnimationActive and (force or (grabDown and inGrabZone)) then
            activate(root, weaponMesh)
        else
            status(string.format("ready (%.0f cm from grip)", dist))
        end
    elseif not force and (not grabDown or dist > (configui.getValue("th_release_radius") or 40)) then
        deactivate(grabDown and "too far" or "grip released")
    end

    if active then
        pivotArgs = { root = root, rightHand = rightHand, leftHand = leftHand }
        -- IK modes: pivoted right before the rig solves instead (placeProxyBeforeSolve)
        if not activeInIKMode then
            local okPivot, err = pcall(applyPivot)
            if not okPivot then print("[two_handed] pivot: " .. tostring(err)) end
        end
        applyLeftPose()
    end
end

-- The per-tick body runs on the first post-stereo view of each tick (controller and weapon transforms are
-- valid there in every render mode). Later views re-apply the pivot from the gun's base: anything that
-- moved the gun between views is overruled, and the last write before the frame renders is ours.
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() then return end
    if stereoRanThisTick then
        -- IK modes: the pivot belongs to the solve (placeProxyBeforeSolve), not to render time
        if active and pivotArgs ~= nil and not activeInIKMode then
            local ok, err = pcall(applyPivot)
            if not ok then print("[two_handed] pivot: " .. tostring(err)) end
        end
        return
    end
    stereoRanThisTick = true
    local ok, err = pcall(doStereoBody)
    if not ok then print("[two_handed] " .. tostring(err)) end
end)

-- ==========================================
-- Input
-- ==========================================
-- Priority 5: after hands_animation (10), so the hands still animate from the real buttons; before the game.
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 then return end

    -- Flashlight toggle: right grip inside the flashlight zone. The press is hidden from the game (no melee).
    if gestures.getGesture(gestures.Gesture.PUNCH) then
        rightGripWasDown = true
    else
        local rightGripNow = uevrUtils.isButtonPressed(state, BTN_RIGHT_GRIP)
        if rightGripNow and flashZoneOverlapping then
            uevrUtils.unpressButton(state, BTN_RIGHT_GRIP)
            if not rightGripWasDown then
                flashlightOn = not flashlightOn
                print("[FL] Spotlight toggled -> " .. tostring(flashlightOn))
            end
        end
        rightGripWasDown = rightGripNow
    end

    -- Two-handing grab button (raw, before it is hidden)
    local useTrigger = configui.getValue("th_grab_button") == 2
    if useTrigger then
        grabDown = (state.Gamepad.bLeftTrigger or 0) > 100
    else
        grabDown = uevrUtils.isButtonPressed(state, BTN_LEFT_GRIP)
    end
    -- any left button edge while two-handing triggers hand-animation lerps: re-assert the grip pose after them
    local leftButtons = (uevrUtils.isButtonPressed(state, BTN_LEFT_GRIP) and 1 or 0) + (((state.Gamepad.bLeftTrigger or 0) > 100) and 2 or 0)
    if active and leftButtons ~= lastLeftButtons then
        for _, delayMs in ipairs({ 150, 400 }) do uevrUtils.setTimeout(delayMs, applyLeftPose) end
    end
    lastLeftButtons = leftButtons
    -- hidden near the grip too: on the left grip the press would otherwise start a mine throw before the grab
    if (active or inGrabZone) and configui.getValue("th_suppress_grab") ~= false then
        if useTrigger then
            state.Gamepad.bLeftTrigger = 0
        else
            uevrUtils.unpressButton(state, BTN_LEFT_GRIP)
        end
    end
end, 5)
