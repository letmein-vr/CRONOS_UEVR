-- Cronos weapon recoil (port of the Borderlands 4 / Outer Worlds 2 / Hellraiser anim-driven kick, 2026-11-12).
--
-- Cronos is third person: the flat game hangs the gun on the BODY (CharacterMesh0 socket hand_r_socket, zero relative)
-- and every shot plays its own (dynamic) montage on that body that kicks the right hand. Recorded live 2026-11-12:
-- SMG ~2.5 cm back / 3-4 deg up over ~0.2 s per shot; heavier weapons up to ~30-45 cm and ~50 deg roll over ~1 s
-- (whole-arm third-person animations, hence the strength sliders and the caps).
--   * kick K = hand_r_socket now relative to a baseline (MakeRelativeTransform, the socket's own frame). The baseline
--     follows the pose while no shot montage plays and freezes when one starts, so aim drift between shots never
--     leaks in. A "shot montage" = a body montage that starts while the right trigger is held (or just after it is
--     let go: some weapons fire on release); reload / melee montages don't kick. When the shot montages end, the kick
--     eases back out.
--   * the body is hidden in VR and only ticks its pose, so its bones are refreshed while the game aims
--     (two_handed_integration.lua's _G.cronosHoldBodyBones, shared with the left-grip probe).
--   * the gun root sits on hands.lua's pawn-owned proxy. The kick goes on that proxy: proxy' = D * proxy with
--     D = G^-1 * K * G (G = the root's relative transform on the proxy), so the gun root moves by K in its own frame.
--     Hands mode: written here (the proxy is snapped to the right controller, identity relative). IK modes: the IK
--     weapon lock in two_handed_integration.lua composes _G.cronosRecoilDelta() when it places the proxy, and the
--     right IK target gets the same D on top of the weapon's IK hand offset. Gloves / IK hands attached to the gun
--     (two-handing) follow it.
-- CronosAimFix reads the gun root (MuzzlePoint + right vector) at fire time, so later shots of a burst leave the kicked
-- barrel.

local uevrUtils = require("libs/uevr_utils")
local configui = require("libs/configui")
local controllers = require("libs/controllers")

local SOCKET = "hand_r_socket"
local RTS_COMPONENT = 2
local TRIGGER_THRESHOLD = 64
local SHOT_AFTER_RELEASE_S = 0.3   -- a montage starting this soon after the trigger is let go is still a shot
local BONES_READY_S = 0.1          -- after the body starts refreshing its bones, before its pose is trusted
local TICK_PRIORITY = 500          -- post engine tick: before the IK weapon lock places the proxy (-1000)

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 2.5, label = "Weapon Recoil", layout = {
    { widgetType = "checkbox", id = "cr_recoil_enabled", label = "Weapon recoil (the game's own kick on the gun and hands)", initialValue = true },
    { widgetType = "slider_float", id = "cr_recoil_strength_loc", label = "Kick strength, position", initialValue = 0.6, range = {0.0, 1.5} },
    { widgetType = "slider_float", id = "cr_recoil_strength_rot", label = "Kick strength, rotation", initialValue = 0.6, range = {0.0, 1.5} },
    { widgetType = "slider_float", id = "cr_recoil_max_cm", label = "Max kick (cm)", initialValue = 8.0, range = {1.0, 40.0} },
    { widgetType = "slider_float", id = "cr_recoil_max_deg", label = "Max kick (deg)", initialValue = 15.0, range = {1.0, 60.0} },
    { widgetType = "slider_float", id = "cr_recoil_ease", label = "Ease out after the shot (s)", initialValue = 0.15, range = {0.0, 0.5} },
    { widgetType = "text", id = "cr_recoil_status", label = "Last shot: -" },
}})

local function enabled() return configui.getValue("cr_recoil_enabled") ~= false end
local function num(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

local function hitResult()
    return uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
end

local socketName = nil
local function socketFName()
    if socketName == nil then socketName = uevrUtils.fname_from_string(SOCKET) end
    return socketName
end

local identity = nil
local function identityT()
    if identity == nil then
        identity = kismet_math_library:MakeTransform(uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0), uevrUtils.vector(1, 1, 1))
    end
    return identity
end

-- ==========================================
-- State
-- ==========================================
local triggerDown, lastTriggerDown = false, -100
local bonesSince = nil       -- os.clock() when this script started holding the body's bones
local baseline = nil         -- hand_r_socket (component space) before the current shot(s)
local lastMontage = nil      -- the body's active montage last tick
local shotMontages = {}      -- montages that started as shots (keyed by object)
local shooting = false       -- a shot montage is playing
local kick = nil             -- the current scaled kick K (socket frame), or nil
local easeFrom = nil         -- { loc, rot, t0, dur } while easing back out
local delta = nil            -- D for the proxy, or nil (exported)
local peak = { cm = 0, deg = 0, rawCm = 0, rawDeg = 0 }
local proxyKicked = nil      -- the proxy this script wrote a kick to (Hands mode)

_G.cronosRecoilDelta = function() return delta end

local function resetState()
    baseline, lastMontage, shotMontages, shooting = nil, nil, {}, false
    kick, easeFrom, delta = nil, nil, nil
end

local function releaseBones()
    if bonesSince ~= nil and _G.cronosReleaseBodyBones ~= nil then pcall(_G.cronosReleaseBodyBones, "recoil") end
    bonesSince = nil
end

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 then return end
    triggerDown = (state.Gamepad.bRightTrigger or 0) >= TRIGGER_THRESHOLD
    if triggerDown then lastTriggerDown = os.clock() end
end, 60)

