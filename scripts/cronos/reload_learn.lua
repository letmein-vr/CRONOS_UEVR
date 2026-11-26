-- Cronos manual reload: the reload analysis itself (2026-11-26). Pure Lua (no game access), so it also runs offline on
-- recorded frames. Port of the Borderlands 4 / Outer Worlds 2 analysis (bl4_vr_reload_analyzer.lua analyze()); the
-- analysis rules are unchanged, the inputs come from scripts/reload_analyzer.lua:
--   ctx = { bones = { {name, parent, index} }, byName, rest = { [i] = {loc,q} }, frames = { {t, clip, bones, l, r, prop} },
--           fingers = { {t, l = {name -> T}, r = {...}} }, empty, hasEmpty, key, hiddenAtEnd = { [bone] = true },
--           profiles (for prop grip donors), info = function(s) }
-- All poses are in the gun's component space = the body's hand_r_socket frame (the flat game hangs the gun there with
-- zero relative). M.analyze(ctx) returns res (see the BL4 analyzer for its fields) or nil, why.
local M = {}
local cur, rec, ctxProfiles
local info = function(s) end
local RACK_HAND_CM = 12.0      -- Cronos: a rack is worked by a hand this close (handgun GG_bolt_r: the hand stays 17-19 cm off, the bolt moves by itself)

-- rack parts the hand rides stay on it (slide 7.7, bolt 8.6, AR lever 10.1) - 5 cm picked the pistol slide
local ITEM_MIN_TRAVEL = 15.0
local RACK_MIN_TRAVEL = 2.0    -- cm
local RACK_MIN_DEG = 20.0      -- rotary rack (charging handle swinging about a pivot)
local PROP_MAX_GRIP = 15.0     -- cm: a prop farther from the hand than this is parked, not held
local CRANK_MIN_DEG = 200.0    -- crank: a part wound past half a turn in one go (Anti-Matter Plasma Rifle 446 deg)
local MECH_MIN_DEG = 15.0
local MECH_MIN_CM = 1.0
-- a part that swings open for the reload (Maliwan sniper Body_Break_Open turns only 25 deg; 30 skipped it, 2026-11-23)
local OPENER_MIN_DEG = 20
local SEATED_CM = 0.3
local APPROACH_MAX_CM = 12.0
local POUR_GAP = 0.12          -- s: ammo steps closer than this are a pour, not separate inserts
-- -------------------------------------------------------------------------------------------------------------------
-- math (tables {X,Y,Z} / {X,Y,Z,W}; UE quaternion convention)
-- -------------------------------------------------------------------------------------------------------------------
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
local function qangle(a, b)
    local d = math.abs(a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W)
    if d > 1 then d = 1 end
    return math.deg(2 * math.acos(d))
end
local function vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function vlen(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function dist(a, b) return vlen(vsub(a, b)) end
local function vnorm(v)
    local l = vlen(v)
    if l < 1e-6 then return { X = 0, Y = 0, Z = 0 } end
    return { X = v.X / l, Y = v.Y / l, Z = v.Z / l }
end
-- b expressed in a's frame (both {loc, q} in the same space)
local function relT(a, b)
    local inv = qconj(a.q)
    return { loc = qrot(inv, vsub(b.loc, a.loc)), q = qmul(inv, b.q) }
end
local function copyT(t)
    return {
        loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
        q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
    }
end
local function r3(n) return math.floor(n * 1000 + 0.5) / 1000 end
local function packT(t)
    if t == nil then return nil end
    return { loc = { X = r3(t.loc.X), Y = r3(t.loc.Y), Z = r3(t.loc.Z) },
             q = { X = r3(t.q.X), Y = r3(t.q.Y), Z = r3(t.q.Z), W = r3(t.q.W) } }
end
local function fmtV(v) return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z) end
local MAG_WORDS = { "mag", "clip", "cell", "battery", "breech", "cylinder", "speedloader", "canister", "bag", "drum", "shell", "bullet", "round" }

local function magLike(s)
    s = (s or ""):lower()
    for _, w in ipairs(MAG_WORDS) do if s:find(w, 1, true) then return true end end
    return false
end

-- cables, straps, wires and chains swing during reloads (Daedalus pistol L/R_Cable_Btm, 120 deg) - never a rack or a
-- mechanism; nor are IK reference bones
local function cosmeticBone(s)
    s = (s or ""):lower()
    for _, w in ipairs({ "cable", "strap", "wire", "chain", "_ref", "aux", "trigger", "_vfx", "morph" }) do if s:find(w, 1, true) then return true end end
    return false
