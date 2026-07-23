local twoHandedAiming = require("libs/two_handed_aiming")
local controllers = require("libs/controllers")
local uevrUtils = require("libs/uevr_utils")
local configui = require("libs/configui")
local hands = require("libs/hands")
local animation = require("libs/animation")
local gestures = require("libs/gestures")
local api = uevr.api
local vr = uevr.params.vr

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

-- Suppress left hand mesh-driven animation while 2-hand grip is active,
-- so our per-tick initializeBones pose is not overwritten by updateAnimationFromMesh.
hands.registerIsAnimatingFromMeshCallback(function(hand, isAnimating)
    if hand == Handed.Left and leftHandParentedToGun then
        return false  -- stop mesh copy; our LH_GRIP_POSE owns the bones
    end
    return nil  -- no change for all other states
end)

local function getControllerComponents()
    local rightHand = controllers.getController(1)
    local leftHand = controllers.getController(0)
    return rightHand, leftHand
end

local function getEquippedWeaponForCronos(pawn)
    if not pawn then return nil, nil, nil end
    local ok, result1, result2, result3 = pcall(function()
        local wpc = uevrUtils.getValid(pawn.WeaponPlayerComponent)
        if wpc == nil then return nil, nil, nil end

        local gun = uevrUtils.getValid(wpc.MultiModeGun)
        if gun == nil then return nil, nil, nil end

        if gun.bHidden then return nil, nil, nil end

        local root = uevrUtils.getValid(gun.RootComponent)

        -- Raw property chain (no getValid) mirrors proven Stalker2 pattern:
        -- p.Mesh.SkeletalMesh works; wrapping in getValid() breaks it
        local mesh = gun.SkeletalMesh  -- the SkeletalMeshComponent on the actor
        if not mesh then mesh = gun.Mesh end

        local skelName = "Unknown"
        if mesh then
            local skelMesh = mesh.SkeletalMesh  -- the actual asset inside the component
            if skelMesh then
                -- use get_fname():to_string() as Stalker2 does, avoids path parsing
                local fname = skelMesh:get_fname():to_string()
                -- fname is like "SK_ShotGun_01" Ã¢â‚¬â€ strip trailing _NN suffix
                skelName = string.gsub(fname, "_%d+$", "")
                -- also strip leading SK_ prefix for display
                skelName = string.gsub(skelName, "^SK_", "")
            end
        end
        return root, mesh, skelName
    end)
    if ok then return result1, result2, result3 end
    return nil, nil, nil
end

-- ==========================================
-- Collision Box System
-- ==========================================
local isAlive = function(obj)
    if obj == nil then return false end
    local ok, alive = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and alive
end

local VHitBoxClass = nil
local function getBoxClass()
    if VHitBoxClass == nil then
        pcall(function()
            VHitBoxClass = uevrUtils.find_required_object("Class /Script/Engine.BoxComponent")
        end)
    end
    return VHitBoxClass
end

-- ==========================================
-- Per-level state Ã¢â‚¬â€ reset whenever the pawn changes
-- ==========================================
local lastPawn            = nil
local handParentedToGun   = false
local leftHandParentedToGun = false
local pmcBaseTransform    = nil
local leftPmcBaseTransform= nil
local BoxCompLH           = nil
local GripBox             = nil
local FlashBoxLH          = nil   -- flashlight interaction zone on left PMC
local flashlightOn        = true  -- current spotlight visibility state
local rightGripWasDown    = false -- edge-detection for right grip
local cachedFlashFL       = nil   -- cached SpotLightComponent for toggle
local flSearchTime        = 0
local _prevHasPunch       = false -- edge-detection for punch start/end prints
local punchAnimationActive = false -- true for 1.5s after a punch fires
local punchGunDetachTimer  = nil  -- uevrUtils.setTimeout handle
local cachedFlashShaft     = nil  -- cached FlashlightShaft StaticMeshComponent
local FlashBoxRH           = nil  -- collision box on right controller for flashlight zone
local flashZoneOverlapping = false -- true when FlashBoxRH overlaps FlashBoxLH

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

