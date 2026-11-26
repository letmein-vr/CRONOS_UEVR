-- Cronos manual reload, step 1: automatic per-mode reload analysis (2026-11-26, port of The Outer Worlds 2 /
-- Borderlands 4 reload_analyzer). The analysis itself lives in cronos/reload_learn.lua (pure Lua); this file is the
-- Cronos game access + the recording.
--
-- Cronos facts (MCP 2026-11-26):
--   * The MultiModeGun is ONE actor (pawn.WeaponPlayerComponent.MultiModeGun) with ONE SkeletalMeshComponent (gun.Mesh)
--     whose asset swaps per mode. The mode = wpc:GetWeaponModeContainer() (GravityGunContainer_BP_C, SpreadGun...,
--     SmartGun..., ...). Each container has its own AmmoComponent (GetAmmoInMagazine / GetMagazineSize / GetAmmoCount =
--     reserve, ReloadAddAmmo, ReloadAmmoAddedPerNotify: 0 = fill, 1 = one shell) and AnimationSettings (ReloadAnimData,
--     ReloadEmptyAnimData, ReloadBodyCarryAnimData ...: the BODY's reload anim; GravityGun has no empty variant).
--   * So a profile is keyed by MODE + MESH ("GravityGun|SK_HandGun_01"): the mode decides the reload animation, the mesh
--     the bones. On a mode switch the container changes at once and the mesh a moment later (two_handed 2026-11-12), so
--     a key is only taken while the mesh belongs to the mode (the analyzer waits for the swap: see stableKey).
--   * The reload plays as a montage on the hidden body (CharacterMesh0): a montage asset (SpreadGun
--     Tra_Spread_Reload_Double_Montage) or a DYNAMIC montage "AnimMontage_<n>" made from the anim sequence (GravityGun
--     Tra_Grav_Aim_Reload, 1.93 s). Shots play dynamic montages too, so a dynamic one is a reload when its length is
--     the reload sequence's.
--   * The flat game hangs the gun on the body's hand_r_socket with zero relative: gun component space = that socket's
--     frame. The hands are the body's hand_l / hand_r in it; the body only refreshes its bones with
--     VisibilityBasedAnimTickOption 0 (_G.cronosHoldBodyBones from two_handed_integration.lua).
--   * The magazines are gun bones: handgun GG_cartridge (in the gun) + GG_cartridge_02 (the fresh one the left hand
--     brings in), SmartGun SmrtG_slide (+ braces, pulled off the front and slid back). The shotgun's gun anim is idle -
--     its shell is not a gun bone (a prop or nothing: recorded as a hand prop when one shows up near a hand).
--
-- API: _G.cronosReloadAnalyzer = { getProfile(), keyFor(), context(), isRecording(), wantsReload(), relearn(),
--   isReloadMontage(montage), reloadMontage() }.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local learn = require('cronos/reload_learn')

local PROFILE_FILE = "cronos_manual_reload_auto.json"
local RTS_COMPONENT, RTS_WORLD = 2, 0
local END_TAIL = 0.35          -- s without a reload montage before a recording ends
local REST_REFRESH = 0.5       -- s between idle rest-pose snapshots
local FINGER_EVERY = 0.08      -- s between finger snapshots while recording
local MAX_FRAMES = 900
local PROP_NEAR_CM = 20.0      -- a mesh this close to a hand during the reload is a hand prop candidate
-- dev: write every recording's raw frames to data/cronos_reload_frames_<key>.json (OFF for release)
local DUMP_FRAMES = false
local GUN_SOCKET = "hand_r_socket"
local HAND_L, HAND_R = "hand_l", "hand_r"

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 2.91, label = "Manual Reload - Analysis", layout = {
    { widgetType = "text", id = "mr_auto_status", label = "Reload analysis: -" },
    { widgetType = "button", id = "mr_auto_relearn", label = "Re-learn this weapon mode (next native reloads)", size = {320, 24} },
    { widgetType = "checkbox", id = "mr_auto_log", label = "Detailed analysis log (log.txt)", initialValue = false },
}})

local function info(s) pcall(function() uevr.params.functions.log_info("[reload_analyzer] " .. s) end) end
local function detail(s) if configui.getValue("mr_auto_log") == true then info(s) end end