end
local function subtreeOf(rootName)
    local out, set = {}, {}
    set[rootName] = true
    out[#out + 1] = rootName
    local grew = true
    while grew do
        grew = false
        for _, b in ipairs(cur.bones) do
            if not set[b.name] and set[b.parent] then set[b.name] = true out[#out + 1] = b.name grew = true end
        end
    end
    return out, set
end

local function isAncestor(anc, name)
    local b = cur.byName[name]
    while b ~= nil and b.parent ~= "None" do
        if b.parent == anc then return true end
        b = cur.byName[b.parent]
    end
    return false
end

-- per bone: max travel / rotation from rest, and whether it is back at rest at the end
local function boneMotion(frames, rest)
    local out = {}
    for i, b in ipairs(cur.bones) do
        local r = rest[i]
        -- bones of part variants this gun does not have: the animation moves them too, but they draw nothing
        if cur.unfitted ~= nil and cur.unfitted[b.name] then r = nil end
        local m = { maxD = 0, maxA = 0, tD = 0, iD = nil, iA = nil, endRest = true, startOff = false }
        if r ~= nil then
            for fi, fr in ipairs(frames) do
                local t = fr.bones[i]
                if t ~= nil then
                    local d, a = dist(t.loc, r.loc), qangle(t.q, r.q)
                    if d > m.maxD then m.maxD, m.iD = d, fi end
                    if a > m.maxA then m.maxA, m.iA = a, fi end
                end
            end
            local first, last = frames[1] and frames[1].bones[i], frames[#frames] and frames[#frames].bones[i]
            if last ~= nil then m.endRest = dist(last.loc, r.loc) < 0.5 and qangle(last.q, r.q) < 3 end
            if first ~= nil then m.startOff = dist(first.loc, r.loc) > 1.0 end
        end
        out[i] = m
    end
    return out
end

-- longest run where hand-in-bone is constant while bone and hand both travel relative to the gun
local function gripWindow(frames, bi, hk, rest)
    local best, run, prev, prevF = nil, nil, nil, nil
    for _, fr in ipairs(frames) do
        local bt, h = fr.bones[bi], fr[hk]
        local rel = (bt and h) and relT(bt, h) or nil
        local off = bt and rest[bi] and dist(bt.loc, rest[bi].loc) > 1.0
        local steady = rel and prev and off and dist(rel.loc, prev.loc) < 0.4 and qangle(rel.q, prev.q) < 3.0
        if steady then
            if run == nil then run = { t0 = fr.t, n = 0, sum = { X = 0, Y = 0, Z = 0 }, bPath = 0, hPath = 0 } end
            run.n = run.n + 1
            run.t1 = fr.t
            run.sum = { X = run.sum.X + rel.loc.X, Y = run.sum.Y + rel.loc.Y, Z = run.sum.Z + rel.loc.Z }
            run.q = rel.q
            if prevF ~= nil and prevF.bones[bi] and prevF[hk] then
                run.bPath = run.bPath + dist(bt.loc, prevF.bones[bi].loc)
                run.hPath = run.hPath + dist(h.loc, prevF[hk].loc)
            end
            if run.bPath > 2 and run.hPath > 2 and (best == nil or run.n > best.n) then best = run end
        else
            run = nil
        end
        prev, prevF = rel, fr
    end
    if best == nil or best.n < 3 then return nil end
    return { t0 = best.t0, t1 = best.t1, n = best.n, hand = hk,
             T = { loc = { X = best.sum.X / best.n, Y = best.sum.Y / best.n, Z = best.sum.Z / best.n }, q = best.q } }
end

local function ammoSteps(frames)
    local steps, last = {}, frames[1] and frames[1].clip
    for _, fr in ipairs(frames) do
        if fr.clip ~= nil and last ~= nil and fr.clip > last then steps[#steps + 1] = { t = fr.t, from = last, to = fr.clip } end
        if fr.clip ~= nil then last = fr.clip end
    end
    return steps
end

local function fingerPoseAt(t, side)
    local best, bestD = nil, 1e9
    for _, s in ipairs(rec.fingers) do
        local d = math.abs(s.t - t)
        if d < bestD then best, bestD = s, d end
    end
    if best == nil then return nil end
    local out = {}
    for name, T in pairs(best[side]) do out[name] = packT(T) end
    return out
end

-- seat frame = the first frame (after the item was away) where the item is back at rest; approach = the earliest
-- frame of the continuous final stretch within APPROACH_MAX_CM of the seat
local strokeInto
local function insertPath(frames, bi, rest, afterT)
    local r = rest[bi]
    local away, seat = false, nil
    for fi, fr in ipairs(frames) do
        local t = fr.bones[bi]
        if t ~= nil and fr.t >= (afterT or 0) then
            local d = dist(t.loc, r.loc)
            if d > 1.0 then away = true end
            if away and d < SEATED_CM then seat = fi break end
        end
    end
    -- BL4 (2026-11-23, Order pistol): the cube seats at 0.87 s (0.7 cm) and then creeps the last millimetres until
    -- 1.1 s, so the 0.3 cm test found the seat 0.25 s late and the grip came from a frame where the hand had already
    -- left. Seated = the first frame within 1 cm that stays within 1 cm from then on.
    do
        local away2, cand = false, nil
        for fi, fr in ipairs(frames) do
            local t = fr.bones[bi]
            if t ~= nil and fr.t >= (afterT or 0) then
                local d = dist(t.loc, r.loc)
                if d > 1.0 then away2 = true cand = nil
                elseif away2 and cand == nil then cand = fi end
            end
        end
        if cand ~= nil and (seat == nil or cand < seat) then seat = cand end
    end
    if seat == nil then return nil end
    return strokeInto(frames, bi, r, seat)
end

-- the final insert stroke into target (a pose) ending at frame seat: its direction comes from the first frame back
-- that is > 1.5 cm out; walk back while the item stays in line with that stroke (the hand's earlier swing toward the
-- gun is not part of the insert)
strokeInto = function(frames, bi, r, seat)
    local ref = nil
    for k = seat - 1, 1, -1 do
        local t = frames[k].bones[bi]
        if t == nil then break end
        if dist(t.loc, r.loc) > 1.5 then ref = vnorm(vsub(r.loc, t.loc)) break end
    end
    local a = seat - 1
    while a > 1 do
        local t, tp = frames[a].bones[bi], frames[a - 1].bones[bi]
        if t == nil or tp == nil then break end
        -- the game snaps the last few cm in one frame (pistol: 5 cm), so allow jumps up to 8 cm
        if dist(tp.loc, r.loc) > APPROACH_MAX_CM or dist(tp.loc, t.loc) > 8.0 then break end
        -- in line with the stroke, beyond 1.5 cm (the distance that defines the stroke direction): the Beam Caster's
        -- battery wobbles 0.5-0.8 cm around its seat before settling, and those sub-cm steps point anywhere
        if ref ~= nil and dist(tp.loc, r.loc) > 1.5 then
            local d = vnorm(vsub(r.loc, tp.loc))
            local c = d.X * ref.X + d.Y * ref.Y + d.Z * ref.Z
            if c < math.cos(math.rad(15)) then break end
        end
        a = a - 1
    end
    local at = frames[a].bones[bi]
    local depth = dist(at.loc, r.loc)
    return { seatT = frames[seat].t, approach = at, depth = depth, axis = vnorm(vsub(r.loc, at.loc)) }
end

-- Cronos guns whose reload has no carried part (2026-11-26):
--   * shell guns (SpreadGun): the game's hand pushes shells into the bottom loading window with no shell object at all
--     (no gun bone moves, no mesh near the hand) and each push counts one round;
--   * single-shot guns (Annihilator / Arbalest, magazine 1): the spent bolt AnnG_ammo_01 is flung away and hidden, the
--     loaded bolt AnnG_ammo_02 slides back to the rear-top and forward into its track, the hand only works above it.
-- The round = the gun's own round bone (ammo / shell / round / bullet / cartridge) nearest the loading hand when the
-- count lands, measured where the bone IS at that moment (the Arbalest's two bolts share one rest spot). It seats at its
-- rest. Shells: pushed in along the hand's motion over the 0.2 s before the count, held where the hand was at the count.
-- Single shot: pushed from where the bone sat at the count into its rest (laid in from the rear, slid forward), held
-- where the hand came nearest it before the count; no drop at the reload start (the round was fired).
local SHELL_WORDS = { "ammo", "shell", "round", "bullet", "cartridge" }
local function cronosShell(res, frames, rest, steps)
    local NONE = "no carried item found"
    if steps[1] == nil then return nil, NONE end
    local ks, fs = nil, nil
    for k, f in ipairs(frames) do if f.t >= steps[1].t - 0.001 then ks, fs = k, f break end end
    if fs == nil then return nil, NONE end
    local function travel(hk)
        local tot, prev = 0, nil
        for _, f in ipairs(frames) do
            if f[hk] ~= nil and f.t >= fs.t - 0.6 and f.t <= fs.t then
                if prev ~= nil then tot = tot + dist(prev, f[hk].loc) end
                prev = f[hk].loc
            end
        end
        return tot
    end
    local hk = travel("l") >= travel("r") and "l" or "r"
    local h = fs[hk]
    if h == nil then return nil, NONE end
    local pick, pd = nil, 1e9
    for i, b in ipairs(cur.bones) do
        local n = b.name:lower()
        local roundy = false
        for _, w in ipairs(SHELL_WORDS) do if n:find(w, 1, true) then roundy = true end end
        local at = fs.bones[i] or rest[i]
        if roundy and not n:find("door", 1, true) and not n:find("unused", 1, true) and rest[i] ~= nil and at ~= nil then
            local d = dist(at.loc, h.loc)
            if d < pd then pick, pd = i, d end
        end
    end
    if pick == nil or pd > 30 then return nil, NONE end
    local seat = rest[pick]
    local single = not res.perRound
    local dir, depth, gripF = nil, 6.0, fs
    if single then
        -- from where the round sat at the count into its rest
        local at = fs.bones[pick] or seat
        local off = vsub(seat.loc, at.loc)
        if vlen(off) > 3.0 then
            dir = vnorm(off)
            depth = math.min(10.0, vlen(off))
        end
        -- the hand's nearest approach to the round in the 0.8 s before the count
        local bd = 1e9
        for k, f in ipairs(frames) do
            if f.t >= fs.t - 0.8 and f.t <= fs.t and f[hk] ~= nil and f.bones[pick] ~= nil then
                local d = dist(f[hk].loc, f.bones[pick].loc)
                if d < bd then bd, gripF = d, f end
            end
        end
    end
    if dir == nil then
        local k0 = ks
        while k0 > 1 and frames[k0 - 1].t >= fs.t - 0.2 do k0 = k0 - 1 end
        local h0 = frames[k0][hk]
        dir = h0 ~= nil and vsub(h.loc, h0.loc) or { X = 0, Y = 0, Z = 1 }
        if vlen(dir) < 1.0 then dir = { X = 0, Y = 0, Z = 1 } end
        dir = vnorm(dir)
    end
    local approach = { loc = { X = seat.loc.X - dir.X * depth, Y = seat.loc.Y - dir.Y * depth, Z = seat.loc.Z - dir.Z * depth }, q = seat.q }
    local names = subtreeOf(cur.bones[pick].name)
    local itemAtGrip = (single and gripF.bones[pick]) or seat
    res.item = { bone = cur.bones[pick].name, bones = names, grip = packT(relT(itemAtGrip, gripF[hk])), gripSource = single and "single" or "shell",
                 gripT = { r3(gripF.t), r3(gripF.t) }, rest = packT(seat), seat = packT(seat), docked = not single, noDrop = single or nil,
                 approach = packT(approach), depth = r3(depth), axis = { X = r3(dir.X), Y = r3(dir.Y), Z = r3(dir.Z) },
                 seatT = r3(steps[1].t), keepVisible = true }
    res.hand = hk == "l" and "left" or "right"
    res.fingers = fingerPoseAt(gripF.t, hk)
    res.style = single and "item" or "rounds"
    info(string.format("%s: round %s (%.1f cm from the %s hand at the count), pushed along (%.2f, %.2f, %.2f) %.1f cm, grip %.1f cm",
        single and "single shot" or "shell gun", cur.bones[pick].name, pd, res.hand, dir.X, dir.Y, dir.Z, depth, vlen(res.item.grip.loc)))
    return res
end

local function analyze()
    local frames, rest = rec.frames, rec.rest
    if #frames < 5 then return nil, "too short" end
    local steps = ammoSteps(frames)
    if #steps == 0 then return nil, "no ammo landed (cancelled?)" end
    local motion = boneMotion(frames, rest)
    local res = { empty = rec.empty, ammo = {}, mechanisms = {} }
    for _, s in ipairs(steps) do res.ammo[#res.ammo + 1] = r3(s.t) end
    local gaps, pour = {}, false
    for i = 2, #steps do gaps[#gaps + 1] = steps[i].t - steps[i - 1].t end
    for _, g in ipairs(gaps) do if g < POUR_GAP then pour = true end end
    res.perRound = (#steps >= 2 and not pour) or (rec.perNotify ~= nil and rec.perNotify > 0)
    res.pour = pour

    -- the carried item: the longest steady-grip window over bones that travelled far
    local best = nil
    for i, b in ipairs(cur.bones) do
        if motion[i].maxD >= ITEM_MIN_TRAVEL then
            for _, hk in ipairs({ "l", "r" }) do
                local w = gripWindow(frames, i, hk, rest)
                if w ~= nil then
                    w.bi = i
                    if best == nil or w.n > best.n then best = w end
                end
            end
        end
    end
    -- prefer an ancestor that is carried nearly as long (Magazine_JNT over its bullets)
    if best ~= nil then
        local changed = true
        while changed do
            changed = false
            local parent = cur.byName[cur.bones[best.bi].parent]
            if parent ~= nil and motion[parent.index].maxD >= ITEM_MIN_TRAVEL then
                local w = gripWindow(frames, parent.index, best.hand, rest)
                if w ~= nil and w.n >= best.n * 0.8 then w.bi = parent.index best = w changed = true end
            end
        end
    end
    local gripSource = "window"
    if best == nil then
        -- fallback: magazine-like bone with the most travel, hand pose at the last frame before it seats
        local pick, pickD = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if m.maxD >= ITEM_MIN_TRAVEL and (magLike(b.name) or b.name:lower():find("bullet", 1, true) or b.name:lower():find("rocket", 1, true)) then
                local parent = cur.byName[b.parent]
                local parentMoves = parent ~= nil and motion[parent.index].maxD >= ITEM_MIN_TRAVEL
                if not parentMoves and m.maxD > pickD then pick, pickD = i, m.maxD end
            end
        end
        if pick ~= nil then
            local path = insertPath(frames, pick, rest)
            local fi = nil
            if path ~= nil then
                for k, fr in ipairs(frames) do if fr.t >= path.seatT then fi = math.max(1, k - 1) break end end
            end
            fi = fi or #frames
            local fr = frames[fi]
            local bt = fr.bones[pick]
            -- the carrying hand: the one that stays closest to the item over its whole trip off the gun (mean
            -- distance), not at one frame - the rocket pistol's right hand on the grip is closer to the rocket's rear
            -- in the last frame before the seat, while the left hand brings it
            local sum, cnt = { l = 0, r = 0 }, 0
            local seatT = path and path.seatT or math.huge
            for _, f2 in ipairs(frames) do
                local b2 = f2.bones[pick]
                if b2 ~= nil and f2.t < seatT and f2.l ~= nil and f2.r ~= nil and dist(b2.loc, rest[pick].loc) > 1.0 then
                    sum.l, sum.r, cnt = sum.l + dist(f2.l.loc, b2.loc), sum.r + dist(f2.r.loc, b2.loc), cnt + 1
                end
            end
            local hk
            if cnt > 0 then
                hk = sum.l <= sum.r and "l" or "r"
            else
                local dl = (fr.l and bt) and dist(fr.l.loc, bt.loc) or 1e9
                local dr = (fr.r and bt) and dist(fr.r.loc, bt.loc) or 1e9
                hk = dl <= dr and "l" or "r"
            end
            if bt ~= nil and fr[hk] ~= nil then
                -- the grip is the hand on the item as it seats; the window is the item's trip off the gun (t0 = when it
                -- leaves). t0 = the seat frame made the insert-path search start after the seat and find nothing
                -- (Kinetic Beam Caster, 2026-11-19)
                local t0 = fr.t
                for _, f2 in ipairs(frames) do
                    local b2 = f2.bones[pick]
                    if b2 ~= nil and f2.t < fr.t and dist(b2.loc, rest[pick].loc) > 1.0 then t0 = f2.t break end
                end
                best = { bi = pick, hand = hk, t0 = t0, t1 = fr.t, n = 1, T = relT(bt, fr[hk]) }
                gripSource = "closest"
                -- BL4 (2026-11-23, Order pistol): the item can spin in the hand (the cube turns ~100 deg a frame), so there is
                -- no steady window, and the frame before the seat can have the hand already leaving (18.6 cm). Grip and
                -- fingers come from the frame where the carrying hand is NEAREST the item during its trip (10.9 cm).
                local kN, dN = nil, 1e9
                for k, f2 in ipairs(frames) do
                    local b2, h2 = f2.bones[pick], f2[hk]
                    if b2 ~= nil and h2 ~= nil and f2.t < seatT and dist(b2.loc, rest[pick].loc) > 1.0 then
                        local dd = dist(h2.loc, b2.loc)
                        if dd < dN then kN, dN = k, dd end
                    end
                end
                if kN ~= nil then
                    best.T = relT(frames[kN].bones[pick], frames[kN][hk])
                    best.fingerT = frames[kN].t
                    gripSource = "nearest"
                end
            end
        end
    end

    -- a hand prop (cell, canister, rod)
    local propFrames = {}
    for _, fr in ipairs(frames) do if fr.prop ~= nil then propFrames[#propFrames + 1] = fr end end

    local itemSet = {}
    if best ~= nil then
        local item = cur.bones[best.bi]
        local names, set = subtreeOf(item.name)
        itemSet = set
        local path = insertPath(frames, best.bi, rest, best.t0)
        res.item = { bone = item.name, bones = names, grip = packT(best.T), gripSource = gripSource,
                     gripT = { r3(best.t0), r3(best.t1) }, rest = packT(rest[best.bi]) }
        -- dock: where the item sits when the first ammo lands, when that is not its rest (the Heavy Revolver's
        -- speedloader rests stowed inside the grip and docks behind the open cylinder). The seat target becomes the
        -- dock, the insert stroke is measured into it.
        do
            local fa = nil
            for k, fr in ipairs(frames) do if fr.t >= steps[1].t - 0.001 then fa = k break end end
            local bt = fa and frames[fa].bones[best.bi]
            -- docked only if the item never slides on into its rest after the ammo landed (it leaves / teleports to a
            -- stowed rest): the heavy MG's magazine is 1.6 cm short of its seat when the ammo lands and then settles
            -- in - that is a magazine, not a dock (it got no drop copy, 2026-11-19)
            local slidesHome = false
            if bt ~= nil then
                local prev = bt
                for k = fa + 1, #frames do
                    local t = frames[k].bones[best.bi]
                    if t == nil then break end
                    if dist(t.loc, prev.loc) > 6.0 then break end -- a jump: left the gun / teleported
                    if dist(t.loc, rest[best.bi].loc) < SEATED_CM then slidesHome = true break end
                    prev = t
                end
            end
            if bt ~= nil and not slidesHome and dist(bt.loc, rest[best.bi].loc) > 1.5 then
                local ps = fa
                while ps > 1 and frames[ps - 1].bones[best.bi] ~= nil and dist(frames[ps - 1].bones[best.bi].loc, bt.loc) < 0.4 do ps = ps - 1 end
                local dpath = strokeInto(frames, best.bi, bt, ps)
                res.item.seat = packT(bt)
                res.item.docked = true
                path = dpath
                if path ~= nil then path.seatT = frames[ps].t end
            end
        end
        if path ~= nil then
            res.item.approach = packT(path.approach)
            res.item.depth = r3(path.depth)
            res.item.axis = { X = r3(path.axis.X), Y = r3(path.axis.Y), Z = r3(path.axis.Z) }
            res.item.seatT = r3(path.seatT)
        end
        res.hand = best.hand == "l" and "left" or "right"
        res.fingers = fingerPoseAt(best.fingerT or ((best.t0 + best.t1) / 2), best.hand)
        -- the item's pose (gun space) while the hand holds it: a right-hand grip is mirrored onto the left hand across
        -- the gun's centre plane THROUGH this pose (2026-11-23, Jakobs pistol cap: held turned 180 deg + broken 55 deg;
        -- mirrored about its rest pose the left hand landed beside the cap instead of at its base)
        do
            local tg = best.fingerT or ((best.t0 + best.t1) / 2)
            local kg, dg = nil, 1e9
            for k, f2 in ipairs(frames) do
                local dd = math.abs(f2.t - tg)
                if f2.bones[best.bi] ~= nil and dd < dg then kg, dg = k, dd end
            end
            if kg ~= nil then res.item.gripPose = packT(frames[kg].bones[best.bi]) end
        end
        -- round by round: every cycle the hand picks a round with the fingers wrapped, then opens them while the thumb
        -- pushes it in (the round slides in the fingers, so no steady window holds the real grip). Grip + fingers come
        -- from the frame where the hand is nearest the round while it is carried (Holographic Repeating Rifle
        -- 2026-11-19: window 0.34-0.50 s = index 216 deg, "fingers too wide"; nearest 1.82 s, 5.1 cm = index 314 deg)
        if res.perRound then
            local hk = best.hand
            local bestK, bestD = nil, 1e9
            for k, f2 in ipairs(frames) do
                local t, h = f2.bones[best.bi], f2[hk]
                if t ~= nil and h ~= nil and dist(t.loc, rest[best.bi].loc) > 1.0 then
                    local d = dist(h.loc, t.loc)
                    if d < bestD then bestK, bestD = k, d end
                end
            end
            if bestK ~= nil then
                local f2 = frames[bestK]
                res.item.grip = packT(relT(f2.bones[best.bi], f2[hk]))
                res.item.gripSource = "nearest"
                res.item.gripT = { r3(f2.t), r3(f2.t) }
                res.fingers = fingerPoseAt(f2.t, hk)
            end
        end
        -- BL4: the rig carries bones for every magazine variant (Magazine01, Magazine02 ...) and the animation moves them
        -- together; only the fitted part has geometry, and which bone it skins to is not exposed. Every bone outside the
        -- item's subtree that rides rigidly with the item for the whole reload (and travels) belongs to it: manual reload
        -- moves this group with the item, so the fitted magazine follows whichever bone it is on.
        do
            local group = {}
            local ib = best.bi
            -- rounds / parts that ride with the item just before it goes in (Jakobs Mag01: the cylinder rounds
            -- Mag01_Bullet01-04 are ejected as cases first, sit in the speedloader 0.78-1.02 s, then enter the cylinder
            -- before the ammo counts at 1.19 s): per bone, the longest run of >= 4 frames with a constant offset to the item
            -- (< 20 cm) that ends in the last 0.45 s before the first ammo / the seat; the offset is that run's
            local tEnd = res.item.seatT
            if steps[1] ~= nil and (tEnd == nil or steps[1].t < tEnd) then tEnd = steps[1].t end
            tEnd = tEnd or (frames[#frames] and frames[#frames].t) or 0
            for i, b in ipairs(cur.bones) do
                if not itemSet[b.name] and not (cur.unfitted and cur.unfitted[b.name]) and motion[i].maxD >= ITEM_MIN_TRAVEL then
                    local bestRun, run = nil, nil
                    for _, fr in ipairs(frames) do
                        if fr.t > tEnd then break end
                        local a, c = fr.bones[ib], fr.bones[i]
                        local r = (a ~= nil and c ~= nil) and relT(a, c) or nil
                        if r ~= nil and vlen(r.loc) <= 20 and run ~= nil and dist(r.loc, run.ref.loc) <= 0.5 and qangle(r.q, run.ref.q) <= 3 then
                            run.n, run.t1 = run.n + 1, fr.t
                        else
                            run = (r ~= nil and vlen(r.loc) <= 20) and { ref = r, n = 1, t0 = fr.t, t1 = fr.t, a0 = a.loc } or nil
                        end
                        -- the item must travel during the run: a still item makes every nearby gun part look attached
                        if run ~= nil and run.n >= 4 and run.t1 >= tEnd - 0.45 and a ~= nil and dist(a.loc, run.a0) > 2.0
                            and (bestRun == nil or run.n >= bestRun.n) then bestRun = run end
                    end
                    if bestRun ~= nil then group[#group + 1] = { i = i, rel = bestRun.ref, t1 = bestRun.t1 } end
                end
            end
            -- top bones of the group only (a child follows its parent)
            local inGroup = {}
            for _, g in ipairs(group) do inGroup[cur.bones[g.i].name] = true end
            local tops = {}
            for _, g in ipairs(group) do
                local b = cur.bones[g.i]
                local anc, under = cur.byName[b.parent], false
                while anc ~= nil do
                    if inGroup[anc.name] then under = true break end
                    anc = cur.byName[anc.parent]
                end
                if not under then
                    local names2 = subtreeOf(b.name)
                    for _, n2 in ipairs(names2) do itemSet[n2] = true end
                    tops[#tops + 1] = { bone = b.name, rel = packT(g.rel) }
                end
            end
            if #tops > 0 then res.item.group = tops end
            -- a docked item whose dock is nowhere near the gun (Jakobs Mag01: the speedloader is whisked back to its
            -- parked spot 80 cm above the gun right after its rounds go in, and only then does the ammo count): it docks
            -- where its rounds leave it - the end of their ride - and the insert stroke is measured into that pose
            if #group > 0 and res.item.docked and res.item.seat ~= nil and res.item.rest ~= nil
                and dist(res.item.seat.loc, res.item.rest.loc) > 25 then
                local tDock = 0
                for _, g in ipairs(group) do if g.t1 ~= nil and g.t1 > tDock then tDock = g.t1 end end
                local kDock = nil
                for k, fr in ipairs(frames) do if math.abs(fr.t - tDock) < 1e-4 then kDock = k break end end
                if kDock ~= nil and frames[kDock].bones[ib] ~= nil then
                    local bt = frames[kDock].bones[ib]
                    local dpath = strokeInto(frames, ib, bt, kDock)
                    res.item.seat = packT(bt)
                    if dpath ~= nil then
                        res.item.approach = packT(dpath.approach)
                        res.item.depth = r3(dpath.depth)
                        res.item.axis = { X = r3(dpath.axis.X), Y = r3(dpath.axis.Y), Z = r3(dpath.axis.Z) }
                    end
                    res.item.seatT = r3(tDock)
                    info(string.format("dock moved to where the item's rounds leave it: %.2f s, (%.1f, %.1f, %.1f)", tDock, bt.loc.X, bt.loc.Y, bt.loc.Z))
                end
            end
            -- an item PARKED at its rest (2026-11-23, Jakobs AR stripper clip: at idle it sits 20 cm beside the gun at scale
            -- 0.001; the reload brings it into the action, holds it there 0.35-1.04 s while the rounds go down, and puts it
            -- back in the park before the ammo counts - the seat came out as the invisible park spot): hidden at rest after
            -- the reload (hidden flag or near-zero scale) = parked; it docks at its longest still stretch away from the park
            -- before the first ammo (>= 0.25 s), and the insert stroke is measured into that pose
            -- (also when an earlier rule docked it at the park: Vladof AR speed feed, 2026-11-23)
            if steps[1] ~= nil then
                -- Cronos: the recorder passes the bones hidden (flag or near-zero scale) at the end of the reload. An item
                -- that is back where it sat when the ammo landed is seated, not parked, even when hidden (the handgun's
                -- fresh cartridge GG_cartridge_02 is swapped for GG_cartridge once it is in).
                local parked = rec.hiddenAtEnd[res.item.bone] == true
                if parked then
                    local fa2 = nil
                    for k, fr in ipairs(frames) do if fr.t >= steps[1].t - 0.001 then fa2 = k break end end
                    local atAmmo = fa2 and frames[fa2].bones[ib] or nil
                    local atEnd = frames[#frames] and frames[#frames].bones[ib] or nil
                    if atAmmo ~= nil and atEnd ~= nil and dist(atAmmo.loc, atEnd.loc) < 1.5 then parked = false end
                end
                if parked then
                    -- the park = where the item ends the reload (its learned rest can be another parked pose)
                    local r0 = (frames[#frames] and frames[#frames].bones[ib]) or rest[ib]
                    local bestS, run = nil, nil
                    for k, fr in ipairs(frames) do
                        if fr.t >= steps[1].t then break end
                        local p = fr.bones[ib]
                        local away = p ~= nil and r0 ~= nil and dist(p.loc, r0.loc) > 3
                        if away and run ~= nil and dist(p.loc, run.ref.loc) <= 0.4 and qangle(p.q, run.ref.q) <= 3 then
                            run.t1 = fr.t
                        else
                            run = away and { ref = p, k = k, t0 = fr.t, t1 = fr.t } or nil
                        end
                        if run ~= nil and run.t1 - run.t0 >= 0.25 and (bestS == nil or run.t1 - run.t0 > bestS.t1 - bestS.t0) then
                            bestS = { ref = run.ref, k = run.k, t0 = run.t0, t1 = run.t1 }
                        end
                    end
                    if bestS ~= nil then
                        local dpath = strokeInto(frames, ib, bestS.ref, bestS.k)
                        res.item.seat = packT(bestS.ref)
                        res.item.docked = true
                        res.item.seatT = r3(bestS.t0)
                        if dpath ~= nil then
                            res.item.approach = packT(dpath.approach)
                            res.item.depth = r3(dpath.depth)
                            res.item.axis = { X = r3(dpath.axis.X), Y = r3(dpath.axis.Y), Z = r3(dpath.axis.Z) }
                        end
                        info(string.format("item parks at its rest: docks at %.2f-%.2f s, (%.1f, %.1f, %.1f)", bestS.t0, bestS.t1,
                            bestS.ref.loc.X, bestS.ref.loc.Y, bestS.ref.loc.Z))
                    end
                end
            end
        end
        res.item.part = cur.magPart and { part = cur.magPart } or nil
        res.style = res.perRound and "rounds" or "item"
    elseif #propFrames > 0 then
        local pf = propFrames[1].prop
        res.item = { prop = { asset = pf.asset, cls = pf.cls, socket = pf.socket } }
        -- grip: hand in prop frame (constant: the prop rides the hand socket)
        local mid = propFrames[math.floor(#propFrames / 2) + 1]
        local hk = pf.hand == "r" and "r" or "l"
        if mid[hk] ~= nil then res.item.grip = packT(relT(mid.prop.T, mid[hk])) end
        res.hand = hk == "l" and "left" or "right"
        -- dock: the prop pose while ammo rises
        local sum, n, q = { X = 0, Y = 0, Z = 0 }, 0, nil
        for _, fr in ipairs(propFrames) do
            for _, s in ipairs(steps) do
                if math.abs(fr.t - s.t) < 0.05 then
                    sum = { X = sum.X + fr.prop.T.loc.X, Y = sum.Y + fr.prop.T.loc.Y, Z = sum.Z + fr.prop.T.loc.Z }
                    n, q = n + 1, fr.prop.T.q
                    break
                end
            end
        end
        if n == 0 then
            -- prop gone before ammo landed (beam MG: the rod docks, then a door turns): last prop frame
            local lf = propFrames[#propFrames]
            sum, n, q = lf.prop.T.loc, 1, lf.prop.T.q
        end
        res.item.dock = packT({ loc = { X = sum.X / n, Y = sum.Y / n, Z = sum.Z / n }, q = q })
        res.fingers = fingerPoseAt(mid.t, hk)
        res.style = "prop"
        -- parked prop (2026-11-20, Charged Shock AR): the prop rides l_hand_Prop_Socket on l_weapon_NSK, a child of the
        -- hand bone that the anims key ~90 cm under the hand (parked out of view) unless they bring the prop in. The
        -- Corrosive Shock MG's empty reload does (rod 9.4 cm from the hand); neither AR reload does, so the grip read
        -- 48 cm and the rod sat nowhere near the hand. A grip that far off is not a grip: the same prop asset's grip and
        -- finger pose from a profile that saw it in the hand are used, and the dock is the hand where the ammo lands
        -- (prop = hand * inverse(grip)).
        local gapOf = function(g) return g and g.loc and vlen(g.loc) or 1e9 end
        if gapOf(res.item.grip) > PROP_MAX_GRIP then
            local donor, donorKey = nil, nil
            for pk, pp in pairs(ctxProfiles) do
                local it = type(pp) == "table" and pp.item or nil
                if pk ~= rec.key and it and it.prop and it.prop.asset == pf.asset and gapOf(it.grip) <= PROP_MAX_GRIP
                    and (it.gripSource == nil or it.gripSource == "learned") then
                    if donor == nil or gapOf(it.grip) < gapOf(donor.item.grip) then donor, donorKey = pp, pk end
                end
            end
            if donor ~= nil then
                -- the hand where the ammo lands (else the last frame with the prop attached)
                local handAt = nil
                for _, fr in ipairs(frames) do
                    if fr[hk] ~= nil and steps[1] ~= nil and fr.t >= steps[1].t - 0.001 then handAt = fr[hk] break end
                end
                if handAt == nil then handAt = propFrames[#propFrames][hk] end
                local g = donor.item.grip
                local gq = { X = g.q.X, Y = g.q.Y, Z = g.q.Z, W = g.q.W }
                local invQ = qconj(gq)
                local invLoc = qrot(invQ, g.loc)
                invLoc = { X = -invLoc.X, Y = -invLoc.Y, Z = -invLoc.Z }
                if handAt ~= nil then
                    local dl = qrot(handAt.q, invLoc)
                    res.item.dock = packT({ loc = { X = handAt.loc.X + dl.X, Y = handAt.loc.Y + dl.Y, Z = handAt.loc.Z + dl.Z },
                                            q = qmul(handAt.q, invQ) })
                end
                info(string.format("prop grip %.1f cm (parked, never in the hand): using the grip of %s (%.1f cm)",
                    gapOf(res.item.grip), donorKey, gapOf(g)))
                res.item.grip = g
                res.item.gripSource = "borrowed:" .. donorKey
                if donor.fingers ~= nil then res.fingers = donor.fingers end
            else
                info(string.format("prop grip %.1f cm (parked, never in the hand) and no profile with this prop in the hand", gapOf(res.item.grip)))
            end
        end
    elseif res.perRound then
        -- Round by round with no carried round in the gun's skeleton (Incendiary Light Revolver 2026-11-19: the game's
        -- right hand fetches each round from 20-25 cm out and pushes it through a loading gate; no gun bone travels).
        -- The round goes into the chamber at the gate: of the round bones under the turning cylinder, the one nearest
        -- the gate across the cylinder axis; it is pushed along that axis from the gate side. The hand nearest that
        -- chamber when the rounds land holds it (grip + fingers from its nearest frame at an ammo step).
        local function low(b) return b.name:lower() end
        local ROUND_WORDS = { "bullet", "round", "shell", "cartridge" }
        local function roundLike(b)
            local n = low(b)
            for _, w in ipairs(ROUND_WORDS) do if n:find(w, 1, true) then return true end end
            return false
        end
        local gate = nil
        for i, b in ipairs(cur.bones) do if low(b):find("gate", 1, true) and rest[i] ~= nil then gate = i break end end
        local cyl, cylA = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not roundLike(b) and m.maxA > cylA and m.iA ~= nil and rest[i] ~= nil then
                local has = false
                for _, c in ipairs(cur.bones) do
                    if roundLike(c) and isAncestor(b.name, c.name) then has = true break end
                end
                if has then cyl, cylA = i, m.maxA end
            end
        end
        if gate == nil or cyl == nil or cylA < 20 then return cronosShell(res, frames, rest, steps) end
        -- the cylinder's turning axis (component frame) from rest to its most-turned frame
        local dq = qmul(frames[motion[cyl].iA].bones[cyl].q, qconj(rest[cyl].q))
        local sn = math.sqrt(math.max(0, 1 - dq.W * dq.W))
        if sn < 1e-4 then return cronosShell(res, frames, rest, steps) end
        local ax = vnorm({ X = dq.X / sn, Y = dq.Y / sn, Z = dq.Z / sn })
        local g = rest[gate].loc
        local function across(p)
            local d = vsub(p, g)
            local along = d.X * ax.X + d.Y * ax.Y + d.Z * ax.Z
            return vlen({ X = d.X - ax.X * along, Y = d.Y - ax.Y * along, Z = d.Z - ax.Z * along }), along
        end
        local pick, pickD, pickAlong = nil, 1e9, 0
        for i, b in ipairs(cur.bones) do
            if roundLike(b) and rest[i] ~= nil and isAncestor(cur.bones[cyl].name, b.name) then
                local d, along = across(rest[i].loc)
                if d < pickD then pick, pickD, pickAlong = i, d, along end
            end
        end
        if pick == nil then return cronosShell(res, frames, rest, steps) end
        -- the push direction: from the gate side into the chamber
        local dir = pickAlong >= 0 and ax or { X = -ax.X, Y = -ax.Y, Z = -ax.Z }
        local seat = rest[pick]
        local depth = math.abs(pickAlong) + 2.0
        local approach = { loc = { X = seat.loc.X - dir.X * depth, Y = seat.loc.Y - dir.Y * depth, Z = seat.loc.Z - dir.Z * depth }, q = seat.q }
        -- the loading hand: nearest the chamber at the ammo steps
        local best_ = { l = { d = 1e9 }, r = { d = 1e9 } }
        local sumD = { l = 0, r = 0 }
        for _, st in ipairs(steps) do
            for _, f2 in ipairs(frames) do
                if math.abs(f2.t - st.t) <= 0.12 then
                    for _, hk in ipairs({ "l", "r" }) do
                        if f2[hk] ~= nil then
                            local d = dist(f2[hk].loc, seat.loc)
                            if d < best_[hk].d then best_[hk] = { d = d, f = f2 } end
                        end
                    end
                end
            end
        end
        for _, f2 in ipairs(frames) do
            if f2.l ~= nil and f2.r ~= nil and f2.t >= steps[1].t - 0.6 and f2.t <= steps[#steps].t then
                sumD.l, sumD.r = sumD.l + dist(f2.l.loc, seat.loc), sumD.r + dist(f2.r.loc, seat.loc)
            end
        end
        -- the holding hand stays put next to the cylinder (low mean distance, little motion); the loading hand comes and
        -- goes - the nearest hand at the steps that is NOT parked beside the gun the whole time
        local function travel(hk)
            local tot, prev = 0, nil
            for _, f2 in ipairs(frames) do
                if f2[hk] ~= nil and f2.t >= steps[1].t - 0.6 and f2.t <= steps[#steps].t then
                    if prev ~= nil then tot = tot + dist(prev, f2[hk].loc) end
                    prev = f2[hk].loc
                end
            end
            return tot
        end
        local hk = travel("r") >= travel("l") and "r" or "l"
        local bf = best_[hk].f
        if bf == nil then return cronosShell(res, frames, rest, steps) end
        local names, set = subtreeOf(cur.bones[pick].name)
        itemSet = set
        res.item = { bone = cur.bones[pick].name, bones = names, grip = packT(relT(seat, bf[hk])), gripSource = "gate",
                     gripT = { r3(bf.t), r3(bf.t) }, rest = packT(seat), seat = packT(seat), docked = true,
                     approach = packT(approach), depth = r3(depth), axis = { X = r3(dir.X), Y = r3(dir.Y), Z = r3(dir.Z) },
                     seatT = r3(steps[1].t), keepVisible = true, gate = cur.bones[gate].name, cylinder = cur.bones[cyl].name }
        res.hand = hk == "l" and "left" or "right"
        res.fingers = fingerPoseAt(bf.t, hk)
        res.style = "rounds"
    else
        return cronosShell(res, frames, rest, steps)
    end

    -- round by round: where to hold between rounds. Holding on the count left the Incendiary Light Revolver's loaded
    -- round at the gate / a chamber half turned: the cylinder turns one chamber 0.09-0.15 s (montage) after the count,
    -- and from +0.23 s the ejector rod pushes the next spent case out (2026-11-19). Hold in the quiet moment between
    -- (montage time; manual_reload plays the settle at 1x). The loading hand's farthest point was tried first, but on an
    -- 8-round recording its distance plateau is flat (argmax anywhere in 0.20-0.24 s), so the hold
    -- is taken from the gun itself: after each count, the midpoint between the end of its first motion burst (the
    -- cylinder turn) and the start of the next (the ejector). The first round runs the montage's first section and
    -- settles sooner (turn +0.04-0.11, ejector +0.17 -> 0.14) than the looping rounds (turn to +0.17, next from +0.23 ->
    -- 0.20): feedSettleFirst + feedSettle (median of the loop rounds).
    if res.perRound and #steps >= 1 then
        local function moved(f, p)
            for i, b in ipairs(cur.bones) do
                local a, c = f.bones[i], p.bones[i]
                if not itemSet[b.name] and a ~= nil and c ~= nil and (dist(a.loc, c.loc) > 0.1 or qangle(a.q, c.q) > 1.0) then return true end
            end
            return false
        end
        local holds = {}
        for si, st in ipairs(steps) do
            local limit = steps[si + 1] and math.min(st.t + 0.45, steps[si + 1].t) or st.t + 0.45
            local lastMove, firstQuiet, nextMove = nil, nil, nil
            for k = 2, #frames do
                local f = frames[k]
                if f.t > st.t and f.t <= limit then
                    local mv = moved(f, frames[k - 1])
                    if lastMove == nil then
                        if mv then lastMove = f.t end
                    elseif firstQuiet == nil then
                        if mv then lastMove = f.t else firstQuiet = f.t end
                    elseif mv then
                        nextMove = f.t
                        break
                    end
                end
            end
            if lastMove ~= nil and firstQuiet ~= nil then
                holds[si] = ((lastMove + (nextMove or (firstQuiet + 0.05))) / 2) - st.t
            elseif lastMove == nil then
                holds[si] = 0 -- nothing moves after this count
            end
        end
        if holds[1] ~= nil then res.feedSettleFirst = r3(holds[1]) end
        local loop = {}
        for si = 2, #steps do if holds[si] ~= nil then loop[#loop + 1] = holds[si] end end
        if #loop > 0 then
            table.sort(loop)
            res.feedSettle = r3(loop[math.floor((#loop + 1) / 2)])
        else
            res.feedSettle = res.feedSettleFirst
        end
    end

    -- rack (empty reloads, or the only reload of a gun without an empty variant - Volted Sniper Rifle's bolt cycles on
    -- every reload): a part that slides from rest and back, outside the item
    -- Cronos: a mode without its own empty-reload animation (GravityGun) racks on its only reload
    local hasEmpty = rec.hasEmpty ~= false
    if rec.empty or not hasEmpty then
        local rk, rkD = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            -- (a part travelling as far as a magazine is not a rack: Vladof SMG's second magazine R_Mag_02, 41 cm, 2026-11-23)
            if not itemSet[b.name] and not cosmeticBone(b.name) and m.maxD >= RACK_MIN_TRAVEL and m.maxD < ITEM_MIN_TRAVEL and m.endRest and m.iD ~= nil then
                local t = frames[m.iD].bones[i]
                local rotAtMax = qangle(t.q, rest[i].q)
                local parent = cur.byName[b.parent]
                local parentSlides = parent ~= nil and not itemSet[parent.name] and motion[parent.index].maxD >= RACK_MIN_TRAVEL
                -- Cronos: a hand works it (within RACK_HAND_CM at the max pull) - the gun's own action can slide parts by
                -- itself during a reload (handgun GG_slide 5.6 cm), and those are no rack for the player
                local fm = frames[m.iD]
                local nearHand = math.min(fm.l and dist(fm.l.loc, t.loc) or 1e9, fm.r and dist(fm.r.loc, t.loc) or 1e9)
                if rotAtMax < 20 and not parentSlides and nearHand <= RACK_HAND_CM and m.maxD > rkD then rk, rkD = i, m.maxD end
            end
        end
        if rk ~= nil then
            local m = motion[rk]
            local b = cur.bones[rk]
            local tMax = frames[m.iD].bones[rk]
            local axis = vnorm(vsub(tMax.loc, rest[rk].loc))
            local release = nil
            for k = m.iD, #frames do
                local t = frames[k].bones[rk]
                if t ~= nil and dist(t.loc, rest[rk].loc) < 0.3 then release = frames[k].t break end
            end
            -- locked back: the part sits displaced for most of the reload before the pull (the game moves the
            -- pistol slide back within the first frames of an empty reload, so frame 1 can still read rest)
            local before, displaced, lockSum = 0, 0, 0
            for k = 1, m.iD - 1 do
                local t = frames[k].bones[rk]
                if t ~= nil then
                    before = before + 1
                    local d = dist(t.loc, rest[rk].loc)
                    if d > 1.0 then displaced, lockSum = displaced + 1, lockSum + d end
                end
            end
            local lockedBack = before >= 5 and displaced >= before * 0.8
            -- hand on it: the hand doing the reload work (the item hand) when it is near the part at max pull, else the
            -- closer hand. Closest alone picked the bullpup AR's right hand, which sits on the grip about 1 cm closer
            -- than the left hand pulling the lever.
            local fr = frames[m.iD]
            local dl = fr.l and dist(fr.l.loc, tMax.loc) or 1e9
            local dr = fr.r and dist(fr.r.loc, tMax.loc) or 1e9
            local hk = dl <= dr and "l" or "r"
            local workHand = res.hand == "left" and "l" or (res.hand == "right" and "r" or nil)
            if workHand ~= nil and (workHand == "l" and dl or dr) <= 25 then hk = workHand end
            res.rack = { bone = b.name, axis = { X = r3(axis.X), Y = r3(axis.Y), Z = r3(axis.Z) }, travel = r3(m.maxD),
                         lockedBack = lockedBack, lockedCm = lockedBack and r3(lockSum / displaced) or nil,
                         pullT = r3(fr.t), releaseT = release and r3(release) or nil,
                         hand = hk == "l" and "left" or "right", grip = fr[hk] and packT(relT(tMax, fr[hk])) or nil,
                         rest = packT(rest[rk]), fingers = fingerPoseAt(fr.t, hk) }
            -- lift: a rotating part in the rack's chain that turns before the pull (bolt handle)
            for i, bb in ipairs(cur.bones) do
                local mm = motion[i]
                if i ~= rk and (isAncestor(b.name, bb.name) or isAncestor(bb.name, b.name)) and mm.maxA >= 20 and mm.iA ~= nil
                    and frames[mm.iA].t <= fr.t + 0.05 then
                    local open = frames[mm.iA].bones[i]
                    res.rack.lift = { bone = bb.name, angle = r3(mm.maxA), open = packT(relT(rest[i], open)) }
                    break
                end
            end
            -- the hand pose on the part: the frame where the rack hand is nearest the part it works (the lift handle when
            -- there is one) while the part is off rest. At the max pull the Volted Sniper's right hand is holding the
            -- new clip 12.6 cm away (finger pose = clip grip, "mangled"); it is on the handle at 2.51 s (5.2 cm).
            do
                local gi = rk
                if res.rack.lift ~= nil and cur.byName[res.rack.lift.bone] ~= nil then gi = cur.byName[res.rack.lift.bone].index end
                local bestK, bestD = nil, 1e9
                for k, f2 in ipairs(frames) do
                    local t, h, g = f2.bones[rk], f2[hk], f2.bones[gi]
                    if t ~= nil and h ~= nil and g ~= nil and dist(t.loc, rest[rk].loc) > 1.0 then
                        local d = dist(h.loc, g.loc)
                        if d < bestD then bestK, bestD = k, d end
                    end
                end
                if bestK ~= nil then
                    local f2 = frames[bestK]
                    res.rack.grip = packT(relT(f2.bones[rk], f2[hk]))
                    res.rack.fingers = fingerPoseAt(f2.t, hk)
                    res.rack.gripT = r3(f2.t)
                end
            end
            res.rack.every = not rec.empty -- learned from the gun's only reload variant: it racks on every reload
            -- bolt: the part is open while the item seats (bolt action: opened before the clip goes in, shut after).
            -- The weapon montage drives the bolt, its handle and any linkage outside its bone chain (the Volted Sniper's
            -- BoltArm1/2 fold with the bolt), so the manual close scrubs that montage: openPos = fully open,
            -- close = { montage time, bolt travel } from the last fully-open frame to closed (travel non-increasing).
            local seatT = res.item and res.item.seatT
            if seatT ~= nil then
                local function dk(k) local t = frames[k].bones[rk] return t and dist(t.loc, rest[rk].loc) or nil end
                local iSeat = nil
                for k, f2 in ipairs(frames) do if f2.t >= seatT - 0.001 then iSeat = k break end end
                local ds = iSeat and dk(iSeat) or 0
                if ds >= 0.5 * m.maxD then
                    local near = m.maxD - 0.15
                    local iOpen, iHold, iClosed = nil, nil, nil
                    for k = 1, #frames do local d = dk(k) if d ~= nil and d >= near then iOpen = k break end end
                    for k = iSeat, #frames do local d = dk(k) if d ~= nil and d < 0.3 then iClosed = k break end end
                    if iOpen ~= nil and iClosed ~= nil then
                        for k = iOpen, iClosed do local d = dk(k) if d ~= nil and d >= near then iHold = k end end
                    end
                    if iOpen ~= nil and iHold ~= nil and iClosed ~= nil and frames[iOpen].gpos ~= nil then
                        local tbl, minD = {}, 1e9
                        for k = iHold, iClosed do
                            local d, p = dk(k), frames[k].gpos
                            if d ~= nil and p ~= nil then
                                minD = math.min(minD, d)
                                tbl[#tbl + 1] = { p = r3(p), a = frames[k].apos and r3(frames[k].apos) or nil, d = r3(minD) }
                            end
                        end
                        if #tbl >= 2 then
                            res.rack.bolt = { openPos = r3(frames[iOpen].gpos), close = tbl,
                                              openArms = frames[iOpen].apos and r3(frames[iOpen].apos) or nil }
                        end
                    end
                end
            end
        end
    end

    -- bolt path (BL4 2026-11-23, Jakobs sniper Bolt_Handle): the handle lifts 90 deg, slides back 9.6 cm, holds while the round
    -- chambers, slides forward and drops - it both turns and slides, so neither the slide rack (< 20 deg) nor the rotary
    -- rack (< 0.5 cm) takes it, and the OW2 bolt table needs montage times BL4 does not have. Learned as three poses:
    -- rest, lifted (most turned before it slides 1 cm), open (furthest back); the hand drives it along rest -> lift -> open.
    -- Learned from either recording (a bolt cycling in the tactical reload too = every reload).
    if res.rack == nil then
        local bk, bkD = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and not cosmeticBone(b.name) and m.maxD >= RACK_MIN_TRAVEL and m.maxD < ITEM_MIN_TRAVEL
                and m.maxA >= 30 and m.endRest and m.iD ~= nil then
                local parent = cur.byName[b.parent]
                local parentMoves = parent ~= nil and not itemSet[parent.name] and (motion[parent.index].maxD >= RACK_MIN_TRAVEL or motion[parent.index].maxA >= 30)
                local fr = frames[m.iD]
                local t = fr.bones[i]
                local dl = fr.l and dist(fr.l.loc, t.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, t.loc) or 1e9
                if not parentMoves and math.min(dl, dr) <= 25 and m.maxD > bkD then bk, bkD = i, m.maxD end
            end
        end
        if bk ~= nil then
            local m = motion[bk]
            local b = cur.bones[bk]
            local r0 = rest[bk]
            local open = frames[m.iD].bones[bk]
            -- lifted: the most turned pose before the part has slid 1 cm
            local lift, liftA, liftK = nil, -1, nil
            for k = 1, m.iD do
                local t = frames[k].bones[bk]
                if t ~= nil and dist(t.loc, r0.loc) < 1.0 then
                    local a = qangle(t.q, r0.q)
                    if a > liftA then lift, liftA, liftK = t, a, k end
                end
            end
            if lift ~= nil and liftA >= 20 then
                local fr = frames[m.iD]
                local dl = fr.l and dist(fr.l.loc, open.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, open.loc) or 1e9
                local hk = dl <= dr and "l" or "r"
                -- the hand pose on the handle: nearest frame while it is off rest
                local bestK, bestD = nil, 1e9
                for k, f2 in ipairs(frames) do
                    local t, h = f2.bones[bk], f2[hk]
                    if t ~= nil and h ~= nil and (dist(t.loc, r0.loc) > 0.5 or qangle(t.q, r0.q) > 10) then
                        local d = dist(h.loc, t.loc)
                        if d < bestD then bestK, bestD = k, d end
                    end
                end
                local gk = bestK or m.iD
                local ax = vnorm(vsub(open.loc, lift.loc))
                res.rack = { boltPath = true, bone = b.name, rest = packT(r0), liftPose = packT(lift), openPose = packT(open),
                             axis = { X = r3(ax.X), Y = r3(ax.Y), Z = r3(ax.Z) }, travel = r3(dist(open.loc, lift.loc)),
                             liftDeg = r3(liftA), hand = hk == "l" and "left" or "right",
                             grip = frames[gk][hk] and packT(relT(frames[gk].bones[bk], frames[gk][hk])) or nil,
                             fingers = fingerPoseAt(frames[gk].t, hk), gripT = r3(frames[gk].t), every = not rec.empty }
                info(string.format("bolt path: %s lifts %.0f deg, slides %.1f cm (%s hand)", b.name, liftA, res.rack.travel, res.rack.hand))
            end
        end
    end

    -- crank (2026-11-20, Chilling Anti-Matter Plasma Rifle): after the magazine seats, the hand winds Crank_JNT from -86 to
    -- +360 deg (1.24 turns) while Gear1/Gear2/Rotator spin up to 720 deg and the Wingnut counter-turns - the ammo arrives
    -- mid-wind. A part copy cannot show the linked parts, so the wind scrubs the reload montages like the bolt action:
    -- rack.bolt = { openPos = montage time where the wind starts, close = { montage time, deg still to wind } } with
    -- rack.crank = true (manual_reload measures the hand sweep about the crank axis instead of a push along it).
    -- Candidates: rotation only (< 0.5 cm), unwrapped sweep >= CRANK_MIN_DEG in one run that starts after the item seats,
    -- frames carry the weapon montage time; the part the hands come nearest during the run wins (gears spin more, but the
    -- hand works the crank: 5.2 cm vs 12+).
    if (rec.empty or not hasEmpty) and res.rack == nil then
        local seatT = res.item and res.item.seatT or 0
        -- (the reference axis needs a real turn, >= 0.5 deg in a frame: the first tiny delta was quaternion rounding noise
        -- along (-1,1,-1)/sqrt3 - stored as the Anti-Matter crank axis, it skewed the hand sweep, 2026-11-20)
        local function unwrapped(i)
            local acc, axis, prev, out, turn = 0, nil, nil, {}, {}
            for k, f2 in ipairs(frames) do
                local t = f2.bones[i]
                if t ~= nil and prev ~= nil then
                    local qd = qmul(t.q, qconj(prev.q))
                    if qd.W < 0 then qd = { X = -qd.X, Y = -qd.Y, Z = -qd.Z, W = -qd.W } end
                    local sn = math.sqrt(qd.X * qd.X + qd.Y * qd.Y + qd.Z * qd.Z)
                    local ang = math.deg(2 * math.atan(sn, qd.W))
                    if sn > 1e-5 then
                        local ax = { X = qd.X / sn, Y = qd.Y / sn, Z = qd.Z / sn }
                        if axis == nil and ang >= 0.5 then axis = ax end
                        if axis ~= nil then
                            local sg = (ax.X * axis.X + ax.Y * axis.Y + ax.Z * axis.Z) >= 0 and 1 or -1
                            acc = acc + sg * ang
                            turn[k] = { X = ax.X * sg * ang, Y = ax.Y * sg * ang, Z = ax.Z * sg * ang }
                        end
                    end
                end
                if t ~= nil then prev = t end
                out[k] = acc
            end
            return out, axis, turn
        end
        local best = nil
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and not cosmeticBone(b.name) and m.maxD < 0.5 and m.maxA >= RACK_MIN_DEG then
                local acc, axis, turn = unwrapped(i)
                if axis ~= nil then
                    -- the biggest sweep acc[j] - acc[i0] (either sense) with i0 < j, via running min / max
                    local iMin, iMax, bi, bj, bs = 1, 1, nil, nil, 0
                    for k = 2, #frames do
                        if acc[k] - acc[iMin] > bs then bi, bj, bs = iMin, k, acc[k] - acc[iMin] end
                        if acc[iMax] - acc[k] > bs then bi, bj, bs = iMax, k, acc[iMax] - acc[k] end
                        if acc[k] < acc[iMin] then iMin = k end
                        if acc[k] > acc[iMax] then iMax = k end
                    end
                    if bi ~= nil and bs >= CRANK_MIN_DEG then
                        local sg = acc[bj] >= acc[bi] and 1 or -1
                        -- trim the plateaus: the last frame still at the start angle, the first already at the end angle
                        -- (the Anti-Matter crank overshoots to -89 deg before it settles at -86: an exact-angle plateau
                        -- trim started the wind at 0.73 s, before the magazine came out)
                        local a0 = acc[bi]
                        local j0 = bj
                        for k = j0, bi, -1 do if (acc[k] - a0) * sg >= bs - 1 then bj = k end end
                        for k = bi, bj do if (acc[k] - a0) * sg <= 0.03 * bs then bi = k end end
                        local nearest = 1e9
                        for k = bi, bj do
                            local t, f2 = frames[k].bones[i], frames[k]
                            if t ~= nil then
                                if f2.l then nearest = math.min(nearest, dist(f2.l.loc, t.loc)) end
                                if f2.r then nearest = math.min(nearest, dist(f2.r.loc, t.loc)) end
                            end
                        end
                        if frames[bi].t >= seatT - 0.1 and frames[bi].gpos ~= nil and nearest <= 25
                            and (best == nil or nearest < best.nearest) then
                            local sum = { X = 0, Y = 0, Z = 0 }
                            for k = bi + 1, bj do
                                local tv = turn[k]
                                if tv ~= nil then sum = { X = sum.X + tv.X, Y = sum.Y + tv.Y, Z = sum.Z + tv.Z } end
                            end
                            local ra = vnorm(sum)
                            best = { i = i, acc = acc, bi = bi, bj = bj, sg = sg, nearest = nearest,
                                     axis = { X = ra.X * sg, Y = ra.Y * sg, Z = ra.Z * sg } }
                        end
                    end
                end
            end
        end
        if best ~= nil then
            local i, acc, sg = best.i, best.acc, best.sg
            -- the table ends before the ammo arrives: the finish plays the rest of the montage (a Montage_SetPosition
            -- jump would skip the notify that grants it)
            local jEnd = best.bj
            local steps = ammoSteps(frames)
            for _, st in ipairs(steps) do
                if st.t > frames[best.bi].t and st.t <= frames[jEnd].t then
                    for k = best.bi, jEnd do if frames[k].t >= st.t then jEnd = math.max(best.bi + 1, k - 2) break end end
                    break
                end
            end
            local total = (acc[jEnd] - acc[best.bi]) * sg
            local tbl, minD = {}, 1e9
            for k = best.bi, jEnd do
                local f2 = frames[k]
                if f2.gpos ~= nil then
                    minD = math.min(minD, math.max(0, total - (acc[k] - acc[best.bi]) * sg))
                    tbl[#tbl + 1] = { p = r3(f2.gpos), a = f2.apos and r3(f2.apos) or nil, d = r3(minD) }
                end
            end
            if #tbl >= 2 and total >= CRANK_MIN_DEG * 0.5 then
                local b = cur.bones[i]
                local mid = math.floor((best.bi + jEnd) / 2)
                local fr = frames[mid]
                local tm = fr.bones[i]
                local dl = fr.l and dist(fr.l.loc, tm.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, tm.loc) or 1e9
                local hk = dl <= dr and "l" or "r"
                -- linked parts: everything else that turns during the wind (the montage scrub poses them; they are not
                -- openers to flick shut)
                local linked = {}
                for i2, b2 in ipairs(cur.bones) do
                    if i2 ~= i and not itemSet[b2.name] and motion[i2].maxA >= MECH_MIN_DEG then
                        local a2 = unwrapped(i2)
                        if math.abs(a2[jEnd] - a2[best.bi]) >= MECH_MIN_DEG then linked[#linked + 1] = b2.name end
                    end
                end
                local knob = nil
                do
                    local gT = fr[hk] and relT(tm, fr[hk]) or nil
                    local fp = fingerPoseAt(fr.t, hk)
                    if gT ~= nil and type(fp) == "table" then
                        local c, n = { X = 0, Y = 0, Z = 0 }, 0
                        for name, f in pairs(fp) do
                            if name:find("2_JNT", 1, true) and f.loc ~= nil then
                                local w = qrot(gT.q, f.loc)
                                c = { X = c.X + w.X + gT.loc.X, Y = c.Y + w.Y + gT.loc.Y, Z = c.Z + w.Z + gT.loc.Z }
                                n = n + 1
                            end
                        end
                        if n > 0 then knob = { X = r3(c.X / n), Y = r3(c.Y / n), Z = r3(c.Z / n) } end
                    end
                end
                res.rack = { crank = true, knob = knob, bone = b.name, axis = { X = r3(best.axis.X), Y = r3(best.axis.Y), Z = r3(best.axis.Z) },
                             travel = r3(total), hand = hk == "l" and "left" or "right",
                             grip = fr[hk] and packT(relT(tm, fr[hk])) or nil, rest = packT(rest[i]),
                             fingers = fingerPoseAt(fr.t, hk), gripT = r3(fr.t), linked = linked,
                             pullT = r3(frames[best.bi].t), releaseT = r3(frames[jEnd].t),
                             bolt = { openPos = tbl[1].p, openArms = tbl[1].a, close = tbl },
                             every = not rec.empty }
            end
        end
    end

    -- rotary rack (2026-11-20, Rookie's Reward ChargingHandle_JNT): no sliding part, but a handle that swings about its
    -- pivot - 19.5 deg locked while empty, pulled to 42 deg after the new magazine seats, snaps home. Candidates: outside
    -- the item, rotation only (>= RACK_MIN_DEG, < 0.5 cm travel), back at rest at the end, a hand within 25 cm at the max
    -- swing, and the max swing after the item seats - a hinge / mag release opens before the item comes out (Rookie's
    -- ClipRelease_JNT 19 deg at 0.28 s, Autospray Magazine_Hinge_JNT 24 deg at 0.33 s). The biggest swing wins.
    -- Stored like a slide rack with rot = true: axis = the rotation axis (gun component space), travel / lockedDeg in deg.
    if (rec.empty or not hasEmpty) and res.rack == nil then
        local seatT = res.item and res.item.seatT
        local rk, rkA = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and not cosmeticBone(b.name) and m.maxA >= RACK_MIN_DEG and m.maxD < 0.5 and m.endRest and m.iA ~= nil
                and (seatT == nil or frames[m.iA].t >= seatT) then
                local parent = cur.byName[b.parent]
                local parentMoves = parent ~= nil and not itemSet[parent.name] and
                    (motion[parent.index].maxA >= RACK_MIN_DEG or motion[parent.index].maxD >= RACK_MIN_TRAVEL)
                local fr = frames[m.iA]
                local t = fr.bones[i]
                local dl = fr.l and dist(fr.l.loc, t.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, t.loc) or 1e9
                if not parentMoves and math.min(dl, dr) <= 25 and m.maxA > rkA then rk, rkA = i, m.maxA end
            end
        end
        if rk ~= nil then
            local m = motion[rk]
            local b = cur.bones[rk]
            local fr = frames[m.iA]
            local tMax = fr.bones[rk]
            -- component-space delta: tMax.q = qd * rest.q (the pivot stays put)
            local qd = qmul(tMax.q, qconj(rest[rk].q))
            if qd.W < 0 then qd = { X = -qd.X, Y = -qd.Y, Z = -qd.Z, W = -qd.W } end
            local axis = vnorm({ X = qd.X, Y = qd.Y, Z = qd.Z })
            local function angleOf(t) return t and qangle(t.q, rest[rk].q) or nil end
            local release = nil
            for k = m.iA, #frames do
                local a = angleOf(frames[k].bones[rk])
                if a ~= nil and a < 3 then release = frames[k].t break end
            end
            local before, displaced, lockSum = 0, 0, 0
            for k = 1, m.iA - 1 do
                local a = angleOf(frames[k].bones[rk])
                if a ~= nil then
                    before = before + 1
                    if a > 5 then displaced, lockSum = displaced + 1, lockSum + a end
                end
            end
            local lockedBack = before >= 5 and displaced >= before * 0.8
            local dl = fr.l and dist(fr.l.loc, tMax.loc) or 1e9
            local dr = fr.r and dist(fr.r.loc, tMax.loc) or 1e9
            local hk = dl <= dr and "l" or "r"
            local workHand = res.hand == "left" and "l" or (res.hand == "right" and "r" or nil)
            if workHand ~= nil and (workHand == "l" and dl or dr) <= 25 then hk = workHand end
            res.rack = { rot = true, bone = b.name, axis = { X = r3(axis.X), Y = r3(axis.Y), Z = r3(axis.Z) }, travel = r3(m.maxA),
                         lockedBack = lockedBack, lockedDeg = lockedBack and r3(lockSum / displaced) or nil,
                         pullT = r3(fr.t), releaseT = release and r3(release) or nil,
                         hand = hk == "l" and "left" or "right", grip = fr[hk] and packT(relT(tMax, fr[hk])) or nil,
                         rest = packT(rest[rk]), fingers = fingerPoseAt(fr.t, hk) }
            -- hand pose: the frame where the rack hand is nearest the handle while it is swung (> 5 deg)
            local bestK, bestD = nil, 1e9
            for k, f2 in ipairs(frames) do
                local t, h = f2.bones[rk], f2[hk]
                if t ~= nil and h ~= nil and angleOf(t) > 5 then
                    local d = dist(h.loc, t.loc)
                    if d < bestD then bestK, bestD = k, d end
                end
            end
            if bestK ~= nil then
                local f2 = frames[bestK]
                res.rack.grip = packT(relT(f2.bones[rk], f2[hk]))
                res.rack.fingers = fingerPoseAt(f2.t, hk)
                res.rack.gripT = r3(f2.t)
            end
            res.rack.every = not rec.empty
        end
    end

    -- mechanisms: other parts that open and close (hinges, gates, locks, clamps, doors)
    local skip = {}
    if res.rack then skip[res.rack.bone] = true if res.rack.lift then skip[res.rack.lift.bone] = true end end
    if res.rack and res.rack.linked then for _, n in ipairs(res.rack.linked) do skip[n] = true end end
    for i, b in ipairs(cur.bones) do
        local m = motion[i]
        if not itemSet[b.name] and not skip[b.name] and not cosmeticBone(b.name) and (m.maxA >= MECH_MIN_DEG or m.maxD >= MECH_MIN_CM) and m.endRest then
            local parent = cur.byName[b.parent]
            local parentMech = parent ~= nil and (motion[parent.index].maxA >= MECH_MIN_DEG or motion[parent.index].maxD >= MECH_MIN_CM)
            if not parentMech and #res.mechanisms < 16 then
                -- motion is measured from the part's pose when the reload montage starts, not the idle pose: the Beam
                -- Caster's Mag_Release_JNT sits 180 deg off its idle pose for the whole montage (a pose-basis difference
                -- between the idle and reload anims, not a swing) and passed as an opener (2026-11-19)
                -- The montage can pose the gun a frame after the recording starts (Beam Caster empty reload: frame 1 at
                -- the idle basis, frame 2 at +180), so the baseline moves past any single-frame jump > 90 deg before the
                -- ammo lands: a pose-basis snap; no animated hinge turns 90 deg in one frame.
                local base, baseK = frames[1].bones[i] or rest[i], 1
                for k = 2, #frames do
                    if frames[k].t >= steps[1].t then break end
                    local pa, pb = frames[k - 1].bones[i], frames[k].bones[i]
                    if pa ~= nil and pb ~= nil and qangle(pa.q, pb.q) > 90 then base, baseK = pb, k end
                end
                local tOpen, tClose = nil, nil
                local mA, mD, iA, iD = 0, 0, nil, nil
                for fi, fr in ipairs(frames) do
                    local t = fi >= baseK and fr.bones[i] or nil
                    if t ~= nil then
                        local d, a = dist(t.loc, base.loc), qangle(t.q, base.q)
                        if d > mD then mD, iD = d, fi end
                        if a > mA then mA, iA = a, fi end
                        if d > 0.3 or a > 3 then tOpen = tOpen or fr.t tClose = fr.t end
                    end
                end
                local key = nil
                if mA >= MECH_MIN_DEG then key = iA elseif mD >= MECH_MIN_CM then key = iD end
                if key ~= nil then
                    local mech = { bone = b.name, open = packT(relT(rest[i], frames[key].bones[i])), rest = packT(rest[i]),
                        maxDeg = r3(mA), maxCm = r3(mD), tOpen = tOpen and r3(tOpen), tClose = tClose and r3(tClose) }
                    local ta = steps[1].t
                    local carriesItem = res.item ~= nil and res.item.bone ~= nil and isAncestor(b.name, res.item.bone)
                    -- round by round, the opener may carry the rounds: the Charged Triple Barrel Shotgun's barrel_JNT
                    -- (83 deg) holds the three shell bones the shells are loaded into (2026-11-19)
                    -- Cronos: parts that slide open count too (handgun slide / bolts 5.6-8.6 cm), and a part may shut on the very frame
                    -- the ammo lands (SmartGun braces)
                    if (mA >= OPENER_MIN_DEG or mD >= 2.0) and tOpen ~= nil and tClose ~= nil and tOpen < ta and tClose >= ta - 0.001 and (not carriesItem or res.perRound) then
                        local fa = nil
                        for k, fr in ipairs(frames) do if fr.t >= ta - 0.001 then fa = k break end end
                        -- open when the ammo lands (the revolver cylinder is): the Beam Caster's latch is pressed at
                        -- 1.6 s and only jumps back to its idle basis after the montage ends - neither is an opening
                        if fa ~= nil and frames[fa].bones[i] ~= nil and (qangle(frames[fa].bones[i].q, base.q) >= OPENER_MIN_DEG or dist(frames[fa].bones[i].loc, base.loc) >= 2.0) then
                            mech.opener = true
                            mech.openPose = packT(frames[fa].bones[i])
                        end
                    end
                    res.mechanisms[#res.mechanisms + 1] = mech
                end
            end
        end
    end
    -- Break action, several chambers (Charged Triple Barrel Shotgun 2026-11-19): the barrel opens, the spent shells fly
    -- out, the same shell bones come back in the hand and go in one at a time - Left, Middle, Right, the k-th shell into
    -- the k-th chamber (a one-shell reload loads Left). Per count: the round bone under the opener that most recently
    -- arrived in its place relative to the opener; its seat + insert stroke are kept relative to the opener and placed
    -- at the opener's open pose (manual_reload's open copy). item.seats in loading order.
    if res.perRound and res.item ~= nil and res.item.bone ~= nil then
        local op = nil
        for _, m in ipairs(res.mechanisms) do
            if m.opener and m.openPose ~= nil and isAncestor(m.bone, res.item.bone) then op = m break end
        end
        if op ~= nil and cur.byName[op.bone] ~= nil then
            local function composeT(a, b) local l = qrot(a.q, b.loc) return { loc = { X = a.loc.X + l.X, Y = a.loc.Y + l.Y, Z = a.loc.Z + l.Z }, q = qmul(a.q, b.q) } end
            local function roundName(n)
                n = n:lower()
                return n:find("bullet", 1, true) or n:find("round", 1, true) or n:find("shell", 1, true) or n:find("cartridge", 1, true)
            end
            local oi = cur.byName[op.bone].index
            local rounds = {}
            for i, b in ipairs(cur.bones) do
                if roundName(b.name) and isAncestor(op.bone, b.name) and rest[i] ~= nil and not roundName(b.parent or "") then
                    rounds[#rounds + 1] = i
                end
            end
            local function relRest(i) return relT(rest[oi], rest[i]) end
            local function seatedAt(k, i)
                local f = frames[k]
                if f == nil or f.bones[oi] == nil or f.bones[i] == nil then return false end
                return dist(relT(f.bones[oi], f.bones[i]).loc, relRest(i).loc) < 0.5
            end
            local seats, used = {}, {}
            for _, st in ipairs(steps) do
                local ks = nil
                for k, f in ipairs(frames) do if f.t >= st.t - 0.001 then ks = k break end end
                if ks ~= nil then
                    -- the shell can seat a frame after its count (Right: counted at 2.227 s, 1.5 cm out, in at 2.25 s):
                    -- look up to 0.12 s past the count
                    local best, bestArr, bestK = nil, -1, nil
                    local kk = ks
                    while best == nil and kk <= #frames and frames[kk].t <= st.t + 0.12 do
                        for _, i in ipairs(rounds) do
                            if not used[i] and seatedAt(kk, i) then
                                local k = kk
                                while k > 1 and seatedAt(k - 1, i) do k = k - 1 end
                                if frames[k].t > bestArr then best, bestArr, bestK = i, frames[k].t, k end
                            end
                        end
                        kk = kk + 1
                    end
                    if best ~= nil then
                        used[best] = true
                        local path = strokeInto(frames, best, frames[bestK].bones[best], bestK)
                        local appRel = path ~= nil and relT(frames[bestK].bones[oi], path.approach) or relRest(best)
                        seats[#seats + 1] = { bone = cur.bones[best].name,
                            seat = packT(composeT(op.openPose, relRest(best))),
                            approach = packT(composeT(op.openPose, appRel)),
                            depth = path ~= nil and r3(path.depth) or 0 }
                    end
                end
            end
            if #seats > 0 then
                res.item.seats = seats
                res.item.seat, res.item.approach = seats[1].seat, seats[1].approach
                res.item.opener = op.bone
            end
        end
    end

    -- BL4 (2026-11-23, Jakobs pistol Mag02): the item rides on a part that swings open - Mag02_Cap -> Mag02_Spin ->
    -- Mag02_Break (55 deg). The game breaks the gun open, the cap goes into the open part, the part shuts (0.88 s) and
    -- only then does the ammo land (0.92 s): in gun space the cap is "home" only once the part is shut, so the seat came
    -- out as the closing frame and the part never opened in VR. When an ancestor of the item turns >= 30 deg, the
    -- item's path is taken relative to that part: seated = home relative to it; the seat / approach are placed at the
    -- part's pose at that moment (open); the part becomes an opener that carries the item (flick to close).
    if res.item ~= nil and res.item.bone ~= nil and not res.perRound and best ~= nil and res.item.seats == nil then
        local function composeT(a, b) local l = qrot(a.q, b.loc) return { loc = { X = a.loc.X + l.X, Y = a.loc.Y + l.Y, Z = a.loc.Z + l.Z }, q = qmul(a.q, b.q) } end
        local ii = best.bi
        local parentB = cur.byName[cur.bones[ii].parent]
        -- the item's ancestors that turn during the reload, outermost first (Mag02_Break, then Mag02_Spin: the cylinder's
        -- own 180 deg index turn - picking only the nearest one flipped the cylinder while the break stayed shut)
        local chain = {}
        local anc = parentB
        while anc ~= nil and anc.parent ~= "None" do
            local m = motion[anc.index]
            if m ~= nil and m.maxA >= 30 then table.insert(chain, 1, anc) end
            anc = cur.byName[anc.parent]
        end
        -- no turning ancestor (Jakobs break-action shotgun, 2026-11-23: the shells L/R_Barrel02_Shell are not under
        -- Magazine01_Break, which turns 72 deg and shuts exactly when the ammo lands): a hinge of the gun - a mechanism
        -- turning >= OPENER_MIN_DEG in place (< 3 cm), not a round, not cosmetic - carries the item virtually.
        -- Every candidate is tested and the one the item seats on EARLIEST (home relative to it while it is open) wins
        -- (Maliwan sniper 2026-11-23: Body_Break_Open and Body_Top_Break_Open both turn 25 deg; mag_02 rides the top one -
        -- home relative to it at 2.11 s, relative to the other only at 2.65 s as the gun shuts - and taking the first of
        -- the tie found no seat, so the gun opened at the wrong part). The ancestor chain, when there is one, comes first.
        local options = {}
        local cands = {}
        for mi, m in ipairs(res.mechanisms) do
            local mb = cur.byName[m.bone]
            local low = (m.bone or ""):lower()
            local roundy = low:find("shell", 1, true) or low:find("bullet", 1, true) or low:find("round", 1, true) or low:find("cartridge", 1, true)
            if mb ~= nil and (m.maxDeg or 0) >= OPENER_MIN_DEG and (m.maxCm or 0) < 3 and not itemSet[m.bone] and not roundy and not cosmeticBone(m.bone) then
                cands[#cands + 1] = { b = mb, maxDeg = m.maxDeg, order = mi }
            end
        end
        table.sort(cands, function(a, b)
            if a.maxDeg ~= b.maxDeg then return a.maxDeg > b.maxDeg end
            return a.order < b.order
        end)
        for _, c in ipairs(cands) do options[#options + 1] = { chain = { c.b }, refB = c.b, virtual = true } end
        -- dry = only test: returns the seat frame index when the item seats on this carrier while it is open
        local function tryCarrier(chain, refB, virtual, dry)
            if refB == nil or rest[refB.index] == nil then return false end
            local pi = refB.index
            local restRel = relT(rest[pi], rest[ii])
            local function relAt(k)
                local c, t = frames[k].bones[pi], frames[k].bones[ii]
                if c == nil or t == nil then return nil end
                return relT(c, t)
            end
            -- seated = home relative to its own parent (whatever the parts above it do), staying home from then on
            local away, ks = false, nil
            for k = 1, #frames do
                local r = relAt(k)
                if r ~= nil then
                    local d = dist(r.loc, restRel.loc)
                    if d > 1.0 then away, ks = true, nil
                    elseif away and ks == nil then ks = k end
                end
            end
            local openAny = false
            if ks ~= nil then
                for _, c in ipairs(chain) do
                    local p = frames[ks].bones[c.index]
                    if p ~= nil and rest[c.index] ~= nil and qangle(p.q, rest[c.index].q) >= 20 then openAny = true end
                end
            end
            if dry then return openAny and ks or false end
            if openAny then
                local parentAt = frames[ks].bones[pi]
                local a = ks
                while a > 1 do
                    local r0, r1 = relAt(a - 1), relAt(a)
                    if r0 == nil or r1 == nil then break end
                    if dist(r0.loc, restRel.loc) > APPROACH_MAX_CM or dist(r0.loc, r1.loc) > 8.0 then break end
                    a = a - 1
                end
                local seatC = composeT(parentAt, restRel)
                local appC = composeT(parentAt, relAt(a) or restRel)
                local it = res.item
                it.seat = packT(seatC)
                it.approach = packT(appC)
                it.depth = r3(dist(seatC.loc, appC.loc))
                local ax = vnorm(vsub(seatC.loc, appC.loc))
                it.axis = { X = r3(ax.X), Y = r3(ax.Y), Z = r3(ax.Z) }
                it.seatT = r3(frames[ks].t)
                it.docked = nil
                it.opener = chain[1].name
                if virtual then it.virtualCarrier = chain[1].name end
                -- openers: the turned ancestors (outermost first, they carry the item), then every other part that is
                -- open at that moment and back at rest by the end (Accessory02_Hinge hinges with the break)
                local chainSet = {}
                for _, c in ipairs(chain) do chainSet[c.name] = true end
                local mechs = {}
                for _, c in ipairs(chain) do
                    local p = frames[ks].bones[c.index]
                    if p ~= nil and rest[c.index] ~= nil and qangle(p.q, rest[c.index].q) >= 10 then
                        mechs[#mechs + 1] = { bone = c.name, rest = packT(rest[c.index]), openPose = packT(p), opener = true,
                            carriesItem = true, maxDeg = r3(qangle(p.q, rest[c.index].q)), maxCm = 0 }
                    end
                end
                for _, m in ipairs(res.mechanisms) do
                    if not chainSet[m.bone] then
                        local b = cur.byName[m.bone]
                        local p = b and frames[ks].bones[b.index] or nil
                        local r = b and rest[b.index] or nil
                        if p ~= nil and r ~= nil and motion[b.index].endRest and (qangle(p.q, r.q) >= 20 or dist(p.loc, r.loc) >= 1.0) then
                            m.opener, m.openPose = true, packT(p)
                        end
                        mechs[#mechs + 1] = m
                    end
                end
                res.mechanisms = mechs
                -- the whole open pose (2026-11-23, a test screenshot: the cap seated beside the cylinder - opening only the
                -- chosen parts left linked ones where they were): every bone outside the item that is off its rest when the
                -- item seats, parent-first, so manual reload opens the gun into exactly the game's pose
                local openFrame = {}
                for i, b in ipairs(cur.bones) do
                    local p, r = frames[ks].bones[i], rest[i]
                    if not itemSet[b.name] and not (cur.unfitted and cur.unfitted[b.name]) and p ~= nil and r ~= nil
                        and (dist(p.loc, r.loc) > 0.3 or qangle(p.q, r.q) > 2) then
                        openFrame[#openFrame + 1] = { bone = b.name, open = packT(p), rest = packT(r) }
                    end
                end
                if #openFrame > 0 then it.openFrame = openFrame end
                local names = {}
                for _, c in ipairs(chain) do names[#names + 1] = c.name end
                info(string.format("item rides on %s: seated at %.2f s, insert depth %.1f cm", table.concat(names, " > "), frames[ks].t, it.depth))
                return true
            end
            return false
        end
        -- the ancestor chain when the item seats on it; otherwise the hinge the item seats on EARLIEST (relative to its
        -- real carrier it is home while the gun is open; relative to any other hinge only once everything has shut)
        local done = false
        if #chain > 0 then done = tryCarrier(chain, parentB, false) end
        if not done then
            local pick, pickKs = nil, nil
            for _, o in ipairs(options) do
                local k = tryCarrier(o.chain, o.refB, true, true)
                if k and (pickKs == nil or k < pickKs) then pick, pickKs = o, k end
            end
            if pick ~= nil then tryCarrier(pick.chain, pick.refB, true) end
        end
    end
    return res
end

-- Cronos (2026-11-26, handgun): the OLD magazine is another bone than the new one - GG_cartridge flies out of the
-- well (71 cm) and snaps back hidden, while GG_cartridge_02 is the fresh one the hand brings in (the Arbalest flings its
-- spent bolt AnnG_ammo_01 2 m away). Bones outside the item that leave the gun as far as an item does, starting in
-- place: ejected. Manual reload hides them for the reload (the drop copy shows the magazine falling out) and gives them
-- back to the game at the end. Run on every result (the no-carried-part fallback returns early).
local function addEjected(res)
    local frames, rest = rec.frames, rec.rest
    if res.item == nil or #frames == 0 then return end
    local motion = boneMotion(frames, rest)
    local itemSet = {}
    for _, n in ipairs(res.item.bones or {}) do itemSet[n] = true end
    for _, g in ipairs(res.item.group or {}) do for _, n in ipairs(subtreeOf(g.bone)) do itemSet[n] = true end end
    local ej = {}
    for i, b in ipairs(cur.bones) do
        local m = motion[i]
        if not itemSet[b.name] and not cosmeticBone(b.name) and m.maxD >= ITEM_MIN_TRAVEL
            and frames[1].bones[i] ~= nil and rest[i] ~= nil and dist(frames[1].bones[i].loc, rest[i].loc) < 5.0 then
            local parent = cur.byName[b.parent]
            local parentFar = parent ~= nil and motion[parent.index] ~= nil and motion[parent.index].maxD >= ITEM_MIN_TRAVEL
                and not itemSet[parent.name]
            if not parentFar then ej[#ej + 1] = b.name end
        end
    end
    if #ej > 0 then
        res.ejected = ej
        info("ejected at the reload start: " .. table.concat(ej, ", "))
    end
end

-- A rack follows the hand that works it (Cronos 2026-11-26, handgun GG_slide: locked back for the reload, it springs
-- home by itself 0.3 s after the magazine seats - the hand was 9 cm off only because it was pushing the magazine in).
-- Over the frames where the part moves, the rack hand's offset in the part's frame must stay steady (spread <= 3 cm).
local function rackFollowsHand(rk)
    local b = cur.byName[rk.bone]
    if b == nil then return false, "no bone" end
    local hk = rk.hand == "right" and "r" or "l"
    local i = b.index
    local offs, prev = {}, nil
    for _, f in ipairs(rec.frames) do
        local p, h = f.bones[i], f[hk]
        if p ~= nil and prev ~= nil and h ~= nil and (dist(p.loc, prev.loc) > 0.2 or qangle(p.q, prev.q) > 1.0) then
            offs[#offs + 1] = relT(p, h).loc
        end
        if p ~= nil then prev = p end
    end
    if #offs < 2 then return false, "moves in under 2 frames" end
    local m = { X = 0, Y = 0, Z = 0 }
    for _, o in ipairs(offs) do m = { X = m.X + o.X, Y = m.Y + o.Y, Z = m.Z + o.Z } end
    m = { X = m.X / #offs, Y = m.Y / #offs, Z = m.Z / #offs }
    local spread = 0
    for _, o in ipairs(offs) do spread = math.max(spread, dist(o, m)) end
    return spread <= 3.0, string.format("hand spread %.1f cm over %d moving frames", spread, #offs)
end

function M.analyze(ctx)
    cur = { bones = ctx.bones, byName = ctx.byName, unfitted = nil }
    rec = { frames = ctx.frames, rest = ctx.rest, fingers = ctx.fingers or {}, empty = ctx.empty == true,
            hasEmpty = ctx.hasEmpty, key = ctx.key, hiddenAtEnd = ctx.hiddenAtEnd or {}, perNotify = ctx.perNotify }
    ctxProfiles = ctx.profiles or {}
    info = ctx.info or function(s) end
    local res, why = analyze()
    if res ~= nil then
        addEjected(res)
        -- a rack the game's hand never comes near (its nearest grip) moves by itself: not a rack for the player
        if res.rack ~= nil and res.rack.grip ~= nil and res.rack.grip.loc ~= nil and vlen(res.rack.grip.loc) > RACK_HAND_CM then
            info(string.format("rack %s dropped: the hand never comes within %.0f cm of it (%.1f cm)", tostring(res.rack.bone), RACK_HAND_CM, vlen(res.rack.grip.loc)))
            res.rack = nil
        end
        if res.rack ~= nil and not res.rack.crank then
            local follows, why2 = rackFollowsHand(res.rack)
            if not follows then
                info("rack " .. tostring(res.rack.bone) .. " dropped: it does not follow the hand (" .. tostring(why2) .. ")")
                res.rack = nil
            end
        end
        -- the bones the game hides at the end of its reload (manual reload leaves the item / ejected bones that way)
        local h = {}
        for n in pairs(rec.hiddenAtEnd) do h[#h + 1] = n end
        table.sort(h)
        res.hiddenAfter = h
    end
    return res, why
end

-- exposed for the recorder / manual reload
M.relT, M.copyT, M.packT, M.qangle, M.dist, M.qmul, M.qconj, M.qrot = relT, copyT, packT, qangle, dist, qmul, qconj, qrot
M.ITEM_MIN_TRAVEL = ITEM_MIN_TRAVEL
return M
