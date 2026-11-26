-- Cronos manual reload (2026-11-26): port of the Borderlands 4 / Outer Worlds 2 manual reload, driven by the automatic
-- per-mode analysis in reload_analyzer.lua (data/cronos_manual_reload_auto.json) - no per-weapon tuning.
--
-- Cronos (MCP 2026-11-26):
--   * The MultiModeGun is ONE skeletal mesh per mode (asset swaps per mode); every weapon mode learns its own profile
--     ("<mode>|<mesh>"). The magazine is a gun bone (handgun GG_cartridge_02, SmartGun SmrtG_slide).
--   * The REAL gun is leader-posed onto a hidden PoseableMeshComponent "driver" for the manual reload (BL4): the item on
--     the gun during the insert stroke, the old magazine hidden, openers / racks are bones written on the driver.
--   * Away from the gun (falling, at the hip pouch, in the hand) the magazine is a COPY: a PoseableMeshComponent with the
--     gun's mesh where every bone but the item is collapsed to nothing at the item (OW2 bone isolation), placed in the
--     world or on the visible left hand's hand_l - gun-space bones show a frame late against the controllers (BL4).
--   * The reload is a montage on the hidden body (+ one on the gun): it is stopped at once when it starts (no ammo has
--     moved), and when the magazine is in, AmmoComponent:ReloadAddAmmo() fills it from the reserve (MCP: 10 -> 15, reserve
--     12 -> 7). Shell guns (ReloadAmmoAddedPerNotify 1) get one ReloadAddAmmo per shell.
--
-- Flow (as OW2): the game's reload button (or an empty gun) starts it; the magazine drops out; a magazine sits at the left
-- hip - take it with the left grip, bring it to the well (it glides onto the learned insert stroke); a learned rack part is
-- pulled and let go. A mode without a profile (or without its empty-reload recording yet) reloads natively so the analyzer
-- can learn it.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')
local animation = require('libs/animation')
local hands = nil
pcall(function() hands = require('libs/hands') end)
local ik = nil
pcall(function() ik = require('libs/ik') end)

local vr = uevr.params.vr

local BTN_LB = 0x0100        -- left grip (XINPUT_GAMEPAD_LEFT_SHOULDER)
local RTS_WORLD = 0
local RTS_COMPONENT = 2
local BONE_SPACE_COMPONENT = 1
local HAND_BONE = "hand_l"
local FINISH_TIMEOUT_S = 1.5
local DROP_TIME_S = 0.6
local HIDDEN_SCALE = 0.001

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 2.9, label = "Manual Reload", layout = {
    { widgetType = "checkbox", id = "mr_enabled", label = "Manual reload (reload drops the magazine, take a new one from the left hip and push it in)", initialValue = true },
    { widgetType = "checkbox", id = "mr_rack", label = "Rack the slide / charging handle after an empty magazine", initialValue = true },
    { widgetType = "text", id = "mr_status", label = "Manual reload: -" },
    { widgetType = "drag_float3", id = "mr_pouch_loc", label = "Hip pouch position (cm from the HMD: forward / right / up, body facing)", initialValue = { 8.0, -24.0, -58.0 }, range = {-120, 120}, speed = 0.5 },
    { widgetType = "slider_float", id = "mr_grab_radius", label = "Grab: hand within (cm of the pouch)", initialValue = 13.0, range = {4.0, 30.0} },
    { widgetType = "slider_float", id = "mr_round_insert_radius", label = "Round by round: insert radius (cm, any side of the stroke)", initialValue = 12.0, range = {3.0, 25.0} },
    { widgetType = "slider_float", id = "mr_insert_radius", label = "Insert: magazine within (cm of the well)", initialValue = 7.0, range = {2.0, 20.0} },
    { widgetType = "slider_float", id = "mr_rack_radius", label = "Rack: hand within (cm of the slide)", initialValue = 10.0, range = {3.0, 25.0} },
    { widgetType = "slider_float", id = "mr_rack_done", label = "Rack: pull at least (fraction of the travel)", initialValue = 0.8, range = {0.3, 1.0} },
    { widgetType = "slider_float", id = "mr_grab_glide", label = "Pouch to hand glide time (s)", initialValue = 0.10, range = {0.0, 0.5} },
    { widgetType = "slider_float", id = "mr_insert_time", label = "Insert glide time (s)", initialValue = 0.15, range = {0.03, 0.6} },
    { widgetType = "slider_float", id = "mr_predict", label = "Magazine motion prediction (frames ahead)", initialValue = 1.0, range = {0.0, 3.0} },
    { widgetType = "checkbox", id = "mr_fingers", label = "Left hand takes the game's finger pose on the magazine", initialValue = true },
    { widgetType = "slider_float", id = "mr_finger_blend", label = "Finger pose blend time (s)", initialValue = 0.2, range = {0.0, 0.8} },
    { widgetType = "checkbox", id = "mr_flick_close", label = "Flick the gun to close a swung-out cylinder / break (off = closes by itself)", initialValue = true },
    { widgetType = "slider_float", id = "mr_flick_speed", label = "Flick: gun speed at least (cm/s)", initialValue = 110.0, range = {40.0, 400.0} },
    { widgetType = "checkbox", id = "mr_haptics", label = "Haptics", initialValue = true },
    { widgetType = "checkbox", id = "mr_marker", label = "Show where the magazine goes (a glowing dot at the well while you take / hold one)", initialValue = true },
    { widgetType = "slider_float", id = "mr_marker_size", label = "Dot size (cm, every gun - per gun in Tuning)", initialValue = 7.0, range = {0.5, 15.0} },
    { widgetType = "slider_float", id = "mr_marker_opacity", label = "Dot opacity", initialValue = 0.54, range = {0.05, 1.0} },
    { widgetType = "color_picker", id = "mr_marker_color", label = "Dot colour", initialValue = "#1CF400FF" },
    { widgetType = "slider_float", id = "mr_marker_brightness", label = "Dot brightness", initialValue = 5.0, range = {0.1, 10.0} },
    { widgetType = "checkbox", id = "mr_log", label = "Log to log.txt", initialValue = false },
    { widgetType = "checkbox", id = "mr_dev_ammo", label = "Dev: keep the ammo reserve topped up (every 3 s)", initialValue = false },
}})