local function resetLevelState()
    handParentedToGun     = false
    leftHandParentedToGun = false
    pmcBaseTransform      = nil
    leftPmcBaseTransform  = nil
    BoxCompLH             = nil
    GripBox               = nil
    FlashBoxLH            = nil
    cachedFlashFL         = nil
    cachedFlashShaft      = nil
    FlashBoxRH            = nil
    flashZoneOverlapping  = false
    flSearchTime          = 0
    rightGripWasDown      = false
    _prevHasPunch         = false
    punchAnimationActive  = false
    if punchGunDetachTimer then
        uevrUtils.clearTimeout(punchGunDetachTimer)
        punchGunDetachTimer = nil
    end
    currentWeapon         = "None"
    configui.setLabel("weapon_label", "Current Weapon: None")
    -- restore left-hand animation state
    pcall(function() hands.setHoldingAttachment(Handed.Left, false) end)
end

-- ==========================================
-- Right Hand PMC Re-parenting State
-- ==========================================
-- (handParentedToGun, leftHandParentedToGun, pmcBaseTransform, leftPmcBaseTransform
--  are declared above in the per-level state block and reset via resetLevelState())

local GUN_SOCKET      = "GG_handle"
local LH_GUN_SOCKET   = "SmrtG_handLeft_socket"  -- fallback if lhSocket config is blank

-- Bone pose forced onto the left PMC every tick while 2-hand grip is active.
-- Format: { boneName = { rotation = {Pitch, Yaw, Roll} } }
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

-- Per-weapon overrides Ã¢â‚¬â€ keyed by the skelName (same as currentWeapon).
-- Falls back to LH_GRIP_POSE for any weapon not listed here.
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

local LH_WEAPON_POSES = {
    ShotGun = LH_GRIP_POSE_SHOTGUN,
    -- add more weapon overrides here as needed
}

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

local function getRightPMC()
    return hands.getHandComponent(Handed.Right)
end

local function attachPMCToGun(pmc, weaponMesh)
    local hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
    -- SnapToTarget (2) Ã¢â‚¬â€ then we override with our per-weapon offsets
    local ok = pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(GUN_SOCKET), 2, false)
    if ok then
        -- Apply per-weapon PMC offsets from config
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
        pmc:K2_SetRelativeLocation(loc, false, hitResult, false)
        pmc:K2_SetRelativeRotation(rot, false, hitResult, false)
        pmc.RelativeScale3D.X = 1.0
        pmc.RelativeScale3D.Y = 1.0
        pmc.RelativeScale3D.Z = 1.0
    end
end

local function attachPMCToController(pmc, rightControllerComp)
    -- Re-parent back to the MotionControllerComponent
    controllers.attachComponentToController(1, pmc)

    -- Restore the original controller-space relative transform
    if pmcBaseTransform then
        local hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
        local loc = uevrUtils.vector(pmcBaseTransform.locX, pmcBaseTransform.locY, pmcBaseTransform.locZ)
        local rot = uevrUtils.rotator(pmcBaseTransform.rotPitch, pmcBaseTransform.rotYaw, pmcBaseTransform.rotRoll)
        pmc:K2_SetRelativeLocation(loc, false, hitResult, false)
        pmc:K2_SetRelativeRotation(rot, false, hitResult, false)
    end
    pmc.RelativeScale3D.X = 1.0
    pmc.RelativeScale3D.Y = 1.0
    pmc.RelativeScale3D.Z = 1.0
end

-- ==========================================
-- Left Hand PMC Re-parenting State (2-hand grip)
-- ==========================================
-- (leftHandParentedToGun and leftPmcBaseTransform are in the per-level state block)

local function getLeftPMC()
    return hands.getHandComponent(Handed.Left)
end

local function captureLeftBaseTransform(pmc)
    if leftPmcBaseTransform then return end
    pcall(function()
        leftPmcBaseTransform = {
            locX = pmc.RelativeLocation.X,
            locY = pmc.RelativeLocation.Y,
            locZ = pmc.RelativeLocation.Z,
            rotPitch = pmc.RelativeRotation.Pitch,
            rotYaw   = pmc.RelativeRotation.Yaw,
            rotRoll  = pmc.RelativeRotation.Roll,
        }
    end)
end