local relT, copyT, packT, dist = learn.relT, learn.copyT, learn.packT, learn.dist
local function fmtV(v) return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z) end
local fnames = {}
local function fname(s)
    if fnames[s] == nil then fnames[s] = uevrUtils.fname_from_string(s) end
    return fnames[s]
end
local function shortName(obj)
    if obj == nil then return "-" end
    local ok, s = pcall(function() return obj:get_fname():to_string() end)
    return ok and s or "-"
end
local function className(obj)
    local ok, s = pcall(function() return obj:get_class():get_fname():to_string() end)
    return ok and s or "?"
end
local function addrOf(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

-- -------------------------------------------------------------------------------------------------------------------
-- profiles
-- -------------------------------------------------------------------------------------------------------------------
local profiles = {}
pcall(function()
    local p = json.load_file(PROFILE_FILE)
    if type(p) == "table" then profiles = p end
end)
-- racks the game's hand never comes near (handgun GG_bolt_r, 17-19 cm: it moves by itself) are dropped (2026-11-26)
for k, p in pairs(profiles) do
    local g = type(p) == "table" and p.rack ~= nil and p.rack.grip ~= nil and p.rack.grip.loc or nil
    if g ~= nil and math.sqrt(g.X * g.X + g.Y * g.Y + g.Z * g.Z) > 12.0 then
        p.rack = nil
        for _, r in pairs(p.records or {}) do if type(r) == "table" then r.rack = nil end end
    end
end
-- profiles learned from a wrong "prop" (the hidden melee gauntlet, 2026-11-26) are dropped: those modes learn again
for k, p in pairs(profiles) do
    if type(p) == "table" and p.item ~= nil and p.item.prop ~= nil and ({ SK_Melee = true, Sphere = true, Cube = true })[p.item.prop.asset] then profiles[k] = nil end
end
local function saveProfiles() pcall(function() json.dump_file(PROFILE_FILE, profiles, 1) end) end

-- -------------------------------------------------------------------------------------------------------------------
-- Cronos game access
-- -------------------------------------------------------------------------------------------------------------------
local function getPawn()
    local p = nil
    pcall(function() p = uevr.api:get_local_pawn(0) end)
    return p
end

-- the live weapon context: { pawn, body, wpc, gun, wmesh, container, ammo, anims, mode, meshName, key }
local function gameContext(pawn)
    if pawn == nil then return nil end
    local c = { pawn = pawn }
    local ok = pcall(function()
        c.body = pawn.Mesh
        c.wpc = pawn.WeaponPlayerComponent
        c.gun = c.wpc and c.wpc.MultiModeGun or nil
        c.wmesh = c.gun and c.gun.Mesh or nil
        c.container = c.wpc and c.wpc:GetWeaponModeContainer() or nil
    end)
    if not ok or c.body == nil or c.wmesh == nil or c.container == nil then return nil end
    pcall(function() c.ammo = c.container.AmmoComponent end)
    pcall(function() c.anims = c.container.AnimationSettings end)
    if c.ammo == nil then return nil end
    local cls = className(c.container)
    c.mode = cls:gsub("_C$", ""):gsub("_BP$", ""):gsub("Container$", "")
    pcall(function() c.meshName = c.wmesh.SkeletalMesh:get_fname():to_string() end)
    if c.meshName == nil then return nil end
    c.key = c.mode .. "|" .. c.meshName
    c.display = c.mode .. " (" .. c.meshName:gsub("^SK_", "") .. ")"
    return c
end

-- The body's reload animations for the mode: ReloadAnimData, ReloadEmptyAnimData and their body-carry variants
local RELOAD_FIELDS = { "ReloadAnimData", "ReloadEmptyAnimData", "ReloadBodyCarryAnimData", "ReloadEmptyBodyCarryAnimData" }
local animCache = {}   -- container address -> { anims = { {obj, len, field} }, hasEmpty }
local function reloadAnimsOf(c)
    local a = addrOf(c.container)
    local e = a and animCache[a] or nil
    if e ~= nil then return e end
    e = { anims = {}, hasEmpty = false }
    for _, f in ipairs(RELOAD_FIELDS) do
        pcall(function()
            local anim = c.anims[f].Animation
            if anim ~= nil then
                local len = nil
                pcall(function() len = anim:GetPlayLength() end)
                e.anims[#e.anims + 1] = { obj = anim, addr = addrOf(anim), len = len, field = f, name = shortName(anim) }
                if f == "ReloadEmptyAnimData" then e.hasEmpty = true end
            end
        end)
    end
    if a ~= nil then animCache[a] = e end
    local names = {}
    for _, x in ipairs(e.anims) do names[#names + 1] = x.field .. "=" .. x.name .. string.format(" (%.3f s)", x.len or -1) end
    info(c.mode .. " reload anims: " .. (#names > 0 and table.concat(names, ", ") or "none") .. (e.hasEmpty and "" or " (no empty variant)"))
    return e
end

-- montage object -> the RELOAD_FIELDS entry it plays, or false
local montageCache = {}
local function reloadFieldOf(c, montage)
    if montage == nil then return nil end
    local ma = addrOf(montage)
    local key = tostring(ma) .. "|" .. tostring(addrOf(c.container))
    local hit = montageCache[key]
    if hit ~= nil then return hit or nil end
    local e = reloadAnimsOf(c)
    local res = false
    for _, x in ipairs(e.anims) do
        if x.addr ~= nil and x.addr == ma then res = x.field break end
    end
    if not res then
        local name = shortName(montage)
        if name:find("^AnimMontage_") then
            local len = nil
            pcall(function() len = montage:GetPlayLength() end)
            if len ~= nil then
                for _, x in ipairs(e.anims) do
                    if x.len ~= nil and math.abs(x.len - len) < 0.002 then res = x.field break end
                end
            end
        end
    end
    montageCache[key] = res
    return res or nil
end

local function bodyMontage(c)
    local m, pos = nil, nil
    pcall(function()
        local ai = c.body:GetAnimInstance()
        m = ai:GetCurrentActiveMontage()
        if m ~= nil then pos = ai:Montage_GetPosition(m) end
    end)
    return m, pos
end
local function gunMontage(c)
    local m, pos = nil, nil
    pcall(function()
        local ai = c.wmesh:GetAnimInstance()
        m = ai:GetCurrentActiveMontage()
        if m ~= nil then pos = ai:Montage_GetPosition(m) end
    end)
    return m, pos
end

local function getClip(c)
    local n = nil
    pcall(function() n = c.ammo:GetAmmoInMagazine() end)
    return n
end

-- -------------------------------------------------------------------------------------------------------------------
-- live state
-- -------------------------------------------------------------------------------------------------------------------
local cur = nil       -- current weapon context + bones
local rec = nil       -- active recording
local clock = 0
local relearnKey = nil
local bodyHeld = nil  -- body mesh whose bones the analyzer keeps fresh

local function setStatus(text) pcall(function() configui.setLabel("mr_auto_status", "Reload analysis: " .. text) end) end

local function profileSummary(p)
    if p == nil or p.item == nil then
        if p ~= nil and p.failed then return "could not learn (" .. tostring(p.failed) .. ") - native reload" end
        return "not learned yet - do a normal reload (one with rounds left, one from empty)"
    end
    local parts = { p.style or "?", (p.hand or "?") .. " hand" }
    if p.item.bone then parts[#parts + 1] = "item " .. p.item.bone end
    if p.item.prop then parts[#parts + 1] = "prop " .. tostring(p.item.prop.asset) end
    if p.rack then parts[#parts + 1] = "rack " .. p.rack.bone end
    parts[#parts + 1] = "learned: " .. (p.recorded and p.recorded.tactical and "tactical " or "") ..
        (p.recorded and p.recorded.empty and "empty" or "")
    if p.recorded and p.hasEmptyReload and not p.recorded.empty then parts[#parts + 1] = "(empty reload still to learn)" end
    return table.concat(parts, ", ")
end

local function updateStatus()
    if cur == nil then setStatus("no gun") return end
    if rec ~= nil then setStatus(cur.display .. ": recording the reload...") return end
    setStatus(cur.display .. ": " .. profileSummary(profiles[cur.key]))
end

local function readBones(wmesh, bones)
    local out = {}
    for i, b in ipairs(bones) do
        pcall(function() out[i] = copyT(wmesh:GetSocketTransform(b.f, RTS_COMPONENT)) end)
    end
    return out
end

local bodyCache = { body = nil }
local function bodyInfo(body)
    if bodyCache.body == body and bodyCache.l ~= nil then return bodyCache end
    local c = { body = body, fingers = { l = {}, r = {} } }
    pcall(function()
        c.l, c.r, c.s = fname(HAND_L), fname(HAND_R), fname(GUN_SOCKET)
        local n = body:GetNumBones()
        for i = 0, n - 1 do
            local f = body:GetBoneName(i)
            local s = f:to_string()
            local low = s:lower()
            local finger = (low:find("index", 1, true) or low:find("middle", 1, true) or low:find("ring", 1, true)
                or low:find("pinky", 1, true) or low:find("thumb", 1, true)) and not low:find("socket", 1, true)
                and not low:find("ik", 1, true) and not low:find("twist", 1, true)
            if finger then
                if body:BoneIsChildOf(f, c.l) then c.fingers.l[#c.fingers.l + 1] = { name = s, f = f }
                elseif body:BoneIsChildOf(f, c.r) then c.fingers.r[#c.fingers.r + 1] = { name = s, f = f } end
            end
        end
    end)
    info(string.format("body fingers: %d left, %d right", #c.fingers.l, #c.fingers.r))
    bodyCache = c
    return c
end

local function holdBody(body)
    if _G.cronosHoldBodyBones == nil or body == nil then return end
    if bodyHeld ~= body then
        if bodyHeld ~= nil and _G.cronosReleaseBodyBones then pcall(_G.cronosReleaseBodyBones, "reload_analyzer") end
        pcall(_G.cronosHoldBodyBones, body, "reload_analyzer")
        bodyHeld = body
    end
end
local function releaseBody()
    if bodyHeld ~= nil and _G.cronosReleaseBodyBones then pcall(_G.cronosReleaseBodyBones, "reload_analyzer") end
    bodyHeld = nil
end

local function setupWeapon(c)
    cur = c
    cur.bones, cur.byName, cur.nextRest = {}, {}, 0
    cur.reloadAnims = reloadAnimsOf(c)
    cur.hasEmpty = cur.reloadAnims.hasEmpty
    cur.bodyInfo = bodyInfo(c.body)
    pcall(function()
        local n = c.wmesh:GetNumBones()
        for i = 0, n - 1 do
            local f = c.wmesh:GetBoneName(i)
            local p = "None"
            pcall(function() p = c.wmesh:GetParentBone(f):to_string() end)
            local b = { name = f:to_string(), f = f, parent = p, index = #cur.bones + 1 }
            cur.bones[#cur.bones + 1] = b
            cur.byName[b.name] = b
        end
    end)
    cur.rest = readBones(c.wmesh, cur.bones)
    pcall(function() cur.magSize = c.ammo:GetMagazineSize() end)
    pcall(function() cur.perNotify = c.ammo.ReloadAmmoAddedPerNotify end)
    info(string.format("weapon %s key %s, %d bones, magazine %s, %s, profile %s", cur.display, cur.key, #cur.bones,
        tostring(cur.magSize), (cur.perNotify or 0) > 0 and ("+" .. cur.perNotify .. " per insert") or "fills",
        profiles[cur.key] and "yes" or "no"))
    updateStatus()
end

local function isEmptyVariant(clip) return clip == 0 and cur ~= nil and cur.hasEmpty end

local function needsRecording(clip)
    if cur == nil or cur.key == nil then return false end
    if relearnKey == cur.key then return true end
    local p = profiles[cur.key]
    if p == nil or p.recorded == nil then return true end
    if p.failed then return false end
    -- shell guns load the same way with rounds left or from empty: either recording is enough (DoubleBarrell 2026-11-26)
    if p.style == "rounds" and (p.recorded.tactical ~= nil or p.recorded.empty ~= nil) then return false end
    if isEmptyVariant(clip) then return p.recorded.empty == nil end
    return p.recorded.tactical == nil
end

-- -------------------------------------------------------------------------------------------------------------------
-- recording
-- -------------------------------------------------------------------------------------------------------------------
local function socketT(body)
    local t = nil
    pcall(function() t = copyT(body:GetSocketTransform(cur.bodyInfo.s, RTS_COMPONENT)) end)
    return t
end

-- a mesh near a hand that is not the gun / body parts: the game's hand prop (shell, cell...)
-- (Sphere / Cube: manual_reload.lua's own seat marker on the gun, learned as the Arbalest's "prop" 2026-11-26)
local IGNORE_ASSETS = { SK_DefaultBoots = true, Ch_MH_Traveler_Proxy = true, SK_Melee = true, Sphere = true, Cube = true }
local function findHandProp(sBody, bodyW)
    local best, bestD = nil, PROP_NEAR_CM
    local handsW = {}
    pcall(function()
        handsW.l = copyT(cur.body:GetSocketTransform(cur.bodyInfo.l, RTS_WORLD))
        handsW.r = copyT(cur.body:GetSocketTransform(cur.bodyInfo.r, RTS_WORLD))
    end)
    if handsW.l == nil then return nil end
    local function scan(parent, depth)
        local ch = nil
        pcall(function() ch = parent.AttachChildren end)
        if ch == nil then return end
        for i = 1, #ch do
            local c = ch[i]
            if c ~= nil and c ~= cur.wmesh then
                local cls = className(c)
                if cls:find("MeshComponent", 1, true) and not cls:find("Poseable", 1, true) then
                    local asset = nil
                    pcall(function() asset = c.StaticMesh end)
                    if asset == nil then pcall(function() asset = c.SkeletalMesh end) end
                    local an = shortName(asset)
                    -- only what the player would see (2026-11-26: the hidden melee gauntlet SK_Melee by the right hand
                    -- was learned as the shotgun's "prop")
                    local vis = false
                    pcall(function() vis = c:IsVisible() and not c.bHiddenInGame end)
                    if asset ~= nil and vis and not IGNORE_ASSETS[an] then
                        local w = nil
                        pcall(function() w = copyT(c:K2_GetComponentToWorld()) end)
                        if w ~= nil then
                            for hk, h in pairs(handsW) do
                                local d = dist(w.loc, h.loc)
                                if d < bestD then best, bestD = { comp = c, w = w, asset = an, cls = cls, hand = hk }, d end
                            end
                        end
                    end
                end
                if depth < 2 then scan(c, depth + 1) end
            end
        end
    end
    scan(cur.body, 0)
    scan(cur.wmesh, 1)
    if best == nil then return nil end
    local socket = "None"
    pcall(function() socket = best.comp.AttachSocketName:to_string() end)
    return { T = relT(sBody, relT(bodyW, best.w)), asset = best.asset, cls = best.cls, socket = socket, hand = best.hand,
             vis = (function() local v = nil pcall(function() v = best.comp:IsVisible() end) return v end)() }
end

local function startRecording(field)
    rec = { t0 = clock, lastActive = clock, frames = {}, fingers = {}, nextFinger = 0 }
    rec.clip0 = getClip(cur)
    rec.empty = isEmptyVariant(rec.clip0) or field == "ReloadEmptyAnimData" or field == "ReloadEmptyBodyCarryAnimData"
    rec.field = field
    rec.key = cur.key
    rec.rest = cur.rest
    updateStatus()
    info("recording " .. (rec.empty and "EMPTY" or "TACTICAL") .. " reload of " .. cur.display .. " (" .. tostring(field) .. ", clip " .. tostring(rec.clip0) .. ")")
end

local function recordFrame()
    local clipNow = getClip(cur)
    if clipNow ~= nil then
        if rec.maxClip ~= nil and clipNow < rec.maxClip then rec.fired = true return end
        if rec.maxClip == nil or clipNow > rec.maxClip then rec.maxClip = clipNow end
    end
    local s = socketT(cur.body)
    if s == nil then return end
    local bi = cur.bodyInfo
    local fr = { t = clock - rec.t0, clip = clipNow, bones = readBones(cur.wmesh, cur.bones) }
    local bm, bpos = bodyMontage(cur)
    if bm ~= nil and reloadFieldOf(cur, bm) then fr.apos = bpos end
    local gm, gpos = gunMontage(cur)
    if gm ~= nil then fr.gpos = gpos end
    pcall(function() fr.l = relT(s, copyT(cur.body:GetSocketTransform(bi.l, RTS_COMPONENT))) end)
    pcall(function() fr.r = relT(s, copyT(cur.body:GetSocketTransform(bi.r, RTS_COMPONENT))) end)
    pcall(function()
        local bodyW = copyT(cur.body:K2_GetComponentToWorld())
        local p = findHandProp(s, bodyW)
        if p ~= nil then
            fr.prop = p
            if not rec.propInfo then
                rec.propInfo = true
                info(string.format("hand prop: %s %s on %s (%s hand, visible %s)", p.cls, tostring(p.asset), tostring(p.socket), p.hand, tostring(p.vis)))
            end
        end
    end)
    if #rec.frames < MAX_FRAMES then rec.frames[#rec.frames + 1] = fr end
    if clock >= rec.nextFinger then
        rec.nextFinger = clock + FINGER_EVERY
        local snap = { t = fr.t, l = {}, r = {} }
        for _, side in ipairs({ "l", "r" }) do
            local hand = nil
            pcall(function() hand = copyT(cur.body:GetSocketTransform(bi[side], RTS_COMPONENT)) end)
            if hand ~= nil then
                for _, fb in ipairs(bi.fingers[side]) do
                    pcall(function() snap[side][fb.name] = relT(hand, copyT(cur.body:GetSocketTransform(fb.f, RTS_COMPONENT))) end)
                end
            end
        end
        rec.fingers[#rec.fingers + 1] = snap
    end
    if bm ~= nil and reloadFieldOf(cur, bm) then rec.lastActive = clock end
end

local function hiddenBones()
    local out = {}
    for _, b in ipairs(cur.bones) do
        pcall(function()
            if cur.wmesh:IsBoneHiddenByName(b.f) then out[b.name] = true return end
            local sc = cur.wmesh:GetSocketTransform(b.f, RTS_COMPONENT).Scale3D
            if (sc.X or sc.x or 1) < 0.1 then out[b.name] = true end
        end)
    end
    return out
end

local function mergeProfile(res)
    local p = profiles[rec.key]
    if p == nil or relearnKey == rec.key or p.failed then p = { recorded = {} } end
    p.recorded = p.recorded or {}
    p.name = cur.display
    p.mode = cur.mode
    p.mesh = cur.meshName
    p.poolSize = cur.magSize
    p.perNotify = cur.perNotify
    p.hasEmptyReload = cur.hasEmpty
    p.records = p.records or {}
    p.records[res.empty and "empty" or "tactical"] = res
    p.recorded[res.empty and "empty" or "tactical"] = os.time()
    local function propGap(r) local g = r and r.item and r.item.grip return g and learn.dist(g.loc, { X = 0, Y = 0, Z = 0 }) or 1e9 end
    local function contains(x, y)
        if not (x and y and x.item and y.item and x.item.bones and y.item.bone) or x.item.bone == y.item.bone then return false end
        for _, n in ipairs(x.item.bones) do if n == y.item.bone then return true end end
        return false
    end
    local function pick(a, b)
        if contains(b, a) then return b end
        if contains(a, b) then return a end
        if a and a.style ~= "prop" then return a end
        if b and b.style ~= "prop" then return b end
        if a and b then return (propGap(b) < propGap(a)) and b or a end
        return a or b
    end
    local main = pick(p.records.tactical, p.records.empty)
    p.style, p.hand, p.item, p.fingers, p.perRound, p.pour, p.ammo = main.style, main.hand, main.item, main.fingers, main.perRound, main.pour, main.ammo
    p.feedSettle, p.feedSettleFirst = main.feedSettle, main.feedSettleFirst
    p.ejected = main.ejected
    p.hiddenAfter = main.hiddenAfter
    p.rack = (p.records.empty and p.records.empty.rack) or (p.records.tactical and p.records.tactical.rack) or nil
    if p.rack ~= nil and p.records.empty and p.records.empty.rack and p.records.tactical and p.records.tactical.rack
        and p.records.empty.rack.bone == p.records.tactical.rack.bone then p.rack.every = true end
    -- the rack's own bones are not openers (OW2 rackMechanisms)
    local own = {}
    if p.rack then
        own[p.rack.bone] = true
        if type(p.rack.lift) == "table" and p.rack.lift.bone then own[p.rack.lift.bone] = true end
        for _, n in ipairs(p.rack.linked or {}) do own[n] = true end
    end
    p.mechanisms = {}
    for _, m in ipairs(main.mechanisms or {}) do if not own[m.bone] then p.mechanisms[#p.mechanisms + 1] = m end end
    p.mirror = (p.hand == "right")
    profiles[rec.key] = p
    saveProfiles()
    if relearnKey == rec.key then relearnKey = nil end
    return p
end

local function endRecording()
    local hidden = hiddenBones()
    if DUMP_FRAMES and rec ~= nil then
        pcall(function()
            local names, parents = {}, {}
            for i, b in ipairs(cur.bones) do names[i] = b.name parents[i] = b.parent end
            local hl = {}
            for n in pairs(hidden) do hl[#hl + 1] = n end
            json.dump_file("cronos_reload_frames_" .. rec.key:gsub("[|%s]", "_") .. "_" .. (rec.empty and "empty" or "tactical") .. ".json",
                { gun = cur.display, key = rec.key, bones = names, parents = parents, rest = rec.rest, frames = rec.frames,
                  fingers = rec.fingers, hiddenAtEnd = hl, field = rec.field }, 0)
        end)
    end
    local ok, res, why = pcall(learn.analyze, { bones = cur.bones, byName = cur.byName, rest = rec.rest, frames = rec.frames,
        fingers = rec.fingers, empty = rec.empty, hasEmpty = cur.hasEmpty, key = rec.key, hiddenAtEnd = hidden,
        perNotify = cur.perNotify, profiles = profiles, info = info })
    if not ok then
        info("analysis error: " .. tostring(res))
    elseif res == nil then
        info("no profile from this reload of " .. cur.display .. ": " .. tostring(why))
        -- remember a failure so the mode is not recorded again every reload (re-learn retries it); a recording without
        -- ammo (cancelled, shot) is not a failure
        if why ~= "no ammo landed (cancelled?)" and why ~= "too short" then
            local p = profiles[rec.key]
            if p == nil or p.item == nil then
                profiles[rec.key] = { failed = why, name = cur.display, mode = cur.mode, mesh = cur.meshName, recorded = {} }
                saveProfiles()
            end
        end
    else
        local p = mergeProfile(res)
        info(cur.display .. " learned (" .. (res.empty and "empty" or "tactical") .. "): " .. profileSummary(p))
        if res.item and res.item.bone then
            detail(string.format("  item %s, grip %s via %s %.2f-%.2f s, rest %s, approach depth %s axis %s",
                res.item.bone, res.item.grip and fmtV(res.item.grip.loc) or "-", res.item.gripSource or "?",
                res.item.gripT[1], res.item.gripT[2], res.item.rest and fmtV(res.item.rest.loc) or "-",
                tostring(res.item.depth), res.item.axis and fmtV(res.item.axis) or "-"))
            for _, g in ipairs(res.item.group or {}) do detail("  rides with the item: " .. g.bone) end
        elseif res.item and res.item.prop then
            detail("  prop " .. tostring(res.item.prop.asset) .. ", dock " .. (res.item.dock and fmtV(res.item.dock.loc) or "-"))
        end
        if res.rack then detail(string.format("  rack %s travel %.2f hand %s", res.rack.bone, res.rack.travel or 0, tostring(res.rack.hand))) end
        for _, m in ipairs(res.mechanisms or {}) do
            detail(string.format("  mechanism %s %.1f deg %.2f cm%s", m.bone, m.maxDeg or 0, m.maxCm or 0, m.opener and " (opener)" or ""))
        end
        detail("  ammo at " .. table.concat(res.ammo, ", ") .. (res.perRound and " (per round)" or ""))
    end
    rec = nil
    updateStatus()
end

-- -------------------------------------------------------------------------------------------------------------------
-- tick
-- -------------------------------------------------------------------------------------------------------------------
-- The key must belong to a settled mode: on a switch the container changes before the mesh does, so a new
-- (mode, mesh) pair is only taken after it has held for 0.3 s
local pendingKey, pendingSince = nil, 0
local function stableKey(c)
    if cur ~= nil and c.key == cur.key then pendingKey = nil return true end
    if c.key ~= pendingKey then pendingKey, pendingSince = c.key, clock return false end
    return clock - pendingSince >= 0.3
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    clock = clock + (delta or 0)
    local c = gameContext(getPawn())
    if c == nil then
        if rec ~= nil then rec = nil end
        if cur ~= nil then cur = nil updateStatus() end
        releaseBody()
        return
    end
    if cur == nil or cur.key ~= c.key or cur.wmesh ~= c.wmesh or cur.container ~= c.container then
        if rec ~= nil then
            -- the mode changed while recording: drop it
            info("recording dropped: the weapon mode changed")
            rec = nil
        end
        if not stableKey(c) then return end
        setupWeapon(c)
    else
        cur.pawn, cur.body = c.pawn, c.body
    end
    if rec ~= nil then
        holdBody(cur.body)
        local ok, err = pcall(recordFrame)
        if not ok then info("record error: " .. tostring(err)) rec = nil updateStatus() return end
        if rec.fired or clock - rec.lastActive > END_TAIL then endRecording() end
        return
    end
    local clip = getClip(cur)
    local wants = needsRecording(clip)
    -- keep the hidden body's bones fresh while a recording may start (the reload's first frames)
    if wants then holdBody(cur.body) else releaseBody() end
    local bm = bodyMontage(cur)
    local field = bm ~= nil and reloadFieldOf(cur, bm) or nil
    if field ~= nil and not cur.lastReload then
        cur.lastReload = true
        detail("reload montage " .. shortName(bm) .. " (" .. field .. "), clip " .. tostring(clip) .. ", needs recording " .. tostring(wants))
        if wants and not _G.cronosManualReloadBusy then
            startRecording(field)
            pcall(recordFrame)
            return
        end
    elseif field == nil then
        cur.lastReload = false
    end
    -- idle: keep the rest pose current (not while a reload / manual reload runs)
    if field == nil and clock >= cur.nextRest and not _G.cronosManualReloadBusy then
        cur.nextRest = clock + REST_REFRESH
        cur.rest = readBones(cur.wmesh, cur.bones)
    end
end)

uevrUtils.registerPreLevelChangeCallback(function()
    rec, cur = nil, nil
    animCache, montageCache = {}, {}
    bodyHeld = nil
end)

uevr.sdk.callbacks.on_script_reset(function() releaseBody() end)

configui.onUpdate("mr_auto_relearn", function()
    uevrUtils.setTimeout(1, function()
        if cur == nil or cur.key == nil then setStatus("no gun") return end
        relearnKey = cur.key
        if profiles[cur.key] ~= nil and profiles[cur.key].failed then profiles[cur.key] = nil end
        setStatus(cur.display .. ": re-learning - do a normal reload (with rounds left, then from empty)")
        info("re-learn requested for " .. cur.key)
    end)
end)

_G.cronosReloadAnalyzer = {
    getProfile = function()
        if cur == nil then return nil end
        local p = profiles[cur.key]
        if p ~= nil and p.item ~= nil then return p end
        return nil
    end,
    keyFor = function() return cur ~= nil and cur.key or nil end,
    -- the analyzer's live context (pawn, body, gun, wmesh, container, ammo, mode, key, display, hasEmpty, magSize, perNotify)
    context = function() return cur end,
    isRecording = function() return rec ~= nil end,
    -- does the analyzer want the reload that is starting (not learned / empty variant missing / re-learn pending)?
    wantsReload = function()
        if rec ~= nil then return true end
        if cur == nil then return false end
        return needsRecording(getClip(cur))
    end,
    relearn = function() if cur ~= nil then relearnKey = cur.key end end,
    -- the body montage playing now, and the reload field it plays (or nil)
    reloadMontage = function()
        if cur == nil then return nil end
        local m, pos = bodyMontage(cur)
        if m == nil then return nil end
        return m, reloadFieldOf(cur, m), pos
    end,
    gunMontage = function() if cur == nil then return nil end return gunMontage(cur) end,
    profiles = function() return profiles end,
}

info("loaded, " .. (function() local n = 0 for _ in pairs(profiles) do n = n + 1 end return n end)() .. " weapon mode profiles")