-- per-mode manual overrides of the learned values: offsets for the item in the left hand and for its seat in the gun,
-- saved per profile key in data/cronos_manual_reload_tune.json, applied live
table.insert(_G.CRONOS_SECTIONS, { order = 2.92, label = "Manual Reload - Tuning (this gun)", layout = {
    { widgetType = "text", id = "mr_tune_gun", label = "Gun: -" },
    { widgetType = "text", label = "In the left hand (cm / deg, hand frame):" },
    { widgetType = "drag_float3", id = "mr_tune_hold_loc", label = "Hold offset", initialValue = { 0.0, 0.0, 0.0 }, range = {-40, 40}, speed = 0.1 },
    { widgetType = "drag_float3", id = "mr_tune_hold_rot", label = "Hold rotation (pitch / yaw / roll)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
    { widgetType = "text", label = "Seated in the gun (cm / deg, gun frame):" },
    { widgetType = "drag_float3", id = "mr_tune_seat_loc", label = "Seat offset", initialValue = { 0.0, 0.0, 0.0 }, range = {-40, 40}, speed = 0.1 },
    { widgetType = "drag_float3", id = "mr_tune_seat_rot", label = "Seat rotation (pitch / yaw / roll)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
    { widgetType = "text", label = "Well dot (shows while you take / hold a magazine):" },
    { widgetType = "combo", id = "mr_tune_marker_shape", label = "Dot shape", initialValue = 1, selections = { "Sphere", "Cube" } },
    { widgetType = "slider_float", id = "mr_tune_marker_size", label = "Dot size (cm, 0 = the Manual Reload default)", initialValue = 0.0, range = {0.0, 15.0} },
    { widgetType = "drag_float3", id = "mr_tune_marker_loc", label = "Dot offset (cm, gun frame)", initialValue = { 0.0, 0.0, 0.0 }, range = {-40, 40}, speed = 0.1 },
    { widgetType = "button", id = "mr_tune_reset", label = "Reset this gun's tuning", size = {200, 22} },
}})

-- -------------------------------------------------------------------------------------------------------------------
-- helpers
-- -------------------------------------------------------------------------------------------------------------------
local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end
local function cfgVec(id, default)
    local v = configui.getValue(id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, z = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    end
    return default[1], default[2], default[3]
end
local function info(s) pcall(function() uevr.params.functions.log_info("[manual_reload] " .. s) end) end
local function log(s) if configui.getValue("mr_log") == true then info(s) end end
local lastStatus = nil
local function status(s)
    if s == lastStatus then return end
    lastStatus = s
    pcall(function() configui.setLabel("mr_status", "Manual reload: " .. s) end)
end
local function haptic(duration, amplitude)
    if configui.getValue("mr_haptics") == false then return end
    pcall(function() vr.trigger_haptic_vibration(0, duration, 1.0, amplitude, vr.get_left_joystick_source()) end)
end
local function exists(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and r == true
end
local function fname(s) return uevrUtils.fname_from_string(s) end
local function vec(x, y, z) return uevrUtils.vector(x, y, z) end

-- transforms as { loc = {X,Y,Z}, q = {X,Y,Z,W} } (UE quaternion convention)
local function qmul(a, b)
    return {
        X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
        Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
        W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z,
    }
end
local function qconj(q) return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W } end
local function qrot(q, v)
    local p = qmul(qmul(q, { X = v.X, Y = v.Y, Z = v.Z, W = 0 }), qconj(q))
    return { X = p.X, Y = p.Y, Z = p.Z }
end
local function addV(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function subV(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function mulV(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
local function dotV(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function lenV(a) return math.sqrt(dotV(a, a)) end
local function compose(a, b) return { loc = addV(a.loc, qrot(a.q, b.loc)), q = qmul(a.q, b.q) } end
local function inv(a) local c = qconj(a.q) return { loc = qrot(c, mulV(a.loc, -1)), q = c } end
local IDENT = { loc = { X = 0, Y = 0, Z = 0 }, q = { X = 0, Y = 0, Z = 0, W = 1 } }
local function nlerpQ(a, b, t)
    local d = a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W
    local s = d < 0 and -1 or 1
    local q = { X = a.X + (s * b.X - a.X) * t, Y = a.Y + (s * b.Y - a.Y) * t, Z = a.Z + (s * b.Z - a.Z) * t, W = a.W + (s * b.W - a.W) * t }
    local l = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    return { X = q.X / l, Y = q.Y / l, Z = q.Z / l, W = q.W / l }
end
local function lerpT(a, b, t) return { loc = addV(a.loc, mulV(subV(b.loc, a.loc), t)), q = nlerpQ(a.q, b.q, t) } end
local function q2r(q)
    local sing = q.Z * q.X - q.W * q.Y
    local yawY = 2 * (q.W * q.Z + q.X * q.Y)
    local yawX = 1 - 2 * (q.Y * q.Y + q.Z * q.Z)
    local yaw = math.deg(math.atan(yawY, yawX))
    if sing < -0.4999995 then
        return { Pitch = -90, Yaw = yaw, Roll = -yaw - 2 * math.deg(math.atan(q.X, q.W)) }
    elseif sing > 0.4999995 then
        return { Pitch = 90, Yaw = yaw, Roll = yaw - 2 * math.deg(math.atan(q.X, q.W)) }
    end
    return { Pitch = math.deg(math.asin(2 * sing)), Yaw = yaw,
             Roll = math.deg(math.atan(-2 * (q.W * q.X + q.Y * q.Z), 1 - 2 * (q.X * q.X + q.Y * q.Y))) }
end
local function fromUE(t)
    return { loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
             q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W } }
end
local function fromProfile(p)
    if p == nil then return nil end
    return { loc = { X = p.loc.X, Y = p.loc.Y, Z = p.loc.Z }, q = { X = p.q.X, Y = p.q.Y, Z = p.q.Z, W = p.q.W } }
end
-- a right-hand grip as a left-hand one: mirrored across the gun's centre plane (x = 0 in the Cronos gun frame)
local function mirrorT(t) return { loc = { X = -t.loc.X, Y = t.loc.Y, Z = t.loc.Z }, q = { X = t.q.X, Y = -t.q.Y, Z = -t.q.Z, W = t.q.W } } end
local function ueTransform(t, s)
    local r = q2r(t.q)
    s = s or 1
    return kismet_math_library:MakeTransform(vec(t.loc.X, t.loc.Y, t.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), vec(s, s, s))
end
local function setRelative(comp, t)
    local r = q2r(t.q)
    comp:K2_SetRelativeLocationAndRotation(vec(t.loc.X, t.loc.Y, t.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, true)
end
local function worldOf(comp) return fromUE(comp:K2_GetComponentToWorld()) end
local function smooth(t) return t * t * (3 - 2 * t) end

-- FRotator (deg) -> FQuat, UE convention
local function r2q(p, y, r)
    local d = math.pi / 360
    local sp, cp = math.sin(p * d), math.cos(p * d)
    local sy, cy = math.sin(y * d), math.cos(y * d)
    local sr, cr = math.sin(r * d), math.cos(r * d)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
             Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

-- -------------------------------------------------------------------------------------------------------------------
-- per-gun tuning (panel "Manual Reload - Tuning (this gun)")
-- -------------------------------------------------------------------------------------------------------------------
local TUNE_FILE = "cronos_manual_reload_tune.json"
local tune = {}
pcall(function() local t = json.load_file(TUNE_FILE) if type(t) == "table" then tune = t end end)
local tuneKey = nil
local TUNE_IDS = { hl = "mr_tune_hold_loc", hr = "mr_tune_hold_rot", sl = "mr_tune_seat_loc", sr = "mr_tune_seat_rot",
                   ml = "mr_tune_marker_loc" }

local function tuneVec(field)
    local t = tuneKey ~= nil and tune[tuneKey] or nil
    local v = t ~= nil and t[field] or nil
    if type(v) ~= "table" then return 0, 0, 0 end
    return v[1] or 0, v[2] or 0, v[3] or 0
end
-- item pose in the hand frame -> with the hold tuning
local function tunedHold(rel)
    local x, y, z = tuneVec("hl")
    local p, yw, r = tuneVec("hr")
    return { loc = addV(rel.loc, { X = x, Y = y, Z = z }), q = qmul(r2q(p, yw, r), rel.q) }
end
-- seat / approach (gun space) -> with the seat tuning (the approach keeps its offset from the seat)
local function tunedSeat(seat, approach)
    local x, y, z = tuneVec("sl")
    local p, yw, r = tuneVec("sr")
    local R = r2q(p, yw, r)
    local s = { loc = addV(seat.loc, { X = x, Y = y, Z = z }), q = qmul(R, seat.q) }
    local a = { loc = addV(s.loc, qrot(R, subV(approach.loc, seat.loc))), q = qmul(R, approach.q) }
    return s, a
end

local function loadTuneUI(key)
    tuneKey = key
    local t = key ~= nil and tune[key] or {}
    pcall(function() configui.setLabel("mr_tune_gun", "Gun: " .. tostring(key or "-")) end)
    for field, id in pairs(TUNE_IDS) do
        local v = t[field]
        if type(v) ~= "table" then v = { 0, 0, 0 } end
        pcall(function() configui.setValue(id, { v[1] or 0, v[2] or 0, v[3] or 0 }, true) end)
    end
    local ms = type(t.ms) == "number" and t.ms or 0.0
    pcall(function() configui.setValue("mr_tune_marker_size", ms, true) end)
    pcall(function() configui.setValue("mr_tune_marker_shape", t.mk == 2 and 2 or 1, true) end)
end

configui.onUpdate("mr_tune_marker_size", function(value)
    if tuneKey == nil or type(value) ~= "number" then return end
    tune[tuneKey] = tune[tuneKey] or {}
    tune[tuneKey].ms = value > 0 and value or nil
    pcall(function() json.dump_file(TUNE_FILE, tune, 1) end)
end)
configui.onUpdate("mr_tune_marker_shape", function(value)
    if tuneKey == nil or type(value) ~= "number" then return end
    tune[tuneKey] = tune[tuneKey] or {}
    tune[tuneKey].mk = value == 2 and 2 or nil   -- 2 = cube, nil = sphere
    pcall(function() json.dump_file(TUNE_FILE, tune, 1) end)
end)

for field, id in pairs(TUNE_IDS) do
    configui.onUpdate(id, function(value)
        if tuneKey == nil then return end
        local x, y, z = cfgVec(id, { 0, 0, 0 })
        tune[tuneKey] = tune[tuneKey] or {}
        tune[tuneKey][field] = { x, y, z }
        pcall(function() json.dump_file(TUNE_FILE, tune, 1) end)
    end)
end
configui.onUpdate("mr_tune_reset", function()
    if tuneKey == nil then return end
    tune[tuneKey] = nil
    pcall(function() json.dump_file(TUNE_FILE, tune, 1) end)
    uevrUtils.setTimeout(1, function() loadTuneUI(tuneKey) end)
end)

local function blocked()
    if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return "cutscene" end
    local world = uevrUtils.get_world()
    if world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true then return "paused" end
    return nil
end

local FINGER_WORDS = { "index", "middle", "ring", "pinky", "thumb" }
local function isFingerBone(name)
    local low = name:lower()
    for _, w in ipairs(FINGER_WORDS) do if low:find(w, 1, true) then return true end end
    return false
end

-- the visible left hand: the IK rig (IK mode) or the glove hand (Hands mode), from hands.lua; both carry hand_l
local function leftHandMesh()
    local m = nil
    if _G.cronosGetHandMesh ~= nil then pcall(function() m = _G.cronosGetHandMesh(Handed.Left) end) end
    if m == nil then pcall(function() m = hands.getHandComponent(Handed.Left) end) end
    if exists(m) then return m end
    return nil
end

-- MetaHuman bone sides: "<name>_l" / "<name>_r"
local function swapSide(name, from, to)
    local s, n = name:gsub("_" .. from .. "$", "_" .. to)
    return n > 0 and s or nil
end

-- -------------------------------------------------------------------------------------------------------------------
-- right-hand guns: the game's right-hand pose mirrored onto the left hand (OW2 2026-11-19)
-- L = M * R * F (M = mirror X: the Cronos gun frame is +Y forward, X across; F = diagonal +-1, det -1), F read from the
-- body's reference pose (MetaHuman finger roots index_metacarpal_l ... are direct children of hand_l / hand_r).
-- -------------------------------------------------------------------------------------------------------------------
local function q2m(q)
    local x, y, z, w = q.X, q.Y, q.Z, q.W
    return {
        { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
        { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
        { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) },
    }
end
local function m2q(m)
    local tr = m[1][1] + m[2][2] + m[3][3]
    local q
    if tr > 0 then
        local S = math.sqrt(tr + 1.0) * 2
        q = { W = 0.25 * S, X = (m[3][2] - m[2][3]) / S, Y = (m[1][3] - m[3][1]) / S, Z = (m[2][1] - m[1][2]) / S }
    elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
        local S = math.sqrt(1.0 + m[1][1] - m[2][2] - m[3][3]) * 2
        q = { W = (m[3][2] - m[2][3]) / S, X = 0.25 * S, Y = (m[1][2] + m[2][1]) / S, Z = (m[1][3] + m[3][1]) / S }
    elseif m[2][2] > m[3][3] then
        local S = math.sqrt(1.0 + m[2][2] - m[1][1] - m[3][3]) * 2
        q = { W = (m[1][3] - m[3][1]) / S, X = (m[1][2] + m[2][1]) / S, Y = 0.25 * S, Z = (m[2][3] + m[3][2]) / S }
    else
        local S = math.sqrt(1.0 + m[3][3] - m[1][1] - m[2][2]) * 2
        q = { W = (m[2][1] - m[1][2]) / S, X = (m[1][3] + m[3][1]) / S, Y = (m[2][3] + m[3][2]) / S, Z = 0.25 * S }
    end
    local l = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    return { X = q.X / l, Y = q.Y / l, Z = q.Z / l, W = q.W / l }
end
local function diagMul(a, m, b)
    local r = {}
    for i = 1, 3 do r[i] = {} for j = 1, 3 do r[i][j] = a[i] * m[i][j] * b[j] end end
    return r
end

local mirrorF = nil -- { fx, fy, fz } or nil (not read yet / could not be read)
local boneFlip = nil -- left bone name -> { fx, fy, fz }
-- MetaHuman finger roots under hand_l / hand_r (the body CharacterMesh0)
local REF_PROBES = { "index_metacarpal", "middle_metacarpal", "ring_metacarpal", "pinky_metacarpal", "thumb_01", "index_01", "middle_01" }
local function mirrorFFromRefPose(arms)
    local acc = { 0, 0, 0 }
    local pairs_ = {}
    for _, n in ipairs(REF_PROBES) do
        local il = arms:GetBoneIndex(fname(n .. "_l"))
        local ir = arms:GetBoneIndex(fname(n .. "_r"))
        if il ~= nil and ir ~= nil and il >= 0 and ir >= 0
            and arms:GetParentBone(fname(n .. "_l")):to_string() == "hand_l"
            and arms:GetParentBone(fname(n .. "_r")):to_string() == "hand_r" then
            local l, r = arms:GetRefPosePosition(il), arms:GetRefPosePosition(ir)
            l, r = { X = l.X, Y = l.Y, Z = l.Z }, { X = r.X, Y = r.Y, Z = r.Z }
            acc[1], acc[2], acc[3] = acc[1] + l.X * r.X, acc[2] + l.Y * r.Y, acc[3] + l.Z * r.Z
            pairs_[#pairs_ + 1] = { l = l, r = r }
        end
    end
    if #pairs_ < 3 then info("mirror axes: only " .. #pairs_ .. " finger roots under the hand bones") return nil end
    local F = { acc[1] >= 0 and 1 or -1, acc[2] >= 0 and 1 or -1, acc[3] >= 0 and 1 or -1 }
    local err = 0
    for _, p in ipairs(pairs_) do
        err = math.max(err, lenV(subV(p.l, { X = F[1] * p.r.X, Y = F[2] * p.r.Y, Z = F[3] * p.r.Z })))
    end
    info(string.format("mirror axes F = (%d, %d, %d) from the ref pose (%d probes), fit error %.2f cm", F[1], F[2], F[3], #pairs_, err))
    if err > 0.5 or F[1] * F[2] * F[3] ~= -1 then return nil end
    return F
end

-- every finger bone has its own axis flip: F_bone = local_R^T * F_parent * local_L (ref pose, parent first)
local function computeBoneFlips(arms, F)
    local out = { hand_l = F }
    local n = arms:GetNumBones()
    for i = 0, n - 1 do
        local lf = arms:GetBoneName(i)
        local lname = lf:to_string()
        local rname = swapSide(lname, "l", "r")
        if rname ~= nil and lname ~= "hand_l" then
            local parent = arms:GetParentBone(lf):to_string()
            local Fp = out[parent]
            if Fp ~= nil then
                local ir = arms:GetBoneIndex(fname(rname))
                if ir ~= nil and ir >= 0 then
                    local L, R = arms:GetRefPoseTransform(i), arms:GetRefPoseTransform(ir)
                    local mL = q2m({ X = L.Rotation.X, Y = L.Rotation.Y, Z = L.Rotation.Z, W = L.Rotation.W })
                    local mR = q2m({ X = R.Rotation.X, Y = R.Rotation.Y, Z = R.Rotation.Z, W = R.Rotation.W })
                    local fb, ok = {}, true
                    for j = 1, 3 do
                        local d = 0
                        for k = 1, 3 do d = d + mR[k][j] * Fp[k] * mL[k][j] end
                        if math.abs(math.abs(d) - 1) > 0.1 then ok = false end
                        fb[j] = d >= 0 and 1 or -1
                    end
                    if ok and fb[1] * fb[2] * fb[3] == -1 then out[lname] = fb end
                end
            end
        end
    end
    return out
end

local function computeMirrorF(arms)
    if mirrorF then return mirrorF end -- a failed fit is not cached
    local ok, F = pcall(mirrorFFromRefPose, arms)
    if ok and F ~= nil then
        mirrorF = F
        local okB, res = pcall(computeBoneFlips, arms, F)
        if okB then boneFlip = res else info("finger bone flips: " .. tostring(res)) end
    elseif not ok then
        info("mirror axes: " .. tostring(F))
    end
    return mirrorF
end

-- Cronos gun frame: +Y forward (barrel), +Z up, X across - the gun's centre plane is x = 0 (every SmartGun bone sits
-- at x = 0). A right-hand bone pose in the gun frame -> the left hand's, mirrored across the plane x = planeX.
local function mirrorHandInGun(H, planeX, F)
    local loc = { X = 2 * planeX - H.loc.X, Y = H.loc.Y, Z = H.loc.Z }
    return { loc = loc, q = m2q(diagMul({ -1, 1, 1 }, q2m(H.q), F)) }
end

-- a right-hand finger pose (hand-relative, *_r bones) -> the left hand's
local function mirrorFingers(pose, F)
    if pose == nil or not F then return nil end
    local out = {}
    for name, T in pairs(pose) do
        local t = fromProfile(T)
        local lname = swapSide(name, "r", "l") or name
        local Fb = (boneFlip ~= nil and boneFlip[lname]) or F
        local m = diagMul(F, q2m(t.q), Fb)
        out[lname] = { loc = { X = F[1] * t.loc.X, Y = F[2] * t.loc.Y, Z = F[3] * t.loc.Z }, q = m2q(m) }
    end
    return out
end

-- -------------------------------------------------------------------------------------------------------------------
-- the driver: a hidden poseable with the gun's rig; the real gun is leader-posed onto it while a manual reload runs
-- -------------------------------------------------------------------------------------------------------------------
local driver = nil   -- { comp, gun, boundsScale }

-- scale: explicit (the item: shown 1 / hidden), else the bone's own scale in the game's pose at the catch - the game
-- parks parts it is not showing scaled to nothing (Jakobs Mag01: the speedloader's rounds sit 35 cm beside the gun at
-- scale 0); writing them at scale 1 showed them floating beside the gun after the insert (2026-11-23)
local function nativeScale(bone)
    driver.scales = driver.scales or {}
    local s = driver.scales[bone]
    if s == nil then
        s = 1
        pcall(function()
            local t = driver.comp:GetBoneTransformByName(fname(bone), BONE_SPACE_COMPONENT)
            local sc = t.Scale3D
            s = sc.X or sc.x or 1
        end)
        if s < HIDDEN_SCALE then s = HIDDEN_SCALE end -- a zero scale breaks the children's local transforms
        driver.scales[bone] = s
    end
    return s
end
-- The gun's pose (component space, with scale) of every bone the reload touches, as it was at the catch: written back
-- before the gun leaves the driver. Bones the gun's own animation does not drive keep whatever the driver last drew
-- (2026-11-23: the Jakobs speedloader stayed drawn floating beside the gun after the reload, through weapon switches,
-- while GetSocketTransform read its normal pose; hiding the bone removed it).
local function touchBone(bone)
    driver.native = driver.native or {}
    if driver.native[bone] ~= nil then return end
    local t = nil
    pcall(function() t = driver.comp:GetBoneTransformByName(fname(bone), BONE_SPACE_COMPONENT) end)
    local idx = 0
    pcall(function() idx = driver.gun:GetBoneIndex(fname(bone)) end)
    driver.native[bone] = { t = t, idx = idx or 0 }
end
local function driverSet(bone, t, scale)
    if driver == nil or driver.comp == nil then return end
    touchBone(bone)
    if scale == nil then scale = nativeScale(bone) end
    pcall(function() driver.comp:SetBoneTransformByName(fname(bone), ueTransform(t, scale), BONE_SPACE_COMPONENT) end)
    driver.dirty = true
end

-- The follower gun only redraws with the driver's bones on a forced leader update: per-frame bone writes on the driver
-- reach the gun's DATA (GetSocketTransform followed them) but not what it draws - the magazine stayed in the gun until
-- SetLeaderPoseComponent(driver, bForceUpdate) was called again over MCP, which drew it at the pose of that moment
-- (2026-11-23). So the leader pose is re-applied with a forced update after each frame's writes.
local function driverFlush()
    if driver == nil or driver.comp == nil or not driver.dirty then return end
    driver.dirty = false
    pcall(function() driver.gun:SetLeaderPoseComponent(driver.comp, true, true) end)
end

-- The game hides parts it is not showing with bone hidden flags (Jakobs Mag01 at idle: Mag01_SpeedLoader and
-- Mag01_SpeedLoader_Bullet01-04 sit beside the cylinder, hidden - measured 2026-11-23: HideBoneByName on them made
-- the floating speedloader seen after manual reloads disappear, and the flags read false on the reloaded gun).
-- A manual reload must leave those flags as it found them: they are recorded at the catch, the item and the bones riding
-- with it are unhidden for the reload (they are drawn), and every recorded bone is hidden again at the end.
local function hiddenBonesOf(mesh)
    local out = {}
    pcall(function()
        local n = mesh:GetNumBones()
        for i = 0, n - 1 do
            local f = mesh:GetBoneName(i)
            if mesh:IsBoneHiddenByName(f) then out[#out + 1] = f:to_string() end
        end
    end)
    return out
end
-- keep: bone name -> true for the item, its subtree and the bones riding with it
local function keepSetOf(mesh, item)
    local keep = {}
    local roots = { item.bone }
    for _, g in ipairs(item.group or {}) do roots[#roots + 1] = g.bone end
    pcall(function()
        local n = mesh:GetNumBones()
        for i = 0, n - 1 do
            local f = mesh:GetBoneName(i)
            local s = f:to_string()
            for _, r in ipairs(roots) do
                if s == r or mesh:BoneIsChildOf(f, fname(r)) then keep[s] = true break end
            end
        end
    end)
    return keep
end
local function unhideForReload(mesh, hidden, keep)
    for _, b in ipairs(hidden) do
        if keep[b] then pcall(function() mesh:UnHideBoneByName(fname(b)) end) end
    end
end
local function restoreHidden(mesh, hidden)
    for _, b in ipairs(hidden or {}) do pcall(function() mesh:HideBoneByName(fname(b), 0) end) end
end

local function createDriver(gun, item)
    local hidden = hiddenBonesOf(gun)
    local keep = keepSetOf(gun, item)
    local comp = uevrUtils.create_component_of_class("Class /Script/Engine.PoseableMeshComponent")
    if comp == nil then return nil end
    local ok, err = pcall(function()
        comp:SetVisibility(false, true)
        pcall(function() comp:SetCastShadow(false) end)
        pcall(function() comp:SetCollisionEnabled(0) end)
        comp:SetSkinnedAssetAndUpdate(gun.SkeletalMesh, false)
        comp:CopyPoseFromSkeletalComponent(gun)
        -- the driver sits on the gun (only its bone transforms matter, but a parented driver keeps its bounds near)
        comp:K2_AttachToComponent(gun, fname(""), 2, 2, 2, false)
        -- bFollowerShouldTickPose = true: the gun's own anim blueprint keeps running underneath (2026-11-23). With false it
        -- froze, so the game's reload animation never played to its end - not even the fast native reload at the finish -
        -- and the parts it moves away at the end (Jakobs Mag01: the speedloader rounds) stayed beside the gun for good.
        gun:SetLeaderPoseComponent(comp, true, true)
    end)
    if not ok then
        info("driver: " .. tostring(err))
        pcall(function() uevrUtils.destroyComponent(comp, true, false) end)
        return nil
    end
    local d = { comp = comp, gun = gun, hidden = hidden }
    -- the driver hides what the gun hides (in case the follower draws with the leader's flags), except the item
    for _, b in ipairs(hidden) do
        if not keep[b] then pcall(function() comp:HideBoneByName(fname(b), 0) end) end
    end
    unhideForReload(gun, hidden, keep)
    log(string.format("gun had %d hidden bones at the catch", #hidden))
    -- the magazine is drawn far from the gun (hip, hand): keep the gun's bounds big enough not to be culled
    pcall(function() d.boundsScale = gun.BoundsScale gun.BoundsScale = 6.0 end)
    log("driver on " .. tostring(gun:get_full_name()))
    return d
end

-- after (a finished reload): { bones = set, hidden = set } - the item, what rides with it and the ejected bones take the
-- hidden state the game leaves at the end of its own reload (Arbalest: the loaded bolt AnnG_ammo_02 shows, the spent
-- AnnG_ammo_01 stays hidden - both were otherwise put back as they were at the catch, with the bolt fired)
local function releaseDriver(after)
    local d = driver
    driver = nil
    if d == nil then return end
    if d.gun ~= nil and exists(d.gun) then
        -- every touched bone back to its catch-time pose (parent first), drawn once, then the gun is let go
        if d.native ~= nil and d.comp ~= nil then
            local list = {}
            for bone, n in pairs(d.native) do if n.t ~= nil then list[#list + 1] = { bone = bone, t = n.t, idx = n.idx } end end
            table.sort(list, function(a, b) return a.idx < b.idx end)
            for _, e in ipairs(list) do
                pcall(function() d.comp:SetBoneTransformByName(fname(e.bone), e.t, BONE_SPACE_COMPONENT) end)
            end
            pcall(function() d.gun:SetLeaderPoseComponent(d.comp, true, true) end)
        end
        pcall(function() d.gun:SetLeaderPoseComponent(nil, true, false) end)
        restoreHidden(d.gun, d.hidden)
        if after ~= nil then
            for b in pairs(after.bones) do if not after.hidden[b] then pcall(function() d.gun:UnHideBoneByName(fname(b)) end) end end
            for b in pairs(after.bones) do if after.hidden[b] then pcall(function() d.gun:HideBoneByName(fname(b), 0) end) end end
        end
        if d.boundsScale ~= nil then pcall(function() d.gun.BoundsScale = d.boundsScale end) end
    end
    if d.comp ~= nil then pcall(function() uevrUtils.destroyComponent(d.comp, true, false) end) end
end

-- -------------------------------------------------------------------------------------------------------------------
-- The magazine away from the gun (falling, at the hip, in the hand) is a COPY (OW2 bone isolation): a
-- PoseableMeshComponent with the gun's mesh and materials, its pose copied from the gun, every bone collapsed to
-- nothing at the item (root scaled 0.001 at the item's rest) except the item and the bones riding with it. Bones on the
-- real gun live in the gun's space and show a frame late against the controllers (BL4 2026-11-23: "the mag still moves
-- when I move the gun"); the copy is placed as a component instead: world transform while falling / at the hip,
-- attached to the visible left hand's hand_l while held. The insert stroke goes back to the real gun's bones.
-- -------------------------------------------------------------------------------------------------------------------
local tp = nil   -- { comp, item, rest, rootBone, rootQ, t0, shown, attachedTo }

local function tpIsolate(show)
    if tp == nil then return end
    local item = tp.item
    local rest = tp.rest
    pcall(function()
        local d = tp.comp
        -- everything collapses into the magazine's position; the magazine (and what rides with it) keeps its pose
        d:SetBoneTransformByName(fname(tp.rootBone), ueTransform({ loc = rest.loc, q = tp.rootQ }, HIDDEN_SCALE), BONE_SPACE_COMPONENT)
        d:SetBoneTransformByName(fname(item.bone), ueTransform(rest, 1), BONE_SPACE_COMPONENT)
        for _, g in ipairs(item.group or {}) do
            d:SetBoneTransformByName(fname(g.bone), ueTransform(compose(rest, fromProfile(g.rel)), 1), BONE_SPACE_COMPONENT)
        end
    end)
    if tp.shown ~= show then pcall(function() tp.comp:SetVisibility(show, false) end) end
    tp.shown = show
end

local function tpRelease()
    local t = tp
    tp = nil
    if t == nil then return end
    if t.comp ~= nil then pcall(function() uevrUtils.destroyComponent(t.comp, true, false) end) end
end

local function tpSetup(gun, profile)
    local t = { item = profile.item, rest = fromProfile(profile.item.rest), t0 = os.clock(), shown = true }
    local ok, err = pcall(function()
        local d = uevrUtils.create_component_of_class("Class /Script/Engine.PoseableMeshComponent")
        if d == nil then error("no poseable") end
        t.comp = d
        d:SetSkinnedAssetAndUpdate(gun.SkeletalMesh, false)
        pcall(function()
            local n = gun:GetNumMaterials()
            for i = 0, n - 1 do d:SetMaterial(i, gun:GetMaterial(i)) end
        end)
        pcall(function() d:SetCastShadow(false) end)
        pcall(function() d:SetCollisionEnabled(0) end)
        d:CopyPoseFromSkeletalComponent(gun)
        t.rootBone = gun:GetBoneName(0):to_string()
        t.rootQ = fromUE(gun:GetSocketTransform(fname(t.rootBone), RTS_COMPONENT)).q
    end)
    tp = t
    if not ok then
        info("magazine copy: " .. tostring(err))
        tpRelease()
        return false
    end
    tpIsolate(false)
    return true
end

-- the copy's component pose for an item pose (the item bone sits at its rest in component space)
local function tpCompFor(itemPose) return compose(itemPose, inv(tp.rest)) end

local function tpPlaceWorld(itemW)
    if tp == nil then return end
    pcall(function()
        if tp.attachedTo ~= false then
            tp.comp:K2_DetachFromComponent(1, 1, 1)
            tp.attachedTo = false
        end
        local c = tpCompFor(itemW)
        local r = q2r(c.q)
        tp.comp:K2_SetWorldLocationAndRotation(vec(c.loc.X, c.loc.Y, c.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, true)
    end)
    if not tp.shown then tpIsolate(true) end
end

-- itemRel: the item in the hand bone's frame
local function tpPlaceOnHand(mesh, itemRel)
    if tp == nil then return end
    pcall(function()
        if tp.attachedTo ~= mesh then
            tp.comp:K2_AttachToComponent(mesh, fname(HAND_BONE), 1, 1, 1, false)
            tp.attachedTo = mesh
        end
        setRelative(tp.comp, tpCompFor(itemRel))
    end)
    if not tp.shown then tpIsolate(true) end
end

local function tpHide()
    if tp ~= nil and tp.shown then tpIsolate(false) end
end

-- A poseable created this frame ignores bone writes until it has ticked (BL4 2026-11-23: the first isolation did not
-- take and the whole gun fell out at the eject): the isolation is re-applied every frame for the first 0.5 s and every
-- 0.25 s after that, and the drop uses the real gun's bones until TP_READY_S has passed.
local TP_READY_S = 0.08
local function tpReady(now) return tp ~= nil and now - tp.t0 >= TP_READY_S end
local function tpTick(now)
    if tp == nil then return end
    if now - tp.t0 < 0.5 or now >= (tp.nextApply or 0) then
        tp.nextApply = now + 0.25
        tpIsolate(tp.shown == true)
    end
end
-- -------------------------------------------------------------------------------------------------------------------
-- left hand finger pose (the game's, from the profile) - written after the hands lib's own animation, blended in and out
-- -------------------------------------------------------------------------------------------------------------------
local fingers = {}   -- { active, mesh, order, snapshot (local transforms), snapRel, lastRel, from, to, t0, out }

local function lockLeftInput(on) pcall(function() hands.setInputLocked(Handed.Left, on) end) end

local function restoreFingerLocals(f)
    if f.mesh == nil or f.snapshot == nil or not exists(f.mesh) then return end
    pcall(function()
        for _, b in ipairs(f.snapshot) do
            animation.setBoneSpaceLocalTransform(f.mesh, b.fname, kismet_math_library:MakeTransform(b.loc, b.rot, b.scale))
        end
    end)
end

local function releaseFingers()
    local f = fingers
    fingers = {}
    lockLeftInput(false)
    restoreFingerLocals(f)
end

local function toPose(pose)
    local out = {}
    for name, T in pairs(pose) do
        if isFingerBone(name) then out[name] = (T.loc ~= nil and T.q ~= nil) and fromProfile(T) or T end
    end
    return out
end

local function setFingerPose(pose, mirrored)
    local wantPose = pose ~= nil and not mirrored and configui.getValue("mr_fingers") ~= false
    if wantPose then
        fingers.active = true
        fingers.out = false
        fingers.to = toPose(pose)
        fingers.from = fingers.lastRel
        fingers.t0 = os.clock()
        lockLeftInput(true)
    elseif pose ~= nil then
        lockLeftInput(true)
    elseif fingers.active and not fingers.out then
        fingers.out = true
        fingers.from = fingers.lastRel
        fingers.to = fingers.snapRel
        fingers.t0 = os.clock()
    elseif not fingers.active then
        lockLeftInput(false)
    end
end

local function readRel(mesh, order, hand)
    local inv_ = inv(hand)
    local out = {}
    for _, b in ipairs(order) do
        out[b.name] = compose(inv_, fromUE(mesh:GetBoneTransformByName(b.f, BONE_SPACE_COMPONENT)))
    end
    return out
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    if not fingers.active then return end
    local ok, err = pcall(function()
        local mesh = leftHandMesh()
        if mesh == nil then return end
        local hand = fromUE(mesh:GetBoneTransformByName(fname(HAND_BONE), BONE_SPACE_COMPONENT))
        if fingers.mesh ~= mesh then
            local want = fingers.to or {}
            fingers.mesh, fingers.snapshot, fingers.order = mesh, {}, {}
            local n = mesh:GetNumBones()
            for i = 0, n - 1 do
                local f = mesh:GetBoneName(i)
                local s = f:to_string()
                if want[s] ~= nil then
                    fingers.order[#fingers.order + 1] = { name = s, f = f }
                    local rot, loc, scale = animation.getBoneSpaceLocalTransform(mesh, f)
                    if rot ~= nil then
                        fingers.snapshot[#fingers.snapshot + 1] = { fname = f, rot = uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll),
                            loc = vec(loc.X, loc.Y, loc.Z), scale = vec(scale.X, scale.Y, scale.Z) }
                    end
                end
            end
            log(string.format("finger pose: writing %d bones on %s", #fingers.order, mesh:get_full_name()))
            fingers.snapRel = readRel(mesh, fingers.order, hand)
            fingers.lastRel = nil
            if fingers.out then fingers.to = fingers.snapRel end
            fingers.from = nil
        end
        if fingers.from == nil then fingers.from = fingers.lastRel or readRel(mesh, fingers.order, hand) end
        local T = cfgNum("mr_finger_blend", 0.2)
        local a = T > 0 and math.min(1.0, (os.clock() - fingers.t0) / T) or 1.0
        local e = smooth(a)
        local last = {}
        for _, b in ipairs(fingers.order) do
            local to = fingers.to[b.name]
            local from = fingers.from[b.name] or to
            if to ~= nil then
                local rel = lerpT(from, to, e)
                last[b.name] = rel
                mesh:SetBoneTransformByName(b.f, ueTransform(compose(hand, rel)), BONE_SPACE_COMPONENT)
            end
        end
        fingers.lastRel = last
        if fingers.out and a >= 1.0 then releaseFingers() end
    end)
    if not ok then info("finger pose: " .. tostring(err)) releaseFingers() end
end)

-- -------------------------------------------------------------------------------------------------------------------
-- state
-- -------------------------------------------------------------------------------------------------------------------
local S_FEED = "feeding"   -- (unused in Cronos: a shell is added at once on the seat)
local S_IDLE, S_AWAIT, S_HOLD, S_INSERT, S_CLOSE, S_AWAIT_RACK, S_RACK, S_FINISH =
    "idle", "await_mag", "holding", "inserting", "closing", "await_rack", "racking", "finishing"
local state = S_IDLE
local cur = {}            -- the reload in progress
local noInterceptUntil = 0
local gripDown, gripPressed, gripReleased, swallowGrip = false, false, false, false
local gripOwned, gripQuietUntil = false, 0   -- a grip press the manual reload took, hidden until released (+ quiet time)
local GRIP_QUIET_S = 0.3
local nearPouch, nearRack = false, false
local pressLocked = false
local lastReloading = false

local function enter(s)
    if s ~= state then log("state " .. state .. " -> " .. s) end
    state = s
    _G.cronosManualReloadBusy = (s ~= S_IDLE)
end

local function loadedOf(ammo)
    local n = nil
    pcall(function() n = ammo:GetAmmoInMagazine() end)
    return n
end
local function reserveOf(ammo)
    local n = nil
    pcall(function() n = ammo:GetAmmoCount() end)
    return n
end
local function capacityOf(ammo)
    local n = nil
    pcall(function() n = ammo:GetMagazineSize() end)
    return n
end

-- The game's reload montages (the hidden body's + the gun's own): stopped when a manual reload catches the reload,
-- and again whenever the player asks for another reload while it runs. Nothing has moved the ammo yet then
-- (ReloadAddAmmo is a notify near the end of the body montage).
local function stopNativeReload(why)
    local a = _G.cronosReloadAnalyzer
    if a == nil then return false end
    local stopped = false
    pcall(function()
        local m = a.reloadMontage()
        local c = a.context()
        if m ~= nil and c ~= nil then
            c.body:GetAnimInstance():Montage_Stop(0.1, m)
            stopped = true
        end
    end)
    pcall(function()
        local c = a.context()
        local ai = c.wmesh:GetAnimInstance()
        local gm = ai:GetCurrentActiveMontage()
        if gm ~= nil then ai:Montage_Stop(0.05, gm) end
    end)
    if stopped then log("native reload stopped (" .. tostring(why) .. ")") end
    return stopped
end

local rackHandRelease = nil

-- -------------------------------------------------------------------------------------------------------------------
-- well dot (2026-11-24): a glowing sphere at the learned seat while a magazine / round is at the hip or in the hand, so
-- the player sees where it goes on every gun. The well is empty then (the magazine is out), so it is a marker, not a
-- highlight: the gun is one gestalt mesh with ONE body material for every part (MCP: 3 sections body / scope / glass),
-- and the game's PP_HighlightStencil needs r.PostProcessing.DisableMaterials 0 (user_script.txt sets 1) and did not
-- show on the gun even then. Engine sphere (100 cm) + Widget3DPassThrough (unlit, translucent: TintColorAndOpacity
-- alpha = opacity). Attached to the first-person gun at seat + per-gun offset, so it
-- moves with the gun. Size / offset per gun in data/cronos_manual_reload_tune.json (ms, ml).
-- -------------------------------------------------------------------------------------------------------------------
local MARKER_MESH = "StaticMesh /Engine/BasicShapes/Sphere.Sphere"
local MARKER_MESHES = { [1] = MARKER_MESH, [2] = "StaticMesh /Engine/BasicShapes/Cube.Cube" }   -- per gun: tune mk (2 = cube)
local markerMeshObj = {}
local MARKER_MATERIAL = "Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough"
local MARKER_TEXTURE = "Texture2D /Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local marker = nil   -- { comp, mid, parent, tint, loc, size, shown }

local function markerColor()
    local v = configui.getValue("mr_marker_color") or "#1CF400FF"
    local hex = type(v) == "string" and v or uevrUtils.intToHexString(v)
    local r = (tonumber(string.sub(hex, 2, 3), 16) or 51) / 255
    local g = (tonumber(string.sub(hex, 4, 5), 16) or 255) / 255
    local b = (tonumber(string.sub(hex, 6, 7), 16) or 102) / 255
    return r, g, b
end

local function markerDestroy()
    if marker ~= nil and marker.comp ~= nil then pcall(function() uevrUtils.destroyComponent(marker.comp, true, false) end) end
    marker = nil
end

-- Hidden = detached from the gun too: hands.lua / two_handed_integration.lua force the gun mesh visible every frame
-- with SetVisibility(true, true) / SetHiddenInGame(false, true), which propagates to its children - a marker left on
-- the gun showed all the time after the first reload (2026-11-26). markerShow re-attaches it.
local function markerHide()
    if marker == nil or not marker.shown then return end
    marker.shown = false
    if exists(marker.comp) then
        pcall(function() marker.comp:K2_DetachFromComponent(1, 1, 1) end)
        pcall(function() marker.comp:SetVisibility(false, false) end)
    end
    marker.parent, marker.loc, marker.size = nil, nil, nil
end

local function markerEnsure()
    if marker ~= nil and exists(marker.comp) then return marker end
    marker = nil
    local comp = uevrUtils.createStaticMeshComponent(MARKER_MESH, { visible = false, collisionEnabled = false })
    if comp == nil then return nil end
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetGenerateOverlapEvents(false) end)
    local mid = nil
    pcall(function()
        local template = uevrUtils.getSafeInstanceOf("Class /Script/Engine.Material", MARKER_MATERIAL)
        if template == nil then return end
        mid = comp:CreateDynamicMaterialInstance(0, template, fname("cronos_mr_marker"))
        local white = uevrUtils.getSafeInstanceOf("Class /Script/Engine.Texture2D", MARKER_TEXTURE)
        if mid ~= nil and white ~= nil then mid:SetTextureParameterValue(fname("SlateUI"), white) end
    end)
    marker = { comp = comp, mid = mid, shown = false, shape = 1 }
    return marker
end

local function markerShow(gun, seat)
    local m = markerEnsure()
    if m == nil then return end
    local c = m.comp
    if m.parent ~= gun then
        pcall(function() c:K2_AttachToComponent(gun, fname(""), 0, 0, 0, false) end)
        m.parent, m.loc, m.size = gun, nil, nil
    end
    local ox, oy, oz = tuneVec("ml")
    local loc = addV(seat.loc, { X = ox, Y = oy, Z = oz })
    if m.loc == nil or lenV(subV(loc, m.loc)) > 1e-3 then
        pcall(function() c:K2_SetRelativeLocationAndRotation(vec(loc.X, loc.Y, loc.Z), uevrUtils.rotator(0, 0, 0), false, reusable_hit_result, true) end)
        m.loc = loc
    end
    local t = tuneKey ~= nil and tune[tuneKey] or nil
    local shape = (t ~= nil and t.mk == 2) and 2 or 1
    if shape ~= m.shape then
        local mesh = markerMeshObj[shape]
        if mesh == nil then
            mesh = uevrUtils.getSafeInstanceOf("Class /Script/Engine.StaticMesh", MARKER_MESHES[shape])
            markerMeshObj[shape] = mesh
        end
        if mesh ~= nil then
            pcall(function() c:SetStaticMesh(mesh) end)
            if m.mid ~= nil then pcall(function() c:SetMaterial(0, m.mid) end) end
        end
        m.shape = shape
    end
    local size = (t ~= nil and type(t.ms) == "number" and t.ms > 0) and t.ms or cfgNum("mr_marker_size", 7.0)
    if size ~= m.size then
        local s = size / 100.0
        pcall(function() c:SetRelativeScale3D(vec(s, s, s)) end)
        m.size = size
    end
    if m.mid ~= nil then
        local r, g, b = markerColor()
        local k = cfgNum("mr_marker_brightness", 5.0)
        local a = cfgNum("mr_marker_opacity", 0.54)
        local tint = string.format("%.3f %.3f %.3f %.3f %.3f", r, g, b, k, a)
        if tint ~= m.tint then
            pcall(function() m.mid:SetVectorParameterValue(fname("TintColorAndOpacity"), uevrUtils.color_from_rgba(r * k, g * k, b * k, a)) end)
            m.tint = tint
        end
    end
    if not m.shown then
        m.shown = true
        pcall(function() c:SetVisibility(true, false) end)
    end
end

-- per frame: the dot shows while a magazine waits at the hip or is in the hand, and goes as it is pushed in
local function markerTick()
    local want = configui.getValue("mr_marker") ~= false and (state == S_AWAIT or state == S_HOLD)
        and cur.seat ~= nil and cur.gun ~= nil and exists(cur.gun)
    if want then markerShow(cur.gun, cur.seat) else markerHide() end
end

local function cleanup(reason)
    if reason ~= "done" then info("released (" .. tostring(reason) .. ") in state " .. state) end
    markerHide()
    if rackHandRelease ~= nil then pcall(rackHandRelease, os.clock()) end
    tpRelease()
    local after = nil
    if reason == "done" and cur.profile ~= nil and cur.gun ~= nil and cur.profile.hiddenAfter ~= nil then
        pcall(function()
            local bones = keepSetOf(cur.gun, cur.profile.item)
            for _, b in ipairs(cur.profile.ejected or {}) do
                for n in pairs(keepSetOf(cur.gun, { bone = b })) do bones[n] = true end
            end
            local hidden = {}
            for _, n in ipairs(cur.profile.hiddenAfter) do hidden[n] = true end
            after = { bones = bones, hidden = hidden }
        end)
    end
    releaseDriver(after)
    setFingerPose(nil)
    cur = {}
    swallowGrip = false
    noInterceptUntil = os.clock() + 0.5
    enter(S_IDLE)
end

-- the left hand pose for this profile (mirrored for a right-hand gun)
local function profileGrip(profile, F)
    local g = fromProfile(profile.item.grip)
    if g == nil then return nil end
    if profile.mirror then
        -- mirrored across the gun's centre plane through the item's pose WHILE HELD (gripPose), else its rest
        local ref = fromProfile(profile.item.gripPose) or fromProfile(profile.item.rest)
        if not F then return mirrorT(g) end
        local H = compose(ref, g)
        g = compose(inv(ref), mirrorHandInGun(H, ref.loc.X, F))
    end
    return g
end

local function leftFingers(pose, profile)
    if not profile.mirror then return pose end
    return mirrorFingers(pose, mirrorF)
end

local function supported(profile)
    if profile == nil or profile.item == nil or profile.item.grip == nil then return false, "not learned yet" end
    if profile.item.rest == nil then return false, "not learned yet" end
    if profile.style ~= "item" and profile.style ~= "rounds" then return false, "style " .. tostring(profile.style) .. " not supported yet" end
    return true
end

-- Prediction (2026-11-23, "the magazine fights the gun's movement"): the magazine is a bone in the GUN's space, so a
-- pose computed from this frame's gun and hand shows a frame late against the controllers - every gun or hand motion
-- shifts it. Both the gun and the target (hand / hip) are extrapolated mr_predict frames ahead from their last frame's
-- motion, and the gun-space pose is taken between the two predictions.
local pred = {}   -- key -> previous world transform
local function scaleDelta(d, k)
    local w = math.max(-1, math.min(1, d.q.W))
    local sgn = w < 0 and -1 or 1
    local q = { X = d.q.X * sgn, Y = d.q.Y * sgn, Z = d.q.Z * sgn, W = d.q.W * sgn }
    local ang = 2 * math.acos(math.min(1, q.W))
    local sn = math.sin(ang / 2)
    local qk = IDENT.q
    if sn > 1e-6 then
        local h = ang * k / 2
        local s = math.sin(h) / sn
        qk = { X = q.X * s, Y = q.Y * s, Z = q.Z * s, W = math.cos(h) }
    end
    return { loc = mulV(d.loc, k), q = qk }
end
local function predicted(key, w)
    local k = cfgNum("mr_predict", 1.0)
    local prev = pred[key]
    pred[key] = w
    if prev == nil or k <= 0 then return w end
    local d = compose(inv(prev), w)          -- last frame's motion in the body's own frame
    if lenV(d.loc) > 30 then return w end    -- a jump (teleport, re-grab): no extrapolation
    return compose(w, scaleDelta(d, k))
end
-- cur.gunPW: the gun's predicted world pose, taken once per frame (tickBody)
local function gunSpaceOf(targetW, key)
    local gunW = cur.gunPW or worldOf(cur.gun)
    return compose(inv(gunW), key and predicted(key, targetW) or targetW)
end

-- the item (and the bones that ride with it) at gun-space pose T; hidden = shrunk to nothing
local function setItem(T, hidden)
    local item = cur.profile.item
    local s = hidden and HIDDEN_SCALE or 1
    driverSet(item.bone, T, s)
    for _, g in ipairs(item.group or {}) do driverSet(g.bone, compose(T, fromProfile(g.rel)), s) end
    cur.itemT = T
end

-- -------------------------------------------------------------------------------------------------------------------
-- reload start: cancel the native reload, put the gun on the driver, drop the magazine
-- -------------------------------------------------------------------------------------------------------------------
local function rackRelative(rk, pull)
    if not rk.rot then return { loc = mulV(rk.axis, pull), q = IDENT.q } end
    local h = math.rad(pull) * 0.5
    local sn = math.sin(h)
    local qd = { X = rk.axis.X * sn, Y = rk.axis.Y * sn, Z = rk.axis.Z * sn, W = math.cos(h) }
    local P = rk.rest.loc
    return { loc = subV(P, qrot(qd, P)), q = qd }
end
-- bolt path (Jakobs sniper): u in [0, travel] = the hand's pull; the first 30% lifts the handle, the rest slides it back
local BOLT_LIFT_SHARE = 0.3
local function boltPose(rk, u)
    local liftLen = rk.travel * BOLT_LIFT_SHARE
    if u <= liftLen then return lerpT(rk.rest, rk.lift, liftLen > 0 and u / liftLen or 1) end
    return lerpT(rk.lift, rk.open, (u - liftLen) / math.max(1e-3, rk.travel - liftLen))
end
local function rackBonePose(rk, pull)
    if rk.boltPath then return boltPose(rk, pull) end
    return compose(rackRelative(rk, pull), rk.rest)
end
local function setSlidePull(pull)
    local rk = cur.rack
    if rk == nil then return end
    driverSet(rk.bone, rackBonePose(rk, pull))
end

local function tryIntercept(ctx, profile)
    if os.clock() < noInterceptUntil then return end
    local gun = ctx.wmesh
    local clip = loadedOf(ctx.ammo)
    local wasEmpty = clip == 0
    local a = _G.cronosReloadAnalyzer
    if a ~= nil and ((a.wantsReload ~= nil and a.wantsReload()) or a.isRecording()) then
        noInterceptUntil = os.clock() + 2.0
        log("the analyzer wants this reload - native")
        return
    end
    -- (round-by-round guns load the same way from empty; a mode without its own empty reload has one recording)
    if wasEmpty and profile.style ~= "rounds" and profile.hasEmptyReload and (profile.recorded == nil or profile.recorded.empty == nil) then
        noInterceptUntil = os.clock() + 2.0
        log("empty reload not learned yet - native")
        return
    end
    if (reserveOf(ctx.ammo) or 1) <= 0 then
        noInterceptUntil = os.clock() + 1.0
        log("no reserve ammo - native")
        return
    end
    -- 1. stop the game's reload (no ammo has moved yet)
    if not stopNativeReload("caught") then info("could not stop the native reload - native") return end
    -- 2. the real gun follows the driver from now on
    local d = createDriver(gun, profile.item)
    if d == nil then return end
    driver = d
    cur = { pawn = ctx.pawn, ctx = ctx, gun = gun, profile = profile, ammo = ctx.ammo, key = ctx.key,
            wasEmpty = wasEmpty, clipBefore = clip, rest = fromProfile(profile.item.rest) }
    pred = {}
    cur.useTP = tpSetup(gun, profile)
    log("magazine renderer: " .. (cur.useTP and "isolated copy" or "gun bones"))
    -- the old magazine (a separate bone from the new one, handgun GG_cartridge): hidden until the reload is over
    for _, b in ipairs(profile.ejected or {}) do
        pcall(function() driverSet(b, fromUE(driver.comp:GetBoneTransformByName(fname(b), BONE_SPACE_COMPONENT)), HIDDEN_SCALE) end)
    end
    -- the mirror axes are needed for a right-hand item AND for a right-hand rack
    if profile.mirror or (profile.rack ~= nil and profile.rack.hand == "right") then computeMirrorF(ctx.body) end
    cur.grip = profileGrip(profile, mirrorF)
    cur.seat0 = fromProfile(profile.item.seat) or cur.rest
    cur.approach0 = fromProfile(profile.item.approach) or cur.rest
    cur.seat, cur.approachT = tunedSeat(cur.seat0, cur.approach0)
    info(string.format("reload caught (%s, clip %s, reserve %s): %s", wasEmpty and "empty" or "tactical", tostring(clip),
        tostring(reserveOf(ctx.ammo)), tostring(profile.name)))

    -- the magazine drops out along the insert stroke (docked items stay: nothing to drop)
    setItem(cur.rest, false)
    cur.loaded = 0
    -- (a single-shot round was fired: nothing to drop)
    if not profile.item.docked and not profile.item.noDrop and profile.style ~= "rounds" then
        local gunW = worldOf(gun)
        -- an item riding a swing-out part leaves from where that part holds it open
        local w = compose(gunW, profile.item.opener ~= nil and cur.seat or cur.rest)
        local axis = profile.item.axis or { X = 0, Y = 0, Z = 1 }
        local outWorld = qrot(gunW.q, mulV(axis, -1))
        cur.drop = { pos = w.loc, q = w.q, vel = addV(mulV(outWorld, 35.0), { X = 0, Y = 0, Z = -40.0 }), t0 = os.clock() }
    else
        setItem(cur.rest, true)
    end
    -- hinges / gates the game opens for the reload (opener mechanisms): opened on the driver, closed at the end
    cur.openers = {}
    for _, m in ipairs(profile.mechanisms or {}) do
        if m.opener and m.openPose ~= nil and m.rest ~= nil then
            local o = { bone = m.bone, rest = fromProfile(m.rest), open = fromProfile(m.openPose), carries = m.carriesItem == true }
            if o.carries and profile.item.seat ~= nil then
                -- closing direction (gun space): the item's travel from where the open part holds it back to its rest
                local d = subV(cur.rest.loc, fromProfile(profile.item.seat).loc)
                local l = lenV(d)
                if l > 0.5 then o.closeDir = mulV(d, 1 / l) end
            end
            cur.openers[#cur.openers + 1] = o
        end
    end
    -- an item riding a swing-out part: the gun opens into the game's whole pose at the seat (every moved bone,
    -- parent-first), the part that carries the item keeps the flick-to-close direction
    if profile.item.openFrame ~= nil then
        local carrier = nil
        for _, o in ipairs(cur.openers) do if o.carries and o.closeDir ~= nil then carrier = o break end end
        cur.openers = {}
        for _, e in ipairs(profile.item.openFrame) do
            local o = { bone = e.bone, rest = fromProfile(e.rest), open = fromProfile(e.open) }
            if carrier ~= nil and e.bone == carrier.bone then o.carries, o.closeDir = true, carrier.closeDir end
            cur.openers[#cur.openers + 1] = o
        end
        if carrier ~= nil then
            local has = false
            for _, o in ipairs(cur.openers) do if o.carries then has = true end end
            if not has then cur.openers[#cur.openers + 1] = carrier end
        end
    end
    if #cur.openers > 0 then cur.openAnim = { t0 = os.clock(), from = 0, to = 1, dur = 0.2 } end
    haptic(0.04, 0.4)
    -- a rack part (empty reloads, or every reload when learned from the only reload): slides and rotary handles
    local rk = profile.rack
    if rk ~= nil and rk.bolt == nil and not rk.crank and (wasEmpty or rk.every) and configui.getValue("mr_rack") ~= false and rk.rest ~= nil then
        local lock = rk.lockedBack and ((rk.rot and rk.lockedDeg or rk.lockedCm) or 0) or 0
        cur.rack = { bone = rk.bone, pull = lock, lock = lock, travel = rk.travel or 5, axis = rk.axis, rest = fromProfile(rk.rest),
                     rot = rk.rot == true }
        if rk.boltPath and rk.liftPose ~= nil and rk.openPose ~= nil then
            -- the hand's pull covers the lift too: path length = slide travel / (1 - lift share)
            cur.rack.boltPath, cur.rack.lift, cur.rack.open = true, fromProfile(rk.liftPose), fromProfile(rk.openPose)
            cur.rack.travel = (rk.travel or 5) / (1 - BOLT_LIFT_SHARE)
            cur.rack.pull, cur.rack.lock = 0, 0
        end
        setSlidePull(lock)
    end
    enter(S_AWAIT)
end

-- -------------------------------------------------------------------------------------------------------------------
-- pouch at the left hip (the magazine shows there once the old one has dropped)
-- -------------------------------------------------------------------------------------------------------------------
local function pouchItemWorld(profile)
    local head = controllers.getControllerLocation(2)
    local hr = controllers.getControllerRotation(2)
    if head == nil or hr == nil then return nil end
    local yaw = math.rad(hr.Yaw or 0)
    local fx, fy, fz = cfgVec("mr_pouch_loc", { 8.0, -24.0, -58.0 })
    local f = { X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }
    local r = { X = -math.sin(yaw), Y = math.cos(yaw), Z = 0 }
    local point = { X = head.X + f.X * fx + r.X * fy, Y = head.Y + f.Y * fx + r.Y * fy, Z = head.Z + fz }
    local yq = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) }
    return { loc = point, q = qmul(yq, fromProfile(profile.item.rest).q) }
end

local function updateDropAndPouch(now, dt)
    if cur.drop ~= nil then
        local d = cur.drop
        d.vel = { X = d.vel.X, Y = d.vel.Y, Z = d.vel.Z - 980.0 * dt }
        d.pos = addV(d.pos, mulV(d.vel, dt))
        if now - d.t0 >= DROP_TIME_S then
            cur.drop = nil
            pred.pouch = nil
        elseif cur.useTP and tpReady(now) then
            setItem(cur.rest, true)
            tpPlaceWorld({ loc = d.pos, q = d.q })
            return
        else
            -- the fall is integrated: its next position is known (one step on), only the gun is predicted
            local k = cfgNum("mr_predict", 1.0)
            setItem(gunSpaceOf({ loc = addV(d.pos, mulV(d.vel, dt * k)), q = d.q }, nil), false)
            return
        end
    end
    local w = pouchItemWorld(cur.profile)
    if w == nil then setItem(cur.rest, true) return end
    cur.pouchW = w
    if cur.useTP then
        setItem(cur.rest, true)
        tpPlaceWorld(w)
    else
        setItem(gunSpaceOf(w, "pouch"), false)
    end
    local hand = controllers.getControllerLocation(Handed.Left)
    local was = nearPouch
    nearPouch = hand ~= nil and lenV(subV({ X = hand.X, Y = hand.Y, Z = hand.Z }, w.loc)) <= cfgNum("mr_grab_radius", 13.0)
    if nearPouch and not was then haptic(0.02, 0.25) end
end

-- -------------------------------------------------------------------------------------------------------------------
-- magazine in the hand: item world = hand bone (visible hand) * inverse(grip)
-- -------------------------------------------------------------------------------------------------------------------
local function handBoneWorld()
    local mesh = leftHandMesh()
    if mesh == nil then return nil end
    local t = nil
    pcall(function() t = fromUE(mesh:GetSocketTransform(fname(HAND_BONE), RTS_WORLD)) end)
    return t
end

local function grabFromPouch()
    local hand = handBoneWorld()
    if hand == nil or cur.pouchW == nil then return false end
    cur.held = { glideT0 = os.clock(), from = compose(inv(hand), cur.pouchW) } -- item in the hand frame at the grab
    setFingerPose(leftFingers(cur.profile.fingers, cur.profile), false)
    haptic(0.03, 0.5)
    nearPouch = false
    enter(S_HOLD)
    log("magazine taken from the pouch")
    return true
end

local function updateHeld()
    local hand = handBoneWorld()
    if hand == nil or cur.grip == nil then return false end
    local target = tunedHold(inv(cur.grip))
    local rel = target
    local T = cfgNum("mr_grab_glide", 0.10)
    if cur.held.from ~= nil and T > 0 then
        local a = math.min(1.0, (os.clock() - cur.held.glideT0) / T)
        rel = lerpT(cur.held.from, target, smooth(a))
        if a >= 1.0 then cur.held.from = nil end
    end
    local itemW = compose(hand, rel)
    cur.heldW = itemW
    if cur.useTP then
        local mesh = leftHandMesh()
        if mesh == nil then return false end
        if cur.itemShownOnGun ~= false then setItem(cur.rest, true) cur.itemShownOnGun = false end
        tpPlaceOnHand(mesh, rel)
    else
        setItem(gunSpaceOf(itemW, "held"), false)
    end
    return true
end

local function dropHeld()
    setFingerPose(nil)
    local w = cur.heldW
    cur.held = nil
    if w ~= nil then cur.drop = { pos = w.loc, q = w.q, vel = { X = 0, Y = 0, Z = -50 }, t0 = os.clock() } end
    log("magazine let go - dropped")
end

-- distance of the held magazine to the learned insert path (approach -> seat segment), world cm
local function wellDistance()
    if cur.heldW == nil then return 1e9 end
    local gunW = worldOf(cur.gun)
    local a = compose(gunW, cur.approachT).loc
    local b = compose(gunW, cur.seat).loc
    local ab = subV(b, a)
    local L2 = dotV(ab, ab)
    local t = L2 > 1e-6 and math.max(0, math.min(1, dotV(subV(cur.heldW.loc, a), ab) / L2)) or 0
    return lenV(subV(cur.heldW.loc, addV(a, mulV(ab, t))))
end

-- insert glide: onto the learned approach pose, then along the stroke into the seat (gun space)
local INSERT_ALIGN_FRACTION = 0.5
local function startInsert()
    cur.held = nil
    setFingerPose(nil)
    local from = cur.itemT or cur.approachT
    if cur.useTP and cur.heldW ~= nil then
        -- the magazine goes back onto the first-person gun's bones for the stroke (it is gun-relative from here on)
        from = compose(inv(worldOf(cur.gun)), cur.heldW)
        tpHide()
        setItem(from, false)
        cur.itemShownOnGun = true
    end
    cur.insert = { t0 = os.clock(), from = from }
    enter(S_INSERT)
    log("insert glide")
end

local function updateInsert()
    local ins = cur.insert
    local T = cfgNum("mr_insert_time", 0.15)
    local a = math.min(1.0, (os.clock() - ins.t0) / T)
    local pose
    if a < INSERT_ALIGN_FRACTION then
        local t = a / INSERT_ALIGN_FRACTION
        pose = lerpT(ins.from, cur.approachT, 1 - (1 - t) * (1 - t))
    else
        local t = (a - INSERT_ALIGN_FRACTION) / (1 - INSERT_ALIGN_FRACTION)
        pose = lerpT(cur.approachT, cur.seat, t * t)
    end
    if a >= 1.0 then pose = cur.seat end
    setItem(pose, false)
    return a >= 1.0
end

-- -------------------------------------------------------------------------------------------------------------------
-- left hand on the rack part: the visible hand rides the rack bone (Hands: the glove on the gun at that bone; IK: the
-- accessory channel), glides back on release
-- -------------------------------------------------------------------------------------------------------------------
local rackHand = nil

local function ikHandsMode() return _G.cronosIsIKMode ~= nil and _G.cronosIsIKMode() == true end

local function attachRackHand(now, parentComp, socket)
    rackHand = nil
    local ok, err = pcall(function()
        local ctrl = controllers.getController(Handed.Left, true)
        if ctrl == nil or parentComp == nil then return end
        local rh = { ik = ikHandsMode(), parent = parentComp }
        if rh.ik then
            local parentW = worldOf(parentComp)
            if socket ~= nil then parentW = fromUE(parentComp:GetSocketTransform(fname(socket), RTS_WORLD)) end
            local rel = compose(inv(parentW), worldOf(ctrl))
            local r = q2r(rel.q)
            uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, parentComp, socket or "", 0, rel.loc, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll })
            rh.attached = true
        else
            local glove = hands ~= nil and hands.getHandComponent(Handed.Left) or nil
            if glove == nil or not exists(glove) then return end
            local parent = glove.AttachParent
            local gs = "None"
            pcall(function() gs = glove.AttachSocketName:to_string() end)
            rh.glove = glove
            rh.snap = { parent = parent, socket = gs ~= "None" and gs or "",
                        rel = parent ~= nil and compose(inv(worldOf(parent)), worldOf(glove)) or nil }
            glove:K2_AttachToComponent(parentComp, fname(socket or ""), 1, 1, 1, false)
        end
        rackHand = rh
    end)
    if not ok then info("rack hand attach: " .. tostring(err)) rackHand = nil end
end

local function releaseRackHand(now)
    local rh = rackHand
    if rh == nil or rh.returning then return end
    if rh.ik then
        rackHand = nil
        if rh.attached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
        return
    end
    local ok = pcall(function()
        if not exists(rh.glove) then error("glove gone") end
        if rh.snap.parent ~= nil and exists(rh.snap.parent) then
            rh.glove:K2_AttachToComponent(rh.snap.parent, fname(rh.snap.socket), 1, 1, 1, false)
            rh.glide = { t0 = now, dur = 0.15, from = compose(inv(worldOf(rh.snap.parent)), worldOf(rh.glove)) }
            rh.returning = true
        else
            controllers.attachComponentToController(Handed.Left, rh.glove)
            rackHand = nil
        end
    end)
    if not ok then rackHand = nil end
end

local function tickRackHand(now)
    local rh = rackHand
    if rh == nil or not rh.returning then return end
    local ok = pcall(function()
        if not exists(rh.glove) then error("glove gone") end
        local g = rh.glide
        local a = g.dur > 0 and math.min(1.0, (now - g.t0) / g.dur) or 1.0
        setRelative(rh.glove, lerpT(g.from, rh.snap.rel, 1 - (1 - a) ^ 3))
        if a >= 1.0 then rackHand = nil end
    end)
    if not ok then rackHand = nil end
end
rackHandRelease = releaseRackHand

-- -------------------------------------------------------------------------------------------------------------------
-- finish: the game's own ReloadAddAmmo fills the magazine from the reserve (MCP 2026-11-26: SmartGun 10 -> 15, reserve
-- 12 -> 7), then the gun comes off the driver
-- -------------------------------------------------------------------------------------------------------------------
local function startFinish()
    local before = loadedOf(cur.ammo)
    local ok, err = pcall(function() cur.ammo:ReloadAddAmmo() end)
    if not ok then info("ReloadAddAmmo: " .. tostring(err)) end
    cur.finish = { t0 = os.clock(), before = before }
    enter(S_FINISH)
    log("ammo added")
end

local function updateFinish(now)
    local f = cur.finish
    -- two more frames on the driver: the gun's own pose takes over cleanly
    if now - f.t0 >= 0.05 then
        info(string.format("reload done: clip %s -> %s (reserve %s)", tostring(cur.clipBefore), tostring(loadedOf(cur.ammo)), tostring(reserveOf(cur.ammo))))
        haptic(0.02, 0.3)
        cleanup("done")
    end
end

-- -------------------------------------------------------------------------------------------------------------------
-- round by round (shells): each seated round = one ReloadAddAmmo (ReloadAmmoAddedPerNotify rounds, the shotguns' 1).
-- Full / no reserve = done.
-- -------------------------------------------------------------------------------------------------------------------
local function startFeed()
    local before = loadedOf(cur.ammo) or 0
    pcall(function() cur.ammo:ReloadAddAmmo() end)
    local clip = loadedOf(cur.ammo) or before
    setItem(cur.rest, true)
    cur.loaded = (cur.loaded or 0) + math.max(0, clip - before)
    local cap, spare = capacityOf(cur.ammo), reserveOf(cur.ammo)
    log(string.format("round in: clip %d (%d loaded, reserve %s)", clip, cur.loaded, tostring(spare)))
    if clip <= before then
        cleanup("feed: no round landed")
    elseif (cap ~= nil and clip >= cap) or (spare ~= nil and spare <= 0) then
        info(string.format("reload done: clip %s -> %d (%d round(s))", tostring(cur.clipBefore), clip, cur.loaded))
        haptic(0.02, 0.3)
        cleanup("done")
    else
        cur.held, cur.insert, cur.heldW, cur.itemShownOnGun = nil, nil, nil, nil
        enter(S_AWAIT)
    end
end

-- -------------------------------------------------------------------------------------------------------------------
-- rack: the part follows the left hand along the learned axis; let go past mr_rack_done = racked
-- -------------------------------------------------------------------------------------------------------------------
local function rotaryPull(rk, hand)
    local ax = rk.axisW
    local function flat(v) return subV(v, mulV(ax, dotV(v, ax))) end
    local function cross(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end
    local gunW = worldOf(cur.gun)
    local pivot = compose(gunW, rk.rest).loc
    local v0 = flat(subV(rk.handStart, rk.pivotW))
    local v = flat(subV(hand, pivot))
    local r0 = lenV(v0)
    if r0 >= 4 and lenV(v) >= 4 then
        return math.deg(math.atan(dotV(ax, cross(v0, v)), dotV(v0, v)))
    end
    local n = r0 > 1e-3 and mulV(v0, 1 / r0) or nil
    if n == nil then return 0 end
    return math.deg(dotV(subV(hand, rk.handStart), cross(ax, n)) / 4)
end

local function rackGrabWorld()
    local rk, prof = cur.rack, cur.profile.rack
    local gunW = worldOf(cur.gun)
    local bone = rackBonePose(rk, rk.pull)
    local partW = compose(gunW, bone).loc
    local handW = (prof.grip ~= nil and prof.hand ~= "right") and compose(gunW, compose(bone, fromProfile(prof.grip))).loc or nil
    return partW, handW
end

local function updateRack(now, pressed, released)
    local rk = cur.rack
    if rk == nil then startFinish() return end
    if rk.spring ~= nil then
        local a = math.min(1.0, (now - rk.spring.t0) / 0.05)
        rk.pull = rk.spring.from + (rk.spring.to - rk.spring.from) * a * a
        setSlidePull(rk.pull)
        if a >= 1.0 then
            local done = rk.spring.armed
            rk.spring = nil
            if done then haptic(0.05, 0.9) log("racked") startFinish() end
        end
        return
    end
    local handC = controllers.getControllerLocation(Handed.Left)
    local hand = handC and { X = handC.X, Y = handC.Y, Z = handC.Z } or nil
    local partW, handW = rackGrabWorld()
    local was = nearRack
    local radius = cfgNum("mr_rack_radius", 10.0)
    local handBone = handW ~= nil and handBoneWorld() or nil
    nearRack = (hand ~= nil and lenV(subV(hand, partW)) <= radius) or
               (handBone ~= nil and lenV(subV(handBone.loc, handW)) <= radius)
    if nearRack and not was and state == S_AWAIT_RACK then haptic(0.02, 0.25) end
    if state == S_AWAIT_RACK then
        if pressed and nearRack and hand ~= nil then
            rk.handStart, rk.pullStart, rk.armed = hand, rk.pull, false
            if rk.rot then
                local gunW = worldOf(cur.gun)
                rk.pivotW = compose(gunW, rk.rest).loc
                rk.axisW = qrot(gunW.q, rk.axis)
            end
            local rackPose = cur.profile.rack.fingers
            if cur.profile.rack.hand == "right" then rackPose = mirrorFingers(rackPose, mirrorF) end
            setFingerPose(rackPose, false)
            -- the gun follows the driver, so its rack bone moves with the pull: the hand rides that bone
            attachRackHand(now, cur.gun, rk.bone)
            haptic(0.02, 0.4)
            enter(S_RACK)
        end
        return
    end
    if hand ~= nil then
        local d
        if rk.rot then d = rotaryPull(rk, hand)
        else d = dotV(subV(hand, rk.handStart), qrot(worldOf(cur.gun).q, rk.axis)) end
        rk.pull = math.max(rk.lock, math.min(rk.travel, rk.pullStart + d))
        setSlidePull(rk.pull)
        if not rk.armed and rk.pull >= rk.travel * cfgNum("mr_rack_done", 0.8) then
            rk.armed = true
            haptic(0.03, 0.6)
        end
        -- bolt path: back home after being open = closed (pushed forward and dropped by the hand)
        if rk.boltPath and rk.armed and rk.pull <= rk.travel * 0.05 then
            setSlidePull(0)
            setFingerPose(nil)
            releaseRackHand(now)
            haptic(0.05, 0.9)
            log("bolt closed")
            startFinish()
            return
        end
    end
    if rk.boltPath and (released or not gripDown) then
        -- a bolt stays where the hand leaves it
        setFingerPose(nil)
        releaseRackHand(now)
        enter(S_AWAIT_RACK)
        return
    end
    if released or not gripDown then
        setFingerPose(nil)
        releaseRackHand(now)
        rk.spring = { t0 = now, from = rk.pull, to = rk.armed and 0 or rk.lock, armed = rk.armed }
        enter(S_AWAIT_RACK)
    end
end

local function updateOpeners(now)
    local a = cur.openAnim
    if a == nil or cur.openers == nil then return end
    local t = a.dur > 0 and math.min(1.0, (now - a.t0) / a.dur) or 1.0
    local e = a.from + (a.to - a.from) * smooth(t)
    for _, o in ipairs(cur.openers) do driverSet(o.bone, lerpT(o.rest, o.open, e)) end
    -- an item carried by a part that is not its parent bone (Jakobs break-action shells vs Magazine01_Break): it closes
    -- with that part, from its seat at the open part to its rest in the closed gun
    if a.to == 0 and cur.profile.item.virtualCarrier ~= nil and cur.seat ~= nil then setItem(lerpT(cur.rest, cur.seat, e), false) end
    if t >= 1.0 and a.to == 1 then cur.openAnim = nil end
end

-- -------------------------------------------------------------------------------------------------------------------
-- input: the left grip (grab / rack) and the fire trigger (held back while the manual reload runs: the game is not in
-- its reload state, so a shot would fire the old clip)
-- -------------------------------------------------------------------------------------------------------------------
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state_)
    if user_index ~= 0 or state_ == nil then return end
    local down = uevrUtils.isButtonPressed(state_, BTN_LB)
    if down and not gripDown then
        gripPressed = true
        if (state == S_AWAIT and nearPouch) or (state == S_AWAIT_RACK and nearRack) then
            swallowGrip = true
            pcall(function() hands.setInputLocked(Handed.Left, true) end)
            pressLocked = true
        end
    elseif not down and gripDown then
        gripReleased = true
    end
    gripDown = down
    -- A press the manual reload has taken stays hidden from the game until it is let go, whatever the reload does
    -- meanwhile (2026-11-26: the reload ended as the magazine seated with the grip still held, and the game got that
    -- press and its release as a mine throw / attack; shells go back to "await" with the grip held too), then for
    -- GRIP_QUIET_S more.
    local now = os.clock()
    if swallowGrip or state == S_HOLD or state == S_INSERT or state == S_RACK then gripOwned = down end
    if gripOwned and not down then
        gripOwned = false
        gripQuietUntil = now + GRIP_QUIET_S
    end
    if swallowGrip or gripOwned or now < gripQuietUntil or state == S_HOLD or state == S_INSERT or state == S_RACK then
        state_.Gamepad.wButtons = state_.Gamepad.wButtons & ~BTN_LB
        if not down then swallowGrip = false end
    end
    -- round by round (OW2): the trigger stays live while waiting for / holding / pushing a round - a shot ends the
    -- reload with the rounds already in (the game's own behaviour for tube guns)
    local roundsWait = cur ~= nil and cur.profile ~= nil and cur.profile.style == "rounds" and (state == S_AWAIT or state == S_HOLD or state == S_INSERT)
    if roundsWait then
        if (state_.Gamepad.bRightTrigger or 0) > 100 then cur.triggerPulled = true end
    elseif state ~= S_IDLE then
        state_.Gamepad.bRightTrigger = 0
    end
end, 26)

-- -------------------------------------------------------------------------------------------------------------------
-- tick (post-stereo, once per frame: gun + controller poses of this frame)
-- -------------------------------------------------------------------------------------------------------------------
local lastTick, lastPawn = nil, nil

local function tickBody(now, dt, pressed, released)
    local a = _G.cronosReloadAnalyzer
    local ctx = a ~= nil and a.context() or nil
    local pawn = ctx ~= nil and ctx.pawn or nil
    if pawn ~= lastPawn then
        if lastPawn ~= nil and state ~= S_IDLE then cleanup("pawn changed") end
        lastPawn = pawn
    end
    if ctx == nil then
        if state ~= S_IDLE then cleanup("no gun") end
        status("no gun")
        return
    end

    local gun = ctx.wmesh
    local profile = a.getProfile()
    if ctx.key ~= tuneKey then loadTuneUI(ctx.key) end
    local enabled = configui.getValue("mr_enabled") ~= false
    local reason = blocked()
    local _, field = a.reloadMontage()
    local reloading = field ~= nil
    local started = reloading and not lastReloading
    lastReloading = reloading

    if state ~= S_IDLE then
        if ctx.key ~= cur.key or gun ~= cur.gun or not exists(cur.gun) then
            cleanup("weapon changed")
            return
        elseif reason == "cutscene" or not enabled then
            cleanup(reason or "disabled")
            return
        end
        -- the player asked for another reload while the manual one runs: not now
        if reloading then stopNativeReload("reload asked again") end
        if cur.triggerPulled then
            info(string.format("trigger pulled: reload ends with %d round(s) in", cur.loaded or 0))
            cleanup("done")
            return
        end
    end

    local ok, why = supported(profile)
    if not enabled or gun == nil or not ok or reason ~= nil then
        if state == S_IDLE then
            status(not enabled and "off" or (reason ~= nil and ("paused (" .. reason .. ")")) or ("native reload: " .. tostring(why)))
            return
        end
    end

    if state == S_IDLE then
        status(string.format("%s ready", tostring(profile and profile.name)))
        if started then tryIntercept(ctx, profile) end
        if state == S_IDLE then return end
    end
    if driver == nil or driver.comp == nil then cleanup("driver lost") return end
    cur.gunPW = predicted("gun", worldOf(cur.gun))
    if cur.useTP then pcall(tpTick, now) end
    if state ~= S_HOLD then pred.held = nil end
    if state ~= S_AWAIT then pred.pouch = nil end

    -- live seat tuning
    if cur.seat0 ~= nil then cur.seat, cur.approachT = tunedSeat(cur.seat0, cur.approach0) end
    pcall(updateOpeners, now)
    if ((state == S_CLOSE and cur.openAnim == nil) or state == S_AWAIT_RACK) and not cur.dockLeft then setItem(cur.seat, false) end
    if state == S_AWAIT then
        status(cur.profile.style == "rounds" and string.format("take a round from the left hip (%d in, trigger = done)", cur.loaded or 0)
            or "take a magazine from the left hip (left grip)")
        updateDropAndPouch(now, dt)
        if pressed and nearPouch and cur.drop == nil then
            if not grabFromPouch() then swallowGrip = false end
        end
    elseif state == S_HOLD then
        status("push the magazine into the gun")
        if not updateHeld() then
            setItem(cur.rest, true)
            enter(S_AWAIT)
        elseif released or not gripDown then
            dropHeld()
            enter(S_AWAIT)
        elseif wellDistance() <= (cur.profile.style == "rounds" and cfgNum("mr_round_insert_radius", 12.0) or cfgNum("mr_insert_radius", 7.0)) then
            startInsert()
        end
    elseif state == S_INSERT then
        if updateInsert() then
            haptic(0.04, 0.8)
            log("seated")
            if cur.profile.style == "rounds" then
                startFeed()
            elseif #cur.openers > 0 or cur.profile.item.docked then
                cur.closeT0 = now
                cur.openAnim = nil
                cur.flickPrev = nil
                enter(S_CLOSE)
            elseif cur.rack ~= nil then enter(S_AWAIT_RACK) else startFinish() end
        end
    elseif state == S_CLOSE then
        -- a docked item (speedloader) leaves 0.15 s after it docks, before anything closes (OW2 S_CLOSE): it hides and its
        -- rounds go back to their own place in the gun (reference pose under their parent - the cylinder - so they close
        -- with it). 2026-11-23: the speedloader + rounds stayed beside the gun while the cylinder swung shut.
        if cur.profile.item.docked and not cur.dockLeft then
            if now - cur.closeT0 < 0.15 then return end
            cur.dockLeft = true
            local item = cur.profile.item
            driverSet(item.bone, cur.seat, HIDDEN_SCALE)
            for _, g in ipairs(item.group or {}) do
                touchBone(g.bone)
                pcall(function() driver.comp:ResetBoneTransformByName(fname(g.bone)) end)
            end
            if driver ~= nil then driver.dirty = true end
            cur.closeT0 = now
        end
        -- a part that carries the item (cylinder, break) shuts on a flick of the gun along its closing direction (OW2
        -- 2026-11-19); parts without the item close by themselves
        if cur.openAnim == nil then
            local dir = nil
            for _, o in ipairs(cur.openers) do if o.carries and o.closeDir ~= nil then dir = o.closeDir break end end
            local flicked = configui.getValue("mr_flick_close") == false or dir == nil
            if not flicked then
                status("flick the gun to close it")
                local gunW = worldOf(cur.gun)
                if cur.flickPrev ~= nil and dt > 0 then
                    local v = mulV(subV(gunW.loc, cur.flickPrev), 1 / dt)
                    if dotV(v, qrot(gunW.q, dir)) >= cfgNum("mr_flick_speed", 110.0) then flicked = true end
                end
                cur.flickPrev = gunW.loc
            end
            if flicked then cur.openAnim = { t0 = now, from = 1, to = 0, dur = 0.12 } end
        elseif now - cur.openAnim.t0 >= cur.openAnim.dur then
            status("closing")
            cur.openAnim = nil
            for _, o in ipairs(cur.openers) do driverSet(o.bone, o.rest) end
            if cur.profile.item.virtualCarrier ~= nil then setItem(cur.rest, false) cur.dockLeft = true end
            haptic(0.04, 0.7)
            if cur.rack ~= nil then enter(S_AWAIT_RACK) else startFinish() end
        end
    elseif state == S_AWAIT_RACK or state == S_RACK then
        status(state == S_RACK and "pull it back and let go" or "rack the slide (left grip on it)")
        updateRack(now, pressed, released)
    elseif state == S_FINISH then
        status("reloading...")
        updateFinish(now)
    end
end

-- dev: tops the current mode's reserve up to 20 every 3 s (SHCharacterPlayItemsComponent:CollectItem with the ammo
-- component's UsedAmmunition row: HandgunAmmo, ShotgunAmmo, MachinegunAmmo, ArbalestAmmo - MCP 2026-11-26)
local nextAmmoRefill = 0
local function devAmmo(now)
    if configui.getValue("mr_dev_ammo") ~= true or now < nextAmmoRefill then return end
    nextAmmoRefill = now + 3.0
    local a = _G.cronosReloadAnalyzer
    local ctx = a ~= nil and a.context() or nil
    if ctx == nil then return end
    local spare = reserveOf(ctx.ammo)
    if spare ~= nil and spare < 20 then
        -- (a full inventory takes no more: SetUnlimitedInventory lifts the slot limit, MCP 2026-11-26)
        pcall(function() ctx.pawn.Items:SetUnlimitedInventory() end)
        pcall(function() ctx.pawn.Items:CollectItem(ctx.ammo.UsedAmmunition.RowName, 20 - spare) end)
    end
end

local function tick()
    local now = os.clock()
    pcall(devAmmo, now)
    local dt = lastTick ~= nil and math.min(0.1, now - lastTick) or 0.016
    lastTick = now
    local pressed, released, locked = gripPressed, gripReleased, pressLocked
    gripPressed, gripReleased, pressLocked = false, false, false
    local ok, err = pcall(tickBody, now, dt, pressed, released)
    if not ok then
        info(string.format("tick error (state %s): %s", state, tostring(err)))
        if state ~= S_IDLE then pcall(cleanup, "error") end
    end
    driverFlush()
    pcall(markerTick)
    pcall(tickRackHand, now)
    if locked and not fingers.active and state ~= S_HOLD and state ~= S_RACK then lockLeftInput(false) end
end

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick or not vr.is_hmd_active() then return end
    ranThisTick = true
    tick()
end)

-- Reset scripts: the Lua state goes, the components stay - the gun must come off the driver and ReloadTime back
uevr.sdk.callbacks.on_script_reset(function()
    pcall(function() if state ~= S_IDLE then cleanup("script reset") end end)
    pcall(tpRelease)
    pcall(releaseDriver)
    pcall(restoreFingerLocals, fingers)
    pcall(function() lockLeftInput(false) end)
    pcall(markerDestroy)
    _G.cronosManualReloadBusy = false
end)

uevrUtils.registerPreLevelChangeCallback(function()
    -- everything belonged to the old world: forget without touching it
    driver = nil
    tp = nil
    fingers = {}
    lockLeftInput(false)
    rackHand = nil
    marker = nil
    cur = {}
    lastPawn, swallowGrip, nearPouch, nearRack, lastReloading = nil, false, false, false, false
    gripOwned, gripQuietUntil = false, 0
    enter(S_IDLE)
end)

info("loaded")
