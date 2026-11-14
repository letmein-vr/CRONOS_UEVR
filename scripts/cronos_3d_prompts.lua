-- cronos_3d_prompts.lua
-- Restores the interaction prompts in VR on the 2026-11-13 Cronos patch.
--
-- Why: that patch added a stereoscopic 3D display mode. Whenever GEngine's stereo rendering device is enabled
-- (always true under UEVR), SHInteractionIconComponent builds a world-space WidgetComponent3D and fills it with
-- the widget class from CronosUISettings.InteractionIconWidget3DClass. The shipped config leaves that soft class
-- empty, so the component never gets a widget and no prompt ever shows. Flat play uses the 2D class, which is set.
--
-- Fix: write /Game/Game/UI/Resources/Icons/Interactions/SHInteractionIconWidget3D_BP.SHInteractionIconWidget3D_BP_C
-- (the 3D prompt the game ships but never references) into that soft class on the CronosUISettings CDO.
-- It only writes when the slot is empty, so it steps aside if a later patch fills it. Icon components that already
-- exist pick it up the next time they activate.

local TAG = "[cronos_3d_prompts] "

local SETTINGS_CLASS = "Class /Script/Cronos.CronosUISettings"
local PROP_3D = "InteractionIconWidget3DClass"
local PROP_2D = "InteractionIconWidgetClass" -- populated by the game; used to validate the soft pointer layout
local PACKAGE_NAME = "/Game/Game/UI/Resources/Icons/Interactions/SHInteractionIconWidget3D_BP"
local ASSET_NAME = "SHInteractionIconWidget3D_BP_C"

-- TSoftClassPtr = FWeakObjectPtr (8) | FSoftObjectPath { PackageName FName (8), AssetName FName (8), SubPath (16) }
local OFF_PACKAGE = 0x08
local OFF_ASSET = 0x10

local api = uevr.api
local done = false
local attempts = 0
local MAX_ATTEMPTS = 600 -- about 10 s of engine ticks; the CDO is native, so this normally succeeds on the first try

-- print() does not reach log.txt; log_info / log_error do
local function log(msg)
    print(TAG .. msg)
    local f = uevr.params and uevr.params.functions
    if f ~= nil and f.log_info ~= nil then f.log_info(TAG .. msg) end
end

local function log_error(msg)
    print(TAG .. msg)
    local f = uevr.params and uevr.params.functions
    if f ~= nil and f.log_error ~= nil then f.log_error(TAG .. msg) end
end

local function get_cdo(className)
    local class = api:find_uobject(className)
    if class == nil then return nil end
    return class:get_class_default_object()
end

-- FName -> (comparison index, number), read through a scratch FGameplayTag (its only member is FName TagName)
local tagStruct = nil
local stringLib = nil
local function fname_parts(str)
    if tagStruct == nil then
        -- find_uobject only returns a typed object for UClass; a ScriptStruct comes back as a plain UObject
        local obj = api:find_uobject("ScriptStruct /Script/GameplayTags.GameplayTag")
        if obj ~= nil then tagStruct = obj:as_struct() end
    end
    if stringLib == nil then stringLib = get_cdo("Class /Script/Engine.KismetStringLibrary") end
    if tagStruct == nil or stringLib == nil then return nil end

    local prop = tagStruct:find_property("TagName")
    if prop == nil then return nil end
    local off = prop:get_offset()

    local tag = StructObject.new(tagStruct)
    tag.TagName = stringLib:Conv_StringToName(str)
    local index = tag:read_dword(off)
    local number = tag:read_dword(off + 4)
    if index == 0 then return nil end -- 0 = None: the FName was not created
    return index, number
end

local function apply()
    local settings = get_cdo(SETTINGS_CLASS)
    if settings == nil then return false end

    local class = settings:get_class()
    local prop3d = class:find_property(PROP_3D)
    local prop2d = class:find_property(PROP_2D)
    if prop3d == nil or prop2d == nil then
        log("CronosUISettings has no " .. PROP_3D .. " / " .. PROP_2D .. "; game version without the 3D prompt path, nothing to do")
        return true
    end
    local off3d = prop3d:get_offset()
    local off2d = prop2d:get_offset()

    -- layout check: the game's own 2D slot must hold a package and an asset FName where we expect them
    if settings:read_dword(off2d + OFF_PACKAGE) == 0 or settings:read_dword(off2d + OFF_ASSET) == 0 then
        log("unexpected soft pointer layout (2D slot empty at +0x08/+0x10); not writing")
        return true
    end

    if settings:read_dword(off3d + OFF_PACKAGE) ~= 0 or settings:read_dword(off3d + OFF_ASSET) ~= 0 then
        log(PROP_3D .. " is already set by the game; leaving it alone")
        return true
    end

    local pkgIndex, pkgNumber = fname_parts(PACKAGE_NAME)
    local assetIndex, assetNumber = fname_parts(ASSET_NAME)
    if pkgIndex == nil or assetIndex == nil then return false end -- name system not ready yet; retry next tick

    settings:write_dword(off3d + OFF_PACKAGE, pkgIndex)
    settings:write_dword(off3d + OFF_PACKAGE + 4, pkgNumber)
    settings:write_dword(off3d + OFF_ASSET, assetIndex)
    settings:write_dword(off3d + OFF_ASSET + 4, assetNumber)

    log(string.format("set %s = %s.%s (FNames 0x%X / 0x%X)", PROP_3D, PACKAGE_NAME, ASSET_NAME, pkgIndex, assetIndex))
    return true
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if done then return end
    attempts = attempts + 1
    local ok, result = pcall(apply)
    if not ok then
        log_error("error: " .. tostring(result))
        done = true
    elseif result then
        done = true
    elseif attempts >= MAX_ATTEMPTS then
        log_error("gave up: CronosUISettings or the FName helpers were not available")
        done = true
    end
end)