-- ==========================================
-- Kick math
-- ==========================================
local function maxAbsAngle(r)
    return math.max(math.abs(r.Pitch), math.abs(r.Yaw), math.abs(r.Roll))
end

local function scaleRot(r, s)
    if s == 1 then return r end
    return kismet_math_library:RLerp(uevrUtils.rotator(0, 0, 0), r, s, true)
end

-- raw kick (socket frame) -> scaled + capped { loc, rot }
local function shapeKick(raw)
    local t = raw.Translation
    local r = kismet_math_library:Quat_Rotator(raw.Rotation)
    local rawCm = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
    local rawDeg = maxAbsAngle(r)
    local sLoc, sRot = num("cr_recoil_strength_loc", 0.6), num("cr_recoil_strength_rot", 0.6)
    local loc = { X = t.X * sLoc, Y = t.Y * sLoc, Z = t.Z * sLoc }
    local cm = rawCm * sLoc
    local maxCm = num("cr_recoil_max_cm", 8.0)
    if cm > maxCm and cm > 0 then
        local f = maxCm / cm
        loc = { X = loc.X * f, Y = loc.Y * f, Z = loc.Z * f }
        cm = maxCm
    end
    local rot = scaleRot(r, sRot)
    local deg = maxAbsAngle(rot)
    local maxDeg = num("cr_recoil_max_deg", 15.0)
    if deg > maxDeg and deg > 0 then
        rot = scaleRot(rot, maxDeg / deg)
        deg = maxDeg
    end
    peak.cm, peak.deg = math.max(peak.cm, cm), math.max(peak.deg, deg)
    peak.rawCm, peak.rawDeg = math.max(peak.rawCm, rawCm), math.max(peak.rawDeg, rawDeg)
    return { loc = loc, rot = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll } }
end

local function kickTransform(k)
    return kismet_math_library:MakeTransform(uevrUtils.vector(k.loc.X, k.loc.Y, k.loc.Z),
        uevrUtils.rotator(k.rot.Pitch, k.rot.Yaw, k.rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function updateStatus()
    configui.setLabel("cr_recoil_status", string.format("Last shot: peak %.1f cm / %.1f deg (game's kick %.1f cm / %.1f deg)",
        peak.cm, peak.deg, peak.rawCm, peak.rawDeg))
end

-- D = G^-1 * K * G: the proxy-local change that moves the gun root by K in its own frame
local function proxyDelta(k, root)
    local g = kismet_math_library:MakeTransform(root.RelativeLocation, root.RelativeRotation, uevrUtils.vector(1, 1, 1))
    return kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(g), kickTransform(k)), g)
end

-- ==========================================
-- Hands mode: the proxy on the right controller (identity relative when not kicking)
-- ==========================================
local function applyToProxyHands(proxy)
    local controller = controllers.getController(1)
    local onController = proxy ~= nil and controller ~= nil and proxy.AttachParent == controller
    if onController and delta ~= nil then
        local t = delta.Translation
        proxy:K2_SetRelativeLocationAndRotation(uevrUtils.vector(t.X, t.Y, t.Z), kismet_math_library:Quat_Rotator(delta.Rotation),
            false, hitResult(), false)
        proxyKicked = proxy
        return
    end
    if proxyKicked ~= nil then
        local p = proxyKicked
        proxyKicked = nil
        -- back to the snapped pose (only while it is still on the controller; on the IK rig the lock owns it)
        if uevrUtils.getValid(p) ~= nil and controller ~= nil and p.AttachParent == controller then
            pcall(function()
                p:K2_SetRelativeLocationAndRotation(uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0), false, hitResult(), false)
            end)
        end
    end
