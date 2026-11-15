-- Webs: the Dreadweaver's silk (PROJECT.md: Interfaces). Server: sticky patches on surfaces, web shots in flight,
-- the lines it rode left hanging, who is slowed. Client: drawing all of it, the screen of someone stuck, the sounds.
--
-- Cheap by design (the user: "having a lot of webbed surfaces ... find a clever way to make it cost less or make them
-- disappear after a few minutes"): a web is nine numbers in a list - no entity, no shape, no physics. Touching one is
-- a few lines of arithmetic per player; drawing one is two flat sprites (plus a few hanging drips up close). There
-- are at most WEB_MAX patches (the oldest goes), each fades after WEB_LIFE seconds, a new one landing on an old one
-- only renews it, and the list is sent to the clients only when it changes.

Webs = {}

WEB_MAX = 40
WEB_LIFE = 180               -- s a patch lasts (the last WEB_FADE of it fading)
WEB_FADE = 14
WEB_MERGE = 0.9              -- m: a patch landing this close to another (same facing) renews that one
LINE_MAX = 10
LINE_LIFE = 240              -- s a line stays strung where it was shot (renewed each time the spider uses it again)
LINE_TOUCH = 0.55            -- m from a line: a player is caught on it (slowed as in a web)
SHOT_SPEED = 26
SHOT_G = 6                   -- m/s2: a glob drops a little
SHOT_LIFE = 3.5
SHOT_HIT = 0.75              -- m from a player's chest line: wrapped
WRAP_T = 4.5                 -- s a player hit by a shot is wrapped
SLOW_WALK = {2.3, 1.2}       -- walking speed in a web / wrapped (the game's is 7)
SLOW_CAP = {2.6, 1.4}        -- m/s: their level speed is held to this
SLOW_JUMP = {2.4, 1.2}       -- m/s: ... and their upward speed (the web holds on)

local function now() return GetTime() end
local function dist(a, b) return VecLength(VecSub(a, b)) end

-- how far a line of length len hangs below the straight at its middle (the spider rides it along the same curve)
function wbSag(len) return math.min(0.8, 0.03 * len) end

-- point u (0..1) of the line from a to b
function wbLinePoint(a, b, u)
	local q = VecLerp(a, b, u)
	q[2] = q[2] - wbSag(dist(a, b)) * math.sin(math.pi * u)
	return q
end

-- distance from point p to the segment a-b
local function segDist(p, a, b)
	local ab = VecSub(b, a)
	local l2 = VecDot(ab, ab)
	local u = l2 > 1e-9 and math.max(0, math.min(1, VecDot(VecSub(p, a), ab) / l2)) or 0
	return dist(p, VecAdd(a, VecScale(ab, u)))
end

----- server -----

function Webs.serverInit()
	wbPatches = {}             -- {pos, n, r, born, seed}
	wbLines = {}               -- {a, b, born}
	wbShots = {}               -- {pos, vel, born, owner}
	wbWrap = {}                -- player -> until
	wbLevel = {}               -- player -> 0 / 1 / 2
	wbSeq, wbShotSeq = 0, 0
	wbDirty, wbShotDirty = true, true
	wbPubT = 0
	wbEv = {splat = 0, sx = 0, sy = 0, sz = 0, stick = 0, tx = 0, ty = 0, tz = 0, wrap = 0}
	wbBright = 0.6
	wbBrightT = -100
end

-- a sticky patch on the surface at p (normal n), radius r
function Webs.addPatch(p, n, r)
	local t = now()
	for _, w in ipairs(wbPatches) do
		if dist(w.pos, p) < WEB_MERGE and VecDot(w.n, n) > 0.7 then
			w.born = t
			w.r = math.max(w.r, r)
			wbDirty = true
			return w
		end
	end
	if #wbPatches >= WEB_MAX then
		local oi, ob = 1, 1e18
		for i, w in ipairs(wbPatches) do if w.born < ob then oi, ob = i, w.born end end
		table.remove(wbPatches, oi)
	end
	local w = {pos = VecCopy(p), n = VecNormalize(n), r = r, born = t, seed = math.random(1, 9999)}
	wbPatches[#wbPatches + 1] = w
	wbDirty = true
	return w
end

-- the line it shot from a (on the surface it left, normal an) to b (the anchor, normal bn) stays strung: players
-- who touch it are slowed, and the spider uses it again as a way across (spider.lua: spLineRoute)
function Webs.addLine(a, an, b, bn)
	if #wbLines >= LINE_MAX then
		local oi, ob = 1, 1e18
		for i, l in ipairs(wbLines) do if l.born < ob then oi, ob = i, l.born end end
		table.remove(wbLines, oi)
	end
	local l = {a = VecCopy(a), an = VecCopy(an), b = VecCopy(b), bn = VecCopy(bn), born = now(), len = dist(a, b)}
	wbLines[#wbLines + 1] = l
	wbDirty = true
	return l
end

function Webs.lines() return wbLines end

-- the spider used a line again: it is as good as new
function Webs.renewLine(l)
	l.born = now()
	wbDirty = true
end

-- is a player standing at `feet` touching line l? (the line as six straight pieces; ankles, chest, head)
function wbLineTouch(l, feet)
	local lo, hi = math.min(l.a[2], l.b[2]) - 1, math.max(l.a[2], l.b[2]) + 0.6
	if feet[2] + 1.8 < lo or feet[2] > hi then return false end
	local prev = l.a
	for i = 1, 6 do
		local q = wbLinePoint(l.a, l.b, i / 6)
		for _, h in ipairs({0.3, 1.0, 1.7}) do
			if segDist(Vec(feet[1], feet[2] + h, feet[3]), prev, q) < LINE_TOUCH then return true end
		end
		prev = q
	end
	return false
end

function Webs.shoot(from, vel, owner)
	wbShots[#wbShots + 1] = {pos = VecCopy(from), vel = VecCopy(vel), born = now(), owner = owner}
	wbShotDirty = true
end

function Webs.wrap(p, secs)
	wbWrap[p] = math.max(wbWrap[p] or 0, now() + secs)
	wbEv.wrap = wbEv.wrap + 1
end

-- 0 free, 1 standing in a web, 2 wrapped by a shot
function Webs.level(p) return wbLevel[p] or 0 end

function Webs.count() return #wbPatches end

-- is point q (a player's feet) in patch w? A floor web holds the feet, a wall's whoever leans on it, a ceiling's
-- whoever's head reaches it
function wbTouch(w, feet)
	local n = w.n
	local q = feet
	if n[2] < -0.5 then q = VecAdd(feet, Vec(0, 1.8, 0)) elseif n[2] < 0.5 then q = VecAdd(feet, Vec(0, 0.9, 0)) end
	local d = VecSub(q, w.pos)
	local along = VecDot(d, n)
	if along < -0.5 or along > (n[2] > 0.5 and 0.55 or 0.8) then return false end
	local lat = VecSub(d, VecScale(n, along))
	return VecLength(lat) < w.r
end

function wbFeet(p) return Prey.feet(p) end

-- a shot lands: a patch where it hit
local function land(s, p, n)
	Webs.addPatch(p, n, 1.4 + math.random() * 0.5)
	wbEv.splat = wbEv.splat + 1
	wbEv.sx, wbEv.sy, wbEv.sz = p[1], p[2], p[3]
	wbShotDirty = true
end

local function shotStep(s, dt)
	local nxt = VecAdd(s.pos, VecScale(s.vel, dt))
	local d = VecSub(nxt, s.pos)
	local l = VecLength(d)
	if l < 1e-5 then return false end
	local dir = VecScale(d, 1 / l)
	-- a player in the way: wrapped, and a web at their feet
	for _, p in ipairs(Prey.all()) do
		if not Prey.inVehicle(p) then
			local feet = wbFeet(p)
			local chest = VecAdd(feet, Vec(0, 1.0, 0))
			local rel = VecSub(chest, s.pos)
			local along = math.max(0, math.min(l, VecDot(rel, dir)))
			local near = VecAdd(s.pos, VecScale(dir, along))
			local off = VecSub(chest, near)
			if math.abs(off[2]) < 1.0 and VecLength(Vec(off[1], 0, off[3])) < SHOT_HIT then
				Webs.wrap(p, WRAP_T)
				QueryRequire("physical static")
				QueryCollisionMask(DW_MASK)
				local hit, hd, hn = QueryRaycast(VecAdd(feet, Vec(0, 0.5, 0)), Vec(0, -1, 0), 2.5)
				if hit then land(s, VecAdd(feet, Vec(0, 0.5 - hd, 0)), hn) else
					wbEv.splat = wbEv.splat + 1
					wbEv.sx, wbEv.sy, wbEv.sz = chest[1], chest[2], chest[3]
				end
				return false
			end
		end
	end
	QueryRequire("physical")
	QueryCollisionMask(DW_MASK)
	local hit, hd, hn = QueryRaycast(s.pos, dir, l, 0.06)
	if hit then
		land(s, VecAdd(s.pos, VecScale(dir, hd)), hn)
		return false
	end
	s.pos = nxt
	s.vel = VecAdd(s.vel, Vec(0, -SHOT_G * dt, 0))
	return now() - s.born < SHOT_LIFE
end

function Webs.serverUpdate(dt)
	Prey.dirty()
	for i = #wbShots, 1, -1 do
		if not shotStep(wbShots[i], dt) then
			table.remove(wbShots, i)
			wbShotDirty = true
		end
	end
	-- the web holds on: slowed players' speed is capped (the walking speed alone leaves jumps and slides)
	for p, lvl in pairs(wbLevel) do
		if lvl > 0 and Prey.isPlayer(p) and IsPlayerValid(p) and GetPlayerHealth(p) > 0 and GetPlayerVehicle(p) == 0 then
			local v = GetPlayerVelocity(p)
			local h = math.sqrt(v[1] * v[1] + v[3] * v[3])
			local cap, up = SLOW_CAP[lvl], SLOW_JUMP[lvl]
			if h > cap or v[2] > up then
				local k = h > cap and cap / h or 1
				SetPlayerVelocity(Vec(v[1] * k, math.min(v[2], up), v[3] * k), p)
			end
		end
	end
end

local function publishWebs()
	wbSeq = wbSeq + 1
	local P, L = {}, {}
	for _, w in ipairs(wbPatches) do
		local k = #P
		P[k + 1], P[k + 2], P[k + 3] = w.pos[1], w.pos[2], w.pos[3]
		P[k + 4], P[k + 5], P[k + 6] = w.n[1], w.n[2], w.n[3]
		P[k + 7], P[k + 8], P[k + 9] = w.r, w.born, w.seed
	end
	for _, l in ipairs(wbLines) do
		local k = #L
		L[k + 1], L[k + 2], L[k + 3] = l.a[1], l.a[2], l.a[3]
		L[k + 4], L[k + 5], L[k + 6] = l.b[1], l.b[2], l.b[3]
		L[k + 7] = l.born
	end
	shared.dwWebs = {n = wbSeq, p = P, l = L, b = wbBright}
end

local function publishShots()
	wbShotSeq = wbShotSeq + 1
	local S, slow = {}, {}
	for _, s in ipairs(wbShots) do
		local k = #S
		S[k + 1], S[k + 2], S[k + 3] = s.pos[1], s.pos[2], s.pos[3]
		S[k + 4], S[k + 5], S[k + 6] = s.vel[1], s.vel[2], s.vel[3]
	end
	for p, lvl in pairs(wbLevel) do
		if lvl > 0 and Prey.isPlayer(p) then slow[#slow + 1] = p; slow[#slow + 1] = lvl end
	end
	local e = wbEv
	shared.dwShots = {n = wbShotSeq, t = now(), s = S, slow = slow, splat = e.splat, sx = e.sx, sy = e.sy, sz = e.sz,
		stick = e.stick, tx = e.tx, ty = e.ty, tz = e.tz, wrap = e.wrap}
end

function Webs.serverTick(dt)
	Prey.dirty()
	local t = now()
	-- old webs and lines go
	for i = #wbPatches, 1, -1 do
		if t - wbPatches[i].born > WEB_LIFE then table.remove(wbPatches, i); wbDirty = true end
	end
	for i = #wbLines, 1, -1 do
		if t - wbLines[i].born > LINE_LIFE then table.remove(wbLines, i); wbDirty = true end
	end
	-- a blast tears webs away
	for i = 1, GetEventCount("explosion") do
		local point, strength = GetEvent("explosion", i)
		local r = 2.5 * (strength or 1)
		for k = #wbPatches, 1, -1 do
			if dist(wbPatches[k].pos, point) < r then table.remove(wbPatches, k); wbDirty = true end
		end
		for k = #wbLines, 1, -1 do
			local l = wbLines[k]
			if segDist(point, l.a, l.b) < r then table.remove(wbLines, k); wbDirty = true end
		end
	end
	-- who is held
	for _, p in ipairs(Prey.all()) do
		local lvl = 0
		if not Prey.inVehicle(p) then
			if (wbWrap[p] or 0) > t then
				lvl = 2
			else
				local feet = wbFeet(p)
				for _, w in ipairs(wbPatches) do
					if wbTouch(w, feet) then lvl = 1; break end
				end
				if lvl == 0 then
					for _, l in ipairs(wbLines) do
						if wbLineTouch(l, feet) then lvl = 1; break end
					end
				end
			end
		end
		local was = wbLevel[p] or 0
		if lvl ~= was then
			wbLevel[p] = lvl
			wbShotDirty = true
			if lvl > 0 and was == 0 then
				local f = wbFeet(p)
				wbEv.stick = wbEv.stick + 1
				wbEv.tx, wbEv.ty, wbEv.tz = f[1], f[2] + 0.5, f[3]
			end
		end
		if lvl > 0 then                                                  -- (holds for one frame: set every tick)
			if Prey.isPlayer(p) then SetPlayerParam("walkingSpeed", SLOW_WALK[lvl], p) else Prey.slow(p, SLOW_WALK[lvl]) end
		end
	end
	for p, lv in pairs(wbLevel) do
		if not Prey.ok(p) then                                          -- (dead or gone: no longer held)
			if lv > 0 then wbShotDirty = true end
			wbLevel[p] = nil; wbWrap[p] = nil
		end
	end
	-- how bright the webs are drawn: sprites are unlit, so by the sky (a dark map: dim webs)
	if t - wbBrightT > 5 then
		wbBrightT = t
		local ok, v = pcall(GetEnvironmentProperty, "skyboxbrightness")
		local b = 0.18 + 0.32 * math.max(0, math.min(1, (ok and type(v) == "number") and v or 0.6))
		if math.abs(b - wbBright) > 0.03 then wbBright = b; wbDirty = true end
	end
	if wbDirty then
		wbDirty = false
		publishWebs()
	end
	if wbShotDirty or (#wbShots > 0 and t - wbPubT > 1 / 15) then
		wbShotDirty = false
		wbPubT = t
		publishShots()
	end
end

----- client -----

function Webs.clientInit()
	wbSpr = {web = {}, strand = LoadSprite("MOD/gfx/strand.png"), glob = LoadSprite("MOD/gfx/glob.png"),
		drip = LoadSprite("MOD/gfx/drip.png")}
	for i = 0, 2 do wbSpr.web[i + 1] = LoadSprite("MOD/gfx/web" .. i .. ".png") end
	wbSnd = {splat = {}, stick = {}}
	local S = SPIDER_SOUNDS or {}
	for k, l in pairs(wbSnd) do
		for _, f in ipairs(S[k] or {}) do l[#l + 1] = LoadSound(f) end
	end
	wbC = {n = -1, sn = -1, p = {}, l = {}, s = {}, slow = {}, b = 0.6, clock = 0, ev = nil, sT = 0, sSrv = 0, over = 0, lvl = 0}
end

local function wbPlay(kind, pos, vol)
	local l = wbSnd[kind]
	if not l or #l == 0 then return end
	PlaySound(l[math.random(#l)], pos, vol or 1, false, 0.9 + math.random() * 0.2)
end

-- two unit vectors across n
local function tangents(n)
	local a = math.abs(n[2]) < 0.9 and Vec(0, 1, 0) or Vec(1, 0, 0)
	local x = VecNormalize(VecCross(a, n))
	return x, VecCross(n, x)
end

-- a strand from a to b, w wide, turned to face the camera
local function strand(a, b, w, c, alpha, cam)
	local d = VecSub(b, a)
	local l = VecLength(d)
	if l < 0.02 then return end
	local x = VecScale(d, 1 / l)
	local mid = VecLerp(a, b, 0.5)
	local toCam = VecSub(cam, mid)
	local z = VecSub(toCam, VecScale(x, VecDot(toCam, x)))
	if VecLength(z) < 0.01 then return end
	DrawSprite(wbSpr.strand, Transform(mid, QuatAlignXZ(x, VecNormalize(z))), l, w, c, c, c, alpha, true, false, true)
end
wbStrand = strand                                                  -- (the view draws the live line with it)

local function splatFx(p)
	ParticleReset()
	ParticleType("plain")
	ParticleColor(0.82, 0.84, 0.7, 0.6, 0.62, 0.5)
	ParticleRadius(0.05, 0.02)
	ParticleAlpha(0.9, 0)
	ParticleGravity(-7)
	ParticleDrag(0.3)
	ParticleSticky(0.6)
	ParticleCollide(1)
	for _ = 1, 16 do
		SpawnParticle(p, Vec((math.random() - 0.5) * 6, math.random() * 4, (math.random() - 0.5) * 6), 0.5 + math.random() * 0.8)
	end
end

function Webs.clientTick(dt)
	local C = wbC
	local W = shared.dwWebs
	if W and W.n ~= C.n then                                        -- (copy: shared hands out copies, keep ours)
		C.n = W.n
		C.p, C.l, C.b = {}, {}, W.b or 0.6
		for i, x in ipairs(W.p or {}) do C.p[i] = x end
		for i, x in ipairs(W.l or {}) do C.l[i] = x end
	end
	local S = shared.dwShots
	if S and S.n ~= C.sn then
		C.sn = S.n
		C.s, C.slow = {}, {}
		for i, x in ipairs(S.s or {}) do C.s[i] = x end
		for i, x in ipairs(S.slow or {}) do C.slow[i] = x end
		C.sT, C.sSrv = GetTime(), S.t or 0
		local prev = C.ev
		if prev then
			if (S.splat or 0) > prev.splat then
				local p = Vec(S.sx, S.sy, S.sz)
				wbPlay("splat", p, 1)
				splatFx(p)
			end
		end
		C.ev = {splat = S.splat or 0, stick = S.stick or 0}
	end
	-- the sticky sound of someone held by a web or caught on a line: when it takes hold, and again and again while
	-- they pull against it
	C.stickT = C.stickT or {}
	local held = {}
	for k = 1, #C.slow, 2 do
		local p = C.slow[k]
		held[p] = true
		if IsPlayerValid(p) then
			local now = GetTime()
			local fresh = C.stickT[p] == nil
			if fresh or (now > C.stickT[p] and VecLength(GetPlayerVelocity(p)) > 0.4) then
				C.stickT[p] = now + 0.7 + math.random() * 0.7
				wbPlay("stick", VecAdd(GetPlayerTransform(p).pos, Vec(0, 0.6, 0)), fresh and 1 or 0.7)
			end
		end
	end
	for p in pairs(C.stickT) do if not held[p] then C.stickT[p] = nil end end
	local D = shared.dw
	local srv = (D and D.t) or GetTime()                             -- (the server's clock, for ages)
	if srv ~= C.srvSeen then C.srvSeen = srv; C.srvAt = GetTime() end
	local t = srv + (GetTime() - (C.srvAt or GetTime()))
	local camT = GetCameraTransform()
	local cam = camT.pos
	local c = C.b
	-- patches: two flat layers, and a few drips where they hang
	local P = C.p
	for k = 1, #P, 9 do
		local pos = Vec(P[k], P[k + 1], P[k + 2])
		local d = dist(pos, cam)
		if d < 75 then
			local n = Vec(P[k + 3], P[k + 4], P[k + 5])
			local r, age, seed = P[k + 6], t - P[k + 7], P[k + 8]
			local a = math.max(0, math.min(1, (WEB_LIFE - age) / WEB_FADE))
			local grow = math.min(1, 0.3 + math.max(0, age) / 0.35 * 0.7)       -- (it spreads as it lands)
			if a > 0.01 then
				local x, y = tangents(n)
				local ang = seed * 0.61
				local xr = VecAdd(VecScale(x, math.cos(ang)), VecScale(y, math.sin(ang)))
				local spr = wbSpr.web[seed % 3 + 1]
				DrawSprite(spr, Transform(VecAdd(pos, VecScale(n, 0.04)), QuatAlignXZ(xr, n)), 2 * r * grow, 2 * r * grow,
					c, c, c * 0.92, a * 0.95, true, false, true)
				if d < 40 then
					local xr2 = VecAdd(VecScale(x, math.cos(ang + 2.2)), VecScale(y, math.sin(ang + 2.2)))
					DrawSprite(wbSpr.web[(seed + 1) % 3 + 1], Transform(VecAdd(pos, VecScale(n, 0.09)), QuatAlignXZ(xr2, n)),
						1.5 * r * grow, 1.5 * r * grow, c, c, c * 0.92, a * 0.7, true, false, true)
				end
				if d < 28 and n[2] < 0.35 then                           -- (walls and ceilings: slime hanging off it)
					for j = 1, 3 do
						local s1 = math.sin(seed * 1.7 + j * 2.4)
						local s2 = math.cos(seed * 0.9 + j * 1.9)
						local at = VecAdd(pos, VecAdd(VecScale(x, s1 * r * 0.55), VecScale(y, s2 * r * 0.55)))
						at = VecAdd(at, VecScale(n, 0.08))
						local len = (0.35 + 0.5 * math.abs(s1 * s2) + 0.2 * j) * grow * (n[2] < -0.5 and 1.4 or 0.8)
						local sway = math.sin(GetTime() * 0.9 + seed + j) * 0.04 * len
						local toCam = VecSub(cam, at)
						local z = Vec(toCam[1], 0, toCam[3])
						if VecLength(z) > 0.05 then
							z = VecNormalize(z)
							local xx = VecCross(Vec(0, 1, 0), z)
							DrawSprite(wbSpr.drip, Transform(VecAdd(at, Vec(sway, -len / 2, 0)), QuatAlignXZ(xx, z)), 0.16, len,
								c, c, c * 0.9, a * 0.9, true, false, true)
						end
					end
				end
			end
		end
	end
	-- the lines it shot: strung where they are, swaying a little
	local L = C.l
	for k = 1, #L, 7 do
		local a, b = Vec(L[k], L[k + 1], L[k + 2]), Vec(L[k + 3], L[k + 4], L[k + 5])
		local age = t - L[k + 6]
		local alpha = math.max(0, math.min(1, (LINE_LIFE - age) / 8))
		if alpha > 0.01 and (dist(a, cam) < 90 or dist(b, cam) < 90) then
			local prev = a
			for i = 1, 6 do
				local u = i / 6
				local q = wbLinePoint(a, b, u)
				q[2] = q[2] + math.sin(GetTime() * 0.7 + u * 5 + k) * 0.02 * math.sin(math.pi * u)
				strand(prev, q, 0.07, c, alpha * 0.9, cam)
				prev = q
			end
		end
	end
	-- shots in flight: a glob with a tail (extrapolated between the server's updates)
	local Sh = C.s
	local ext = math.min(0.3, GetTime() - C.sT)
	for k = 1, #Sh, 6 do
		local v = Vec(Sh[k + 3], Sh[k + 4], Sh[k + 5])
		local p = VecAdd(Vec(Sh[k], Sh[k + 1], Sh[k + 2]), VecScale(v, ext))
		p[2] = p[2] - 0.5 * SHOT_G * ext * ext
		DrawSprite(wbSpr.glob, Transform(p, camT.rot), 0.42, 0.42, 0.9, 0.9, 0.82, 1, true, false, false)
		local sp = VecLength(v)
		if sp > 0.1 then strand(VecSub(p, VecScale(v, 1.6 / sp)), p, 0.1, 0.85, 0.9, cam) end
	end
end

-- the screen of someone held by a web
function Webs.clientDraw()
	local C = wbC
	local me = GetLocalPlayer()
	local lvl = 0
	for k = 1, #C.slow, 2 do if C.slow[k] == me then lvl = C.slow[k + 1] end end
	if lvl > 0 then C.lvl = lvl end
	local want = lvl == 2 and 0.9 or (lvl == 1 and 0.55 or 0)
	C.over = C.over + (want - C.over) * math.min(1, GetTimeStep() * (want > C.over and 8 or 2.5))
	if C.over < 0.01 then return end
	UiPush()
	UiPush()
	UiColor(1, 1, 1, C.over)
	UiScale(UiWidth() / 1280, UiHeight() / 720)                    -- (the picture is 1280 x 720: over the whole screen)
	UiImage("MOD/gfx/overlay.png")
	UiPop()
	UiTranslate(UiCenter(), UiHeight() * 0.78)
	UiAlign("center middle")
	UiFont("bold.ttf", 30)
	UiColor(0.9, 0.92, 0.8, math.min(1, C.over * 1.4))
	UiText(C.lvl == 2 and "WRAPPED IN WEB" or "STUCK IN A WEB")
	UiPop()
end