local function attachLeftPMCToGun(pmc, weaponMesh)
    local hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
    -- Use per-weapon socket from config, fall back to hardcoded default if blank
    local socketName = configui.getValue("lhSocket")
    if socketName == nil or socketName == "" then socketName = LH_GUN_SOCKET end
    local ok = pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(socketName), 2, false)
    if ok then
        local loc = uevrUtils.vector(
            configui.getValue("lhPmcOffX") or 0,
            configui.getValue("lhPmcOffY") or 0,
            configui.getValue("lhPmcOffZ") or 0
        )
        local rot = uevrUtils.rotator(
            configui.getValue("lhPmcRotPitch") or 0,
            configui.getValue("lhPmcRotYaw")   or 0,
            configui.getValue("lhPmcRotRoll")  or 0
        )
        pmc:K2_SetRelativeLocation(loc, false, hitResult, false)
        pmc:K2_SetRelativeRotation(rot, false, hitResult, false)
        pmc.RelativeScale3D.X = 1.0
        pmc.RelativeScale3D.Y = 1.0
        pmc.RelativeScale3D.Z = 1.0
    end
end

local function attachLeftPMCToController(pmc)
    -- Explicitly break the gun parent link before re-attaching
    pmc:DetachFromParent(false, false)
    controllers.attachComponentToController(0, pmc)
    if leftPmcBaseTransform then
        local hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
        local loc = uevrUtils.vector(leftPmcBaseTransform.locX, leftPmcBaseTransform.locY, leftPmcBaseTransform.locZ)
        local rot = uevrUtils.rotator(leftPmcBaseTransform.rotPitch, leftPmcBaseTransform.rotYaw, leftPmcBaseTransform.rotRoll)
        pmc:K2_SetRelativeLocation(loc, false, hitResult, false)
        pmc:K2_SetRelativeRotation(rot, false, hitResult, false)
    end
    pmc.RelativeScale3D.X = 1.0
    pmc.RelativeScale3D.Y = 1.0
    pmc.RelativeScale3D.Z = 1.0
end