end

-- ==========================================
-- Per tick (post engine tick: the body's anim for this frame is done)
-- ==========================================
local function getGunRoot(pawn)
    local root = nil
    pcall(function() root = uevrUtils.getValid(pawn.WeaponPlayerComponent.MultiModeGun.RootComponent) end)
    return root
end

local function tick()
    local pawn = uevr.api:get_local_pawn(0)
    local proxy = _G.cronosGetGunProxy ~= nil and _G.cronosGetGunProxy() or nil -- nil in cutscenes / gun off the proxy
    local body = pawn ~= nil and uevrUtils.getValid(pawn.Mesh) or nil
    local root = pawn ~= nil and getGunRoot(pawn) or nil
    local aiming = pawn ~= nil and _G.cronosIsRangedAiming ~= nil and _G.cronosIsRangedAiming(pawn) == true

    if not enabled() or body == nil or root == nil or proxy == nil or _G.cronosHoldBodyBones == nil then
        resetState()
        releaseBones()
        applyToProxyHands(proxy)
        return
    end

    -- the hidden body only has a current pose while its bones are refreshed: while aiming, and until a kick is over
    if aiming or shooting or easeFrom ~= nil then
        if bonesSince == nil then bonesSince = _G.cronosHoldBodyBones(body, "recoil") end
    else
        releaseBones()
        resetState()
        applyToProxyHands(proxy)
        return
    end
    if bonesSince == nil or os.clock() - bonesSince < BONES_READY_S then return end

    local now = os.clock()
    local pose = body:GetSocketTransform(socketFName(), RTS_COMPONENT)

    local montage = nil
    pcall(function() montage = body:GetAnimInstance():GetCurrentActiveMontage() end)
    if montage ~= nil and montage ~= lastMontage then
        -- a new montage: a shot if the trigger is (or was just) pulled
        if triggerDown or now - lastTriggerDown <= SHOT_AFTER_RELEASE_S then
            if not shooting then
                peak = { cm = 0, deg = 0, rawCm = 0, rawDeg = 0 }
                easeFrom = nil
            end
            shotMontages[montage] = true
        end
    end
    lastMontage = montage
    local wasShooting = shooting
    shooting = montage ~= nil and shotMontages[montage] == true

    if shooting then
        if baseline == nil then baseline = pose end
        kick = shapeKick(kismet_math_library:MakeRelativeTransform(pose, baseline))
    else
        if wasShooting then
            -- the shots are over: ease the last kick back out, then follow the pose again
            shotMontages = {}
            local dur = num("cr_recoil_ease", 0.15)
            if kick ~= nil and dur > 0 then easeFrom = { loc = kick.loc, rot = kick.rot, t0 = now, dur = dur } end
            kick = nil
            updateStatus()
        end
        baseline = pose
        if easeFrom ~= nil then
            local a = math.min(1.0, (now - easeFrom.t0) / easeFrom.dur)
            local e = 1 - (1 - a) ^ 3
            local f = 1 - e
            local r = scaleRot(uevrUtils.rotator(easeFrom.rot.Pitch, easeFrom.rot.Yaw, easeFrom.rot.Roll), f)
            kick = { loc = { X = easeFrom.loc.X * f, Y = easeFrom.loc.Y * f, Z = easeFrom.loc.Z * f },
                     rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
            if a >= 1.0 then easeFrom, kick = nil, nil end
        end
    end

    delta = nil
    if kick ~= nil and root.AttachParent == proxy then delta = proxyDelta(kick, root) end
    applyToProxyHands(proxy)
end

uevrUtils.registerPostEngineTickCallback(function(engine, delta_)
    local ok, err = pcall(tick)
    if not ok then
        print("[weapon_recoil] " .. tostring(err))
        resetState()
    end
end, TICK_PRIORITY)

uevrUtils.registerPreLevelChangeCallback(function(level)
    resetState()
    releaseBones()
    proxyKicked = nil
end)

uevr.sdk.callbacks.on_script_reset(function()
    resetState()
    pcall(applyToProxyHands, proxyKicked)
    releaseBones()
    _G.cronosRecoilDelta = nil
end)
