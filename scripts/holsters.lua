-- Holsters (2026-11-13, the Hellraiser / BL4 holsters ported to Cronos). Right grip pressed with the right hand in a
-- body zone = a d-pad tap, which selects that weapon slot in the game:
--   right hip      -> d-pad up    weapon slot 1
--   right shoulder -> d-pad right weapon slot 2
--   left shoulder  -> d-pad down  weapon slot 3
--   left hip       -> d-pad left  weapon slot 4
--
-- Zones are boxes around the head in the HMD's yaw-only frame: origin = HMD position, yaw = HMD yaw (pitch / roll
-- ignored, so looking down at a hip does not move them). X forward, Y right, Z up, cm. Positions from
-- libs/controllers.lua (the libs have no body-zone gesture).
-- A zone press is a grip press that STARTS in a zone (holding the grip and moving into a zone does nothing). That
-- grip (RB) is then kept from the game until it is released, so the game never sees it. A short haptic pulse when the
-- hand enters a zone tells you where you are. Off in cutscenes / vents / ladders (hands.lua), while the game is paused
-- or shows a mouse cursor (menus), and while the right grip would toggle the arm flashlight (two_handed_integration).

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local BTN_RB    = 0x0200 -- XINPUT_GAMEPAD_RIGHT_SHOULDER (the right grip)
local BTN_UP    = 0x0001
local BTN_DOWN  = 0x0002
local BTN_LEFT  = 0x0004
local BTN_RIGHT = 0x0008
local TAP_POLLS = 3
local TAP_MAX_S = 0.25

-- body zones: id, label, button, default centre (cm, body frame)
local ZONES = {
    { id = "rhip", label = "Right hip (slot 1)",      button = BTN_UP,    x = 0.0,   y = 22.0,  z = -65.0 },
    { id = "rsh",  label = "Right shoulder (slot 2)", button = BTN_RIGHT, x = -12.0, y = 20.0,  z = -10.0 },
    { id = "lsh",  label = "Left shoulder (slot 3)",  button = BTN_DOWN,  x = -12.0, y = -20.0, z = -10.0 },
    { id = "lhip", label = "Left hip (slot 4)",       button = BTN_LEFT,  x = 0.0,   y = -22.0, z = -65.0 },
}

local layout = {
    { widgetType = "checkbox", id = "hz_enabled", label = "Holsters: right grip at the hips / shoulders = weapon slots 1-4", initialValue = true },
    { widgetType = "checkbox", id = "hz_haptic", label = "Haptic pulse when the hand enters a zone", initialValue = true },
    { widgetType = "slider_float", id = "hz_size", label = "Zone size (cm, half width of each box)", initialValue = 16.0, range = {6.0, 35.0}, speed = 0.5 },
    { widgetType = "text", id = "hz_status", label = "Hand: -" },
    { widgetType = "text", label = "Zone centres (cm from the HMD: forward / right / up, body facing)" },
}
for _, z in ipairs(ZONES) do
    table.insert(layout, { widgetType = "drag_float3", id = "hz_" .. z.id, label = z.label, initialValue = { z.x, z.y, z.z }, range = {-120, 120}, speed = 0.5 })
end
_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 2.8, label = "Holsters", layout = layout })

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

-- configui drag_float3 values come back as vectors (X/Y/Z) or arrays
local function zoneCentre(z)
    local v = configui.getValue("hz_" .. z.id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, zz = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(zz) == "number" then return x, y, zz end
    end
    return z.x, z.y, z.z
end

local function call(fn)
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn)
    return ok and result == true
end

local function isPausedOrMenu()
    local ok, result = pcall(function()
        local world = uevrUtils.get_world()
        if Statics ~= nil and world ~= nil and Statics:IsGamePaused(world) then return true end
        local pc = uevr.api:get_player_controller(0)
        return pc ~= nil and pc.bShowMouseCursor == true
    end)
    return ok and result == true
end

local function blocked()
    return call(_G.cronosIsCutscene) or isPausedOrMenu()
end

-- right hand in the zone frame: returns local x, y, z (cm) or nil
local function handLocal()
    local hand = controllers.getControllerLocation(Handed.Right)
    local head = controllers.getControllerLocation(2)
    if hand == nil or head == nil then return nil end
    local rot = controllers.getControllerRotation(2)
    local yaw = math.rad((rot and rot.Yaw) or 0)
    local dx, dy, dz = hand.X - head.X, hand.Y - head.Y, hand.Z - head.Z
    local c, s = math.cos(yaw), math.sin(yaw)
    return dx * c + dy * s, -dx * s + dy * c, dz
end

local function zoneAt(x, y, z)
    local h = cfgNum("hz_size", 16.0)
    for _, zone in ipairs(ZONES) do
        local cx, cy, cz = zoneCentre(zone)
        if math.abs(x - cx) <= h and math.abs(y - cy) <= h and math.abs(z - cz) <= h then return zone end
    end
    return nil
end

local current = nil       -- zone the hand is in (from the last input poll)
local nextStatusAt = 0    -- panel status line throttle
local gripWasDown = false
local swallowGrip = false -- the current grip press started a zone action: keep RB from the game until released
local tap = { button = 0, polls = 0, deadline = 0 }

local function startTap(zone)
    tap.button, tap.polls, tap.deadline = zone.button, TAP_POLLS, os.clock() + TAP_MAX_S
    pcall(function() vr.trigger_haptic_vibration(0, 0.08, 1.0, 1.0, vr.get_right_joystick_source()) end)
    print("[holsters] " .. zone.label)
end

-- Priority 25: before two_handed_integration (5), which reads the right grip for the arm flashlight
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local grip = uevrUtils.isButtonPressed(state, BTN_RB)
    local pressed = grip and not gripWasDown
    gripWasDown = grip

    if swallowGrip and not grip then swallowGrip = false end

    if configui.getValue("hz_enabled") ~= false and not blocked() then
        local ok, err = pcall(function()
            local x, y, z = handLocal()
            local zone = x ~= nil and zoneAt(x, y, z) or nil
            if zone ~= current then
                current = zone
                if zone ~= nil and configui.getValue("hz_haptic") ~= false then
                    pcall(function() vr.trigger_haptic_vibration(0, 0.03, 1.0, 0.4, vr.get_right_joystick_source()) end)
                end
            end
            if x ~= nil and os.clock() >= nextStatusAt then
                nextStatusAt = os.clock() + 0.2
                configui.setLabel("hz_status", string.format("Hand: %.0f / %.0f / %.0f cm - %s", x, y, z, zone and zone.label or "no zone"))
            end
            if pressed and zone ~= nil and tap.polls <= 0 and not call(_G.cronosRightGripIsFlashlight) then
                swallowGrip = true
                startTap(zone)
            end
        end)
        if not ok then print("[holsters] " .. tostring(err)) end
    elseif current ~= nil then
        current = nil
    end

    if swallowGrip and grip then state.Gamepad.wButtons = state.Gamepad.wButtons & ~BTN_RB end
    if tap.polls > 0 then
        if os.clock() > tap.deadline then
            tap.polls = 0
        else
            state.Gamepad.wButtons = state.Gamepad.wButtons | tap.button
            tap.polls = tap.polls - 1
        end
    end
end, 25)

uevrUtils.registerPreLevelChangeCallback(function(level)
    current, swallowGrip, tap.polls = nil, false, 0
end)

print("[holsters] loaded")