-- ==========================================
-- Config UI (JBusfield Framework)
-- ==========================================
local configDef = {
    {
        panelLabel = "Cronos VR",
        saveFile = "two_handed_dev_config",
        layout = {
            { widgetType = "text_colored", label = "Cronos: The New Dawn VR", color = "#8B0000FF" },
            { widgetType = "spacing" },
            { widgetType = "checkbox", id = "twoHandEnabled", label = "Enable 2-Handing", initialValue = true },
            { widgetType = "spacing" },
            { widgetType = "tree_node", id = "dev_tools_header", label = "Dev Tools", initialOpen = false },
            { widgetType = "spacing" },
            { widgetType = "text", id = "weapon_label", label = "Current Weapon: None" },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Right Hand (PMC Ã¢â€ â€™ GG_handle socket)" },
            { widgetType = "slider_float", id = "pmcOffX",    label = "PMC Offset X",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcOffY",    label = "PMC Offset Y",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcOffZ",    label = "PMC Offset Z",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "pmcRotPitch",label = "PMC Rot Pitch",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "pmcRotYaw",  label = "PMC Rot Yaw",     initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "pmcRotRoll", label = "PMC Rot Roll",    initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left Hand (PMC Ã¢â€ â€™ SmrtG_handLeft_socket, 2-hand only)" },
            { widgetType = "slider_float", id = "lhPmcOffX",    label = "LH PMC Offset X",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcOffY",    label = "LH PMC Offset Y",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcOffZ",    label = "LH PMC Offset Z",  initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhPmcRotPitch",label = "LH PMC Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "lhPmcRotYaw",  label = "LH PMC Rot Yaw",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "lhPmcRotRoll", label = "LH PMC Rot Roll",  initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "input_text", id = "lhSocket", label = "LH Socket Name", initialValue = "", width = 280 },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left Hand Grip Box (collision trigger)" },
            { widgetType = "slider_float", id = "scaleX", label = "Grip Scale X", initialValue = 0.1, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "scaleY", label = "Grip Scale Y", initialValue = 0.1, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "scaleZ", label = "Grip Scale Z", initialValue = 0.1, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "offX", label = "Grip Offset X", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "offY", label = "Grip Offset Y", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "offZ", label = "Grip Offset Z", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left Hand Box" },
            { widgetType = "slider_float", id = "lhScaleX", label = "Hand Scale X", initialValue = 0.05, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "lhScaleY", label = "Hand Scale Y", initialValue = 0.05, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "lhScaleZ", label = "Hand Scale Z", initialValue = 0.05, range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "lhOffX", label = "Hand Offset X", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhOffY", label = "Hand Offset Y", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "lhOffZ", label = "Hand Offset Z", initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Spotlight (Left Controller offset)" },
            { widgetType = "slider_float", id = "slOffX",    label = "SL Offset X",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slOffY",    label = "SL Offset Y",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slOffZ",    label = "SL Offset Z",    initialValue = 0.0, range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "slRotPitch",label = "SL Rot Pitch",   initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "slRotYaw",  label = "SL Rot Yaw",     initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "slRotRoll", label = "SL Rot Roll",    initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Flashlight Collision Box (Left PMC)" },
            { widgetType = "slider_float", id = "flOffX",    label = "FL Offset X",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flOffY",    label = "FL Offset Y",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flOffZ",    label = "FL Offset Z",    initialValue = 0.0,  range = {-50.0, 50.0} },
            { widgetType = "slider_float", id = "flScaleX",  label = "FL Scale X",     initialValue = 0.1,  range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "flScaleY",  label = "FL Scale Y",     initialValue = 0.1,  range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "flScaleZ",  label = "FL Scale Z",     initialValue = 0.1,  range = {0.01, 2.0} },
            { widgetType = "slider_float", id = "flRotPitch",label = "FL Rot Pitch",   initialValue = 0.0,  range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "flRotYaw",  label = "FL Rot Yaw",     initialValue = 0.0,  range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "flRotRoll", label = "FL Rot Roll",    initialValue = 0.0,  range = {-180.0, 180.0} },
            { widgetType = "spacing" },
            { widgetType = "checkbox", id = "debugMode", label = "Debug Visibility", initialValue = true },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Dev Controls" },
            { widgetType = "checkbox", id = "forceTwoHand", label = "Force 2-Handing ON", initialValue = false },
            { widgetType = "tree_pop" },
        }
    }
}
configui.create(configDef)


local function applyBoxSizes()
    pcall(function()
        if isAlive(GripBox) then
            GripBox.RelativeScale3D.X = configui.getValue("scaleX") or 0.1
            GripBox.RelativeScale3D.Y = configui.getValue("scaleY") or 0.1
            GripBox.RelativeScale3D.Z = configui.getValue("scaleZ") or 0.1
            GripBox.RelativeLocation.X = configui.getValue("offX") or 0.0
            GripBox.RelativeLocation.Y = configui.getValue("offY") or 0.0
            GripBox.RelativeLocation.Z = configui.getValue("offZ") or 0.0
        end
    end)
    pcall(function()
        if isAlive(BoxCompLH) then
            BoxCompLH.RelativeScale3D.X = configui.getValue("lhScaleX") or 0.05
            BoxCompLH.RelativeScale3D.Y = configui.getValue("lhScaleY") or 0.05
            BoxCompLH.RelativeScale3D.Z = configui.getValue("lhScaleZ") or 0.05
            BoxCompLH.RelativeLocation.X = configui.getValue("lhOffX") or 0.0
            BoxCompLH.RelativeLocation.Y = configui.getValue("lhOffY") or 0.0
            BoxCompLH.RelativeLocation.Z = configui.getValue("lhOffZ") or 0.0

            local dbg = configui.getValue("debugMode")
            if dbg == nil then dbg = true end
            BoxCompLH:SetHiddenInGame(not dbg)
            BoxCompLH:SetVisibility(dbg, false)
        end
        if isAlive(GripBox) then
            local dbg = configui.getValue("debugMode")
            if dbg == nil then dbg = true end
            GripBox:SetHiddenInGame(not dbg)
            GripBox:SetVisibility(dbg, false)
        end
    end)
    pcall(function()
        local dbg = configui.getValue("debugMode")
        if dbg == nil then dbg = true end
        if isAlive(FlashBoxLH) then
            FlashBoxLH.RelativeScale3D.X = configui.getValue("flScaleX") or 0.1
            FlashBoxLH.RelativeScale3D.Y = configui.getValue("flScaleY") or 0.1
            FlashBoxLH.RelativeScale3D.Z = configui.getValue("flScaleZ") or 0.1
            FlashBoxLH.RelativeLocation.X = configui.getValue("flOffX") or 0.0
            FlashBoxLH.RelativeLocation.Y = configui.getValue("flOffY") or 0.0
            FlashBoxLH.RelativeLocation.Z = configui.getValue("flOffZ") or 0.0
            FlashBoxLH.RelativeRotation.Pitch = configui.getValue("flRotPitch") or 0.0
            FlashBoxLH.RelativeRotation.Yaw   = configui.getValue("flRotYaw")   or 0.0
            FlashBoxLH.RelativeRotation.Roll  = configui.getValue("flRotRoll")  or 0.0
            FlashBoxLH:SetHiddenInGame(not dbg)
            FlashBoxLH:SetVisibility(dbg, false)
        end
    end)
end

-- Apply live PMC offset changes while gun-parented
local function applyPMCOffset(pmc)
    if not isAlive(pmc) then return end
    if not handParentedToGun then return end
    pcall(function()
        local hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
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
        pmc:K2_SetRelativeLocation(loc, false, hitResult, false)
        pmc:K2_SetRelativeRotation(rot, false, hitResult, false)
    end)
end

-- All slider IDs Ã¢â‚¬â€ used for profile save/load
local ids = {
    "pmcOffX","pmcOffY","pmcOffZ","pmcRotPitch","pmcRotYaw","pmcRotRoll",
    "lhPmcOffX","lhPmcOffY","lhPmcOffZ","lhPmcRotPitch","lhPmcRotYaw","lhPmcRotRoll",
    "lhSocket",
    "scaleX","scaleY","scaleZ","offX","offY","offZ",
    "lhScaleX","lhScaleY","lhScaleZ","lhOffX","lhOffY","lhOffZ",
    "slOffX","slOffY","slOffZ","slRotPitch","slRotYaw","slRotRoll",
    "flOffX","flOffY","flOffZ","flScaleX","flScaleY","flScaleZ","flRotPitch","flRotYaw","flRotRoll",
    "debugMode"
}

for _, id in ipairs(ids) do
    configui.onUpdate(id, function(value)
        applyBoxSizes()

        -- Live-apply right PMC offset changes
        if id == "pmcOffX" or id == "pmcOffY" or id == "pmcOffZ"
        or id == "pmcRotPitch" or id == "pmcRotYaw" or id == "pmcRotRoll" then
            local pmc = getRightPMC()
            if pmc then applyPMCOffset(pmc) end
        end
        -- Live-apply left PMC offset changes while gripping
        if id == "lhPmcOffX" or id == "lhPmcOffY" or id == "lhPmcOffZ"
        or id == "lhPmcRotPitch" or id == "lhPmcRotYaw" or id == "lhPmcRotRoll" then
            if leftHandParentedToGun then
                local pmc = getLeftPMC()
                local _, weaponMesh, _ = getEquippedWeaponForCronos(api:get_local_pawn(0))
                if pmc and isAlive(pmc) and weaponMesh then
                    pcall(function() attachLeftPMCToGun(pmc, weaponMesh) end)
                end
            end
        end

        -- Save to weapon profile
        if currentWeapon ~= "None" then
            if weaponProfiles[currentWeapon] == nil then
                weaponProfiles[currentWeapon] = {}
            end
            weaponProfiles[currentWeapon][id] = value
            saveProfiles()
        end
    end)
end

local function applyProfileValues(weaponName)
    local profile = weaponProfiles[weaponName]
    if not profile then return end
    for _, id in ipairs(ids) do
        if profile[id] ~= nil then
            configui.setValue(id, profile[id])
        end
    end
end

local function initBoxes(pawn, weaponMesh, leftHand)
    local cls = getBoxClass()
    if not cls then return end

    if not isAlive(BoxCompLH) then
        BoxCompLH = nil
        local ok, _ = pcall(function()
            BoxCompLH = uevr.api:add_component_by_class(pawn, cls)
        end)
        if ok and isAlive(BoxCompLH) then
            pcall(function()
                BoxCompLH:K2_AttachToComponent(leftHand, "Root", 0, 0, 0, true)
                BoxCompLH:SetGenerateOverlapEvents(true)
                BoxCompLH:SetCollisionObjectType(2)
                BoxCompLH:SetCollisionResponseToAllChannels(1)
                BoxCompLH:SetCollisionEnabled(1)
            end)
        end
    end

    if not isAlive(GripBox) then
        GripBox = nil
        local ok, _ = pcall(function()
            GripBox = uevr.api:add_component_by_class(pawn, cls)
        end)
        if ok and isAlive(GripBox) then
            pcall(function()
                GripBox:K2_AttachToComponent(weaponMesh, "GG_LeftHandHandle", 2, 2, 2, false)
                GripBox:SetGenerateOverlapEvents(true)
                GripBox:SetCollisionObjectType(2)
                GripBox:SetCollisionResponseToAllChannels(1)
                GripBox:SetCollisionEnabled(1)
            end)
        end
    else
        pcall(function()
            GripBox:K2_AttachToComponent(weaponMesh, "GG_LeftHandHandle", 2, 2, 2, false)
        end)
    end

    -- Flashlight Collision Boxes:
    --   FlashBoxLH  â”€ attached to left hand PMC near the flashlight socket (zone anchor)
    --   FlashBoxRH  â”€ attached to right controller (the "hand" that reaches into the zone)
    -- When FlashBoxRH overlaps FlashBoxLH and right grip is pressed, we toggle.
    local leftPMCForBox = hands.getHandComponent(Handed.Left)
    if leftPMCForBox and isAlive(leftPMCForBox) then
        if not isAlive(FlashBoxLH) then
            FlashBoxLH = nil
            local ok3, _ = pcall(function()
                FlashBoxLH = uevr.api:add_component_by_class(pawn, cls)
            end)
            if ok3 and isAlive(FlashBoxLH) then
                pcall(function()
                    FlashBoxLH:K2_AttachToComponent(leftPMCForBox, "root", 0, 0, 0, true)
                    FlashBoxLH:SetGenerateOverlapEvents(true)
                    FlashBoxLH:SetCollisionObjectType(2)
                    FlashBoxLH:SetCollisionResponseToAllChannels(1)
                    FlashBoxLH:SetCollisionEnabled(1)  -- QueryOnly, for overlap detection
                end)
            end
        end
    end
    if not isAlive(FlashBoxRH) then
        FlashBoxRH = nil
        local ok4, _ = pcall(function()
            FlashBoxRH = uevr.api:add_component_by_class(pawn, cls)
        end)
        if ok4 and isAlive(FlashBoxRH) then
            pcall(function()
                controllers.attachComponentToController(1, FlashBoxRH)
                FlashBoxRH:SetGenerateOverlapEvents(true)
                FlashBoxRH:SetCollisionObjectType(2)
                FlashBoxRH:SetCollisionResponseToAllChannels(1)
                FlashBoxRH:SetCollisionEnabled(1)  -- QueryOnly
                -- Small fixed box â€“ just enough to detect right-hand presence
                FlashBoxRH.RelativeScale3D.X = 0.2
                FlashBoxRH.RelativeScale3D.Y = 0.2
                FlashBoxRH.RelativeScale3D.Z = 0.2
                print("[FL] FlashBoxRH created on right controller")
            end)
        end
    end

    applyBoxSizes()
end

uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() or view_index ~= 1 then return end

    local pawn = api:get_local_pawn(0)
    if not pawn then return end

    -- Detect level load / respawn Ã¢â‚¬â€ pawn identity changes each time
    if pawn ~= lastPawn then
        lastPawn = pawn
        resetLevelState()
    end

    local rightHand, leftHand = getControllerComponents()
    if not rightHand or not leftHand then return end

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Right hand PMC Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    local rightPMC = getRightPMC()
    local pmcAlive = rightPMC and isAlive(rightPMC)

    local weaponComponent, weaponMesh, skelName = getEquippedWeaponForCronos(pawn)
    local gunEquipped = weaponComponent ~= nil and weaponMesh ~= nil

    local hasPunch = gestures.getGesture(gestures.Gesture.PUNCH)

    -- Punch fires true for ONE frame only (speed peak). Start a 1.5-second
    -- timer so the PMC stays free from the gun for the full melee animation.
    -- Matches the 1500ms punchResetTimer in hands.lua.
    if hasPunch and not punchAnimationActive then
        punchAnimationActive = true
        if punchGunDetachTimer then uevrUtils.clearTimeout(punchGunDetachTimer) end
        punchGunDetachTimer = uevrUtils.setTimeout(1500, function()
            punchAnimationActive = false
            punchGunDetachTimer  = nil
        end)
        print("[PMC] Punch detected Ã¢â‚¬â€ freeing PMC from gun for 1.5s")
    end

    if pmcAlive then
        captureBaseTransform(rightPMC)

        if punchAnimationActive and handParentedToGun then
            -- First tick of punch: detach PMC from gun socket Ã¢â€ â€™ follow right controller
            print("[PMC] Detaching from gun (melee active)")
            pcall(function() attachPMCToController(rightPMC, rightHand) end)
            handParentedToGun = false

        elseif gunEquipped and not handParentedToGun and not punchAnimationActive then
            -- Punch animation finished Ã¢â‚¬â€ re-parent to gun socket
            print("[PMC] Re-attaching to gun (melee ended)")
            pcall(function() attachPMCToGun(rightPMC, weaponMesh) end)
            handParentedToGun = true

        elseif not gunEquipped and handParentedToGun then
            -- Gun hidden/gone Ã¢â‚¬â€ free PMC
            pcall(function() attachPMCToController(rightPMC, rightHand) end)
            handParentedToGun = false
        end
    end

    -- â”€â”€ Flashlight zone overlap check (collision-based) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- Check every tick whether the right controller box is inside the flashlight zone.
    -- Result is stored in flashZoneOverlapping and read by the XInput callback.
    flashZoneOverlapping = false
    if isAlive(FlashBoxRH) and isAlive(FlashBoxLH) then
        local overlapping = {}
        pcall(function() FlashBoxRH:GetOverlappingComponents(overlapping) end)
        local flFullName = FlashBoxLH:get_full_name()
        for _, comp in ipairs(overlapping) do
            if comp and UEVR_UObjectHook.exists(comp) then
                if comp:get_full_name() == flFullName then
                    flashZoneOverlapping = true
                    break
                end
            end
        end
    end

    -- â”€â”€ Flashlight visibility enforcement (every tick) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- The game's Blueprint logic can override SetVisibility, so we re-apply our
    -- desired state each frame to guarantee it wins.
    if cachedFlashFL == nil then
        local now = os.clock()
        if now - flSearchTime > 2.0 then
            flSearchTime = now
            pcall(function() cachedFlashFL = findSpotlightForToggle() end)
            pcall(function() cachedFlashShaft = findFlashlightShaftForToggle() end)
        end
    else
        -- Validate still alive; invalidate if the object was GC'd
        local ok = pcall(function() cachedFlashFL:get_full_name() end)
        if not ok then cachedFlashFL = nil end
    end
    -- FlashlightShaft: search/validate independently
    if cachedFlashShaft == nil then
        local now = os.clock()
        if now - flSearchTime > 2.0 then   -- flSearchTime already throttles both
            pcall(function() cachedFlashShaft = findFlashlightShaftForToggle() end)
        end
    else
        local ok = pcall(function() cachedFlashShaft:get_full_name() end)
        if not ok then cachedFlashShaft = nil end
    end
    -- Enforce spotlight
    if cachedFlashFL ~= nil then
        pcall(function()
            cachedFlashFL:SetVisibility(flashlightOn, true)
            cachedFlashFL:SetHiddenInGame(not flashlightOn, true)
        end)
    end
    -- Enforce shaft beam
    if cachedFlashShaft ~= nil then
        pcall(function()
            cachedFlashShaft:SetVisibility(flashlightOn, true)
            cachedFlashShaft:SetHiddenInGame(not flashlightOn, true)
        end)
    end

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Nothing more to do without a gun Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    if not gunEquipped then return end

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Weapon switch detection Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    if skelName ~= nil and skelName ~= currentWeapon then
        currentWeapon = skelName
        configui.setLabel("weapon_label", "Current Weapon: " .. currentWeapon)
        applyProfileValues(currentWeapon)
        applyBoxSizes()
        -- Re-apply PMC offset for new weapon profile
        if rightPMC and isAlive(rightPMC) and handParentedToGun then
            pcall(function() attachPMCToGun(rightPMC, weaponMesh) end)
        end
    end

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Grip collision boxes Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    initBoxes(pawn, weaponMesh, leftHand)

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Two-handed aiming Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    local isTwoHandedWeapon = true
    local isPhysicallyGripping = false

    if isAlive(BoxCompLH) and isAlive(GripBox) then
        local overlapping = {}
        pcall(function() BoxCompLH:GetOverlappingComponents(overlapping) end)
        local gripFullName = GripBox:get_full_name()
        for _, comp in ipairs(overlapping) do
            if comp and UEVR_UObjectHook.exists(comp) then
                if comp:get_full_name() == gripFullName then
                    isPhysicallyGripping = true
                    break
                end
            end
        end
    end

    -- Dev toggle: force 2-handing on regardless of physical detection
    if configui.getValue("forceTwoHand") == true then
        isPhysicallyGripping = true
    end

    -- Ã¢â€â‚¬Ã¢â€â‚¬ Left hand PMC re-parenting (MachineGun 2-hand grip) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
    local leftPMC = getLeftPMC()
    if leftPMC and isAlive(leftPMC) then
        captureLeftBaseTransform(leftPMC)

        local shouldLHParent = isTwoHandedWeapon
            and isPhysicallyGripping
            and (configui.getValue("lhSocket") ~= nil and configui.getValue("lhSocket") ~= "")
            and configui.getValue("twoHandEnabled") ~= false

        if shouldLHParent and not leftHandParentedToGun then
            pcall(function() attachLeftPMCToGun(leftPMC, weaponMesh) end)
            leftHandParentedToGun = true
            -- Tell handsAnimation the left hand is gripping so it applies
            -- grip_left_weapon instead of open_left every tick
            hands.setHoldingAttachment(Handed.Left, true)
        elseif not shouldLHParent and leftHandParentedToGun then
            pcall(function() attachLeftPMCToController(leftPMC) end)
            leftHandParentedToGun = false
            -- Restore open-hand animation
            hands.setHoldingAttachment(Handed.Left, false)
        end
    end

    -- â”€â”€ Left hand grip pose (forced every tick while 2-handing) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if leftHandParentedToGun and leftPMC and isAlive(leftPMC) then
        local pose = LH_WEAPON_POSES[currentWeapon] or LH_GRIP_POSE
        pcall(function()
            animation.initializeBones(leftPMC, pose)
        end)
    end

    if isTwoHandedWeapon and isPhysicallyGripping and configui.getValue("twoHandEnabled") ~= false then
        twoHandedAiming.applyTwoHandedRotation(weaponComponent, rightHand, leftHand)
    end
end)
-- == Flashlight toggle (collision-box overlap) ==
-- FlashBoxRH on right controller overlaps FlashBoxLH on left hand → grip toggles flashlight.
-- flashZoneOverlapping is computed every stereo tick and cached for use here.
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if user_index ~= 0 then return end

    if gestures.getGesture(gestures.Gesture.PUNCH) then
        rightGripWasDown = true
        return
    end

    local rightGripNow = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_RIGHT_SHOULDER)

    if rightGripNow and flashZoneOverlapping then
        -- Suppress this press from reaching the game so melee never fires
        uevrUtils.unpressButton(state, XINPUT_GAMEPAD_RIGHT_SHOULDER)
        -- Rising edge only: toggle once per press, not every frame
        if not rightGripWasDown then
            flashlightOn = not flashlightOn
            print("[FL] Spotlight toggled -> "..tostring(flashlightOn))
        end
    end

    rightGripWasDown = rightGripNow
end)

