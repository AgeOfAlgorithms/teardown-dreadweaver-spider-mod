-- SpiderView: what each machine draws and hears of the Dreadweavers (PROJECT.md: Interfaces). Every client spawns
-- its own parts (one body per part, 0.05 m voxels, colliding with nothing) and poses them from shared.dw, a publish
-- interval in the past so it can blend between two updates. The legs are its life: each foot is planted on the real
-- surface under it (a closest-point query when it steps) and stays there while the body moves on, until it is too
-- far from where it belongs; then it steps, in two alternating groups of four, faster the faster the spider runs.
-- Each leg is two bones solved from hip to foot with the knee held high. On top: breathing, the abdomen's pulse, the
-- head's jerky looks, feeling pedipalps, twitching fangs, a front leg lifted to taste the air, the threat pose
-- (front legs raised, fangs wide), legs gathered on a web line or flung wide in a leap, the death curl; the red
-- eyes (emissive + a small light); green smoke where it is hit; and its voice, only while it hunts.

SpiderView = {}

SV_PARK = Vec(0, -1000, 0)
SV_LOOPS = {skitter = true}
-- where each pair's feet rest, in the body's frame: degrees from straight ahead, m out
SV_REST = {{38, 1.45}, {72, 1.25}, {108, 1.2}, {145, 1.4}}
SV_FAR = 110                  -- m from the camera: beyond it the legs are not posed
SV_MID, SV_LOW = 70, 140      -- m from the camera: beyond these it is posed every 2nd / every 4th frame (in turns)

local function dist(a, b) return VecLength(VecSub(a, b)) end
local function rnd(a, b) return a + math.random() * (b - a) end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

function svLoadSounds()
	svSnd = {}
	for k, list in pairs(SPIDER_SOUNDS or {}) do
		svSnd[k] = {}
		for _, f in ipairs(list) do
			svSnd[k][#svSnd[k] + 1] = SV_LOOPS[k] and LoadLoop(f) or LoadSound(f)
		end
	end
end

function svPlay(kind, pos, vol)
	local l = svSnd[kind]
	if not l or #l == 0 then return end
	PlaySound(l[math.random(#l)], pos, vol or 1, false, 0.9 + math.random() * 0.2)
end

----- the parts -----

local function spawnPart(def)
	local xml = string.format("<body dynamic='true' tags='dreadweaverview nocull'><vox tags='nocull' file='%s' scale='%.2f'/></body>",
		def.file, (SPIDER_PARTS.voxel or 0.05) / 0.1)
	local ok, ents = pcall(Spawn, xml, Transform(SV_PARK))
	if not ok or type(ents) ~= "table" then return nil end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			local shapes = GetBodyShapes(h) or {}
			for _, s in ipairs(shapes) do SetShapeCollisionFilter(s, DW_LAYER, 0) end
			return {body = h, shapes = shapes, centred = false, def = def}
		end
	end
	return nil
end

-- each part's voxel box centred on its body's origin (the points in SPIDER_PARTS are relative to the box centre);
-- a fresh shape can read 0 in its spawn frame, so this waits for real sizes
local function centre(q)
	if q.centred then return true end
	for _, sh in ipairs(q.shapes) do
		if not IsHandleValid(sh) then return false end
		local x, y, z, vs = GetShapeSize(sh)
		if not x or x <= 0 or not vs or vs <= 0 then return false end
	end
	for _, sh in ipairs(q.shapes) do
		local t = GetShapeLocalTransform(sh)
		local x, y, z, vs = GetShapeSize(sh)
		local c = TransformToParentPoint(t, Vec(x * vs / 2, y * vs / 2, z * vs / 2))
		SetShapeLocalTransform(sh, Transform(VecSub(t.pos, c), t.rot))
	end
	q.centred = true
	return true
end

local function V3(p) return Vec(p[1], p[2], p[3]) end

function svSpawn()
	local P = SPIDER_PARTS
	local v = {parts = {}, legs = {}, ph = math.random() * 100, look = {y = 0, p = 0, ty = 0, tp = 0, next = 0},
		still = 0, hitSeq = nil, ev = nil, feel = nil, feelNext = GetTime() + rnd(2, 6), deadK = 0, lastAir = ""}
	local function add(def)
		local q = spawnPart(def)
		if q then v.parts[#v.parts + 1] = q end
		return q
	end
	v.ceph = add(P.ceph)
	v.abd = add(P.abdomen)
	v.fangs = {{q = add(P.fang_l), socket = V3(P.ceph.fang_l), pivot = V3(P.fang_l.pivot), side = 1},
		{q = add(P.fang_r), socket = V3(P.ceph.fang_r), pivot = V3(P.fang_r.pivot), side = -1}}
	v.palps = {{q = add(P.palp_l), socket = V3(P.ceph.palp_l), pivot = V3(P.palp_l.pivot), side = 1},
		{q = add(P.palp_r), socket = V3(P.ceph.palp_r), pivot = V3(P.palp_r.pivot), side = -1}}
	for i = 1, 4 do
		for _, side in ipairs({1, -1}) do
			local h = P.ceph.hips[i]
			local d = P.legs[i]
			local a = math.rad(SV_REST[i][1])
			v.legs[#v.legs + 1] = {pair = i, side = side, hip = Vec(h[1] * side, h[2], h[3]),
				upper = add(d.upper), lower = add(d.lower), la = d.upper.len, lb = d.lower.len,
				rest = Vec(side * math.sin(a) * SV_REST[i][2], -DW_RIDE, math.cos(a) * SV_REST[i][2] + 0.1),
				group = ((i + (side > 0 and 0 or 1)) % 2), planted = nil, step = nil, tw = 0}
		end
	end
	return v
end

function svDelete(v)
	for _, q in ipairs(v.parts) do if IsHandleValid(q.body) then Delete(q.body) end end
	v.parts = {}
end

----- maths -----

-- a rotation with local +z = z and local +y as near to y as it can be
local function frame(y, z)
	local x = VecCross(y, z)
	if VecLength(x) < 1e-3 then
		x = VecCross(math.abs(z[2]) < 0.9 and Vec(0, 1, 0) or Vec(1, 0, 0), z)
	end
	x = VecNormalize(x)
	return QuatAlignXZ(x, z), x
end

-- a bone's body: its prox point on a, its -z toward b, its back (+y) toward pole
local function bone(q, a, b, pole)
	if not q then return end
	local z = VecSub(a, b)
	local l = VecLength(z)
	if l < 1e-4 then return end
	z = VecScale(z, 1 / l)
	local rot = frame(pole, z)
	local d = q.def
	SetBodyTransform(q.body, Transform(VecSub(a, QuatRotateVec(rot, Vec(d.prox[1], d.prox[2], d.prox[3]))), rot))
end

-- the knee of a two-bone leg from h to f (lengths la, lb), bent toward pole
local function knee(h, f, la, lb, pole)
	local e = VecSub(f, h)
	local d = VecLength(e)
	if d < 1e-4 then return VecAdd(h, VecScale(pole, la)), f end
	e = VecScale(e, 1 / d)
	local dd = clamp(d, math.abs(la - lb) + 0.02, la + lb - 0.01)
	local x0 = (la * la - lb * lb + dd * dd) / (2 * dd)
	local hgt = math.sqrt(math.max(0, la * la - x0 * x0))
	local pp = VecSub(pole, VecScale(e, VecDot(pole, e)))
	if VecLength(pp) < 1e-3 then pp = Vec(0, 1, 0) end
	pp = VecNormalize(pp)
	local k = VecAdd(VecAdd(h, VecScale(e, x0)), VecScale(pp, hgt))
	return k, VecAdd(h, VecScale(e, dd))                              -- (the foot it can reach)
end

-- the surface point for a foot that wants to be at p (nil: nothing there)
local function footOn(p)
	QueryRequire("physical static")
	QueryCollisionMask(DW_MASK)
	local hit, cp = QueryClosestPoint(p, 0.75)
	if hit then return cp end
	return nil
end

----- blood: green smoke where it was hit -----

local function rv() return Vec(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) end

function svBlood(pos, dmg)
	local k = math.min(1, 0.35 + dmg / 25)
	ParticleReset()
	ParticleType("smoke")
	ParticleColor(0.22, 0.62, 0.1, 0.05, 0.2, 0.03)
	ParticleRadius(0.1 + 0.12 * k, 0.45 + 0.5 * k, "easeout")
	ParticleAlpha(0.95, 0, "easein")
	ParticleEmissive(0.35, 0, "easeout")
	ParticleGravity(0.4)
	ParticleDrag(0.8)
	ParticleCollide(0)
	for _ = 1, math.floor(5 + 9 * k) do
		SpawnParticle(VecAdd(pos, VecScale(rv(), 0.25)), VecAdd(VecScale(rv(), 1.6 + 2 * k), Vec(0, 0.6, 0)), 1.6 + 1.8 * math.random())
	end
	ParticleReset()
	ParticleType("plain")
	ParticleColor(0.3, 0.85, 0.15, 0.05, 0.25, 0.03)
	ParticleRadius(0.035, 0.012)
	ParticleAlpha(1, 0)
	ParticleEmissive(0.8, 0)
	ParticleGravity(-9)
	ParticleDrag(0.2)
	ParticleSticky(0.4)
	ParticleCollide(1)
	for _ = 1, math.floor(6 + 12 * k) do
		SpawnParticle(pos, VecScale(rv(), 4 + 5 * k), 0.5 + 0.8 * math.random())
	end
end

function svHits(v, w)
	local h = w.hits
	if not h then v.hitSeq = v.hitSeq or 0; return end
	local last = v.hitSeq or -1
	for i = 1, #h, 5 do
		if h[i] > last then
			if v.hitSeq then svBlood(Vec(h[i + 1], h[i + 2], h[i + 3]), h[i + 4]) end   -- (none for hits from before we came)
			last = math.max(last, h[i])
		end
	end
	v.hitSeq = math.max(last, v.hitSeq or 0)
end

----- sounds: its voice only while it hunts; a hit and its death are heard whenever -----

local SV_EVENTS = {{"screech", "screech", 0.85}, {"hiss", "hiss", 1}, {"spit", "spit", 1}, {"leap", "leap", 0.8},
	{"bite", "bite", 1}, {"zip", "zip", 1}, {"die", "death", 0.85}}  -- (the shrieks are mastered louder than the clicks)

function svSounds(v, w, pos)
	local t = GetTime()
	local prev = v.ev
	if prev then
		for _, e in ipairs(SV_EVENTS) do
			if (w[e[1]] or 0) > (prev[e[1]] or 0) then svPlay(e[2], pos, e[3]) end
		end
		if (w.hurt or 0) > (prev.hurt or 0) and t - (v.hurtSndT or 0) > 0.35 and w.alive then
			v.hurtSndT = t
			svPlay("hurt", pos, 0.75)
		end
		if (w.bite or 0) > (prev.bite or 0) then
			local d = dist(GetCameraTransform().pos, pos)
			if d < 4 then ShakeCamera(0.7 * (1 - d / 4)) end
		end
	end
	v.ev = {screech = w.screech, hiss = w.hiss, spit = w.spit, leap = w.leap, bite = w.bite, zip = w.zip, die = w.die,
		hurt = w.hurt}
	if not (w.alive and w.hunt) then return end
	local loop = svSnd.skitter and svSnd.skitter[1]
	if loop and w.air == "" and (w.speed or 0) > 1 then PlayLoop(loop, pos, math.min(1, (w.speed or 0) / 7), false) end
	if t > (v.nextVoice or 0) then
		v.nextVoice = t + rnd(1.3, 3.2)
		if v.voiced then svPlay("chitter", pos, 1) end           -- (not on top of the screech)
		v.voiced = true
	end
end

----- the pose -----

function svPose(v, w, dt)
	local t = GetTime()
	for _, q in ipairs(v.parts) do if not centre(q) then return end end
	local pos = Vec(w.x, w.y, w.z)
	local up = VecNormalize(Vec(w.ux, w.uy, w.uz))
	local fwd = Vec(w.fx, w.fy, w.fz)
	fwd = VecSub(fwd, VecScale(up, VecDot(fwd, up)))
	if VecLength(fwd) < 1e-3 then fwd = VecCross(up, Vec(1, 0, 0)) end
	if VecLength(fwd) < 1e-3 then fwd = VecCross(up, Vec(0, 0, 1)) end
	fwd = VecNormalize(fwd)
	local speed = w.speed or 0
	local air = w.air or ""
	local dead = not w.alive
	local hunt = w.hunt
	local agit = hunt and 1 or (w.state == "stalk" and 0.4 or 0.15)
	local rear = w.rear or 0
	v.still = v.still + (((speed < 0.3 and air == "") and 1 or 0) - v.still) * math.min(1, dt * 3)
	local still = dead and 0 or v.still
	v.ph = v.ph + dt * (1.2 + 2.5 * agit)
	if dead and air == "" then v.deadK = math.min(1, v.deadK + dt / 0.8) end
	if not dead then v.deadK = 0 end
	local dk = v.deadK
	local dk2 = dk * dk * (3 - 2 * dk)
	local deadFor = dead and (t - (v.diedT or t)) or 0
	if dead and not v.diedT then v.diedT = t end
	local thrash = dead and math.max(0, 1 - deadFor / 3) or 0

	-- the body: breathing, a shiver when it hunts, reared up in a threat, on its back when dead
	local bob = math.sin(v.ph * 1.1) * (0.012 + 0.012 * still) + (math.random() - 0.5) * 0.012 * agit * (1 - still * 0.5)
	local lift = rear * 0.2 - dk2 * 0.2 + bob
	if air == "leap" then lift = lift + 0.05 end
	local bpos = VecAdd(pos, VecScale(up, lift))
	local R0, left = frame(up, fwd)
	local pitch = -rear * 30 + (air == "leap" and -18 or 0) + (air == "fall" and math.sin(t * 9) * 10 or 0)
	local roll = dk2 * 180 + math.sin(v.ph * 0.7) * 1.5 * still + thrash * math.sin(t * 31) * 8
	local RB = QuatRotateQuat(R0, QuatEuler(pitch, 0, roll))
	local TB = Transform(bpos, RB)
	local bx, by, bz = QuatRotateVec(RB, Vec(1, 0, 0)), QuatRotateVec(RB, Vec(0, 1, 0)), QuatRotateVec(RB, Vec(0, 0, 1))
	local function B(p) return TransformToParentPoint(TB, p) end       -- (a body-frame point in the world)

	-- the head: it looks round in jerks (more when it sits still), straight at its prey when it acts
	local L = v.look
	if t > L.next then
		local k = (dead or rear > 0.1 or air ~= "") and 0 or (0.3 + 0.7 * still)
		L.ty, L.tp = rnd(-22, 22) * k, rnd(-8, 10) * k
		L.next = t + rnd(0.25, 1.6 - agit)
	end
	local kk = math.min(1, dt * 14)
	L.y, L.p = L.y + (L.ty - L.y) * kk, L.p + (L.tp - L.p) * kk
	local P = SPIDER_PARTS
	local TC = Transform(B(Vec(0, 0, 0)), QuatRotateQuat(RB, QuatEuler(L.p, L.y, 0)))
	local cabd = P.ceph.abd
	SetBodyTransform(v.ceph.body, Transform(TransformToParentPoint(TC, Vec(-cabd[1], -cabd[2], -cabd[3])), TC.rot))
	local TCeph = GetBodyTransform(v.ceph.body)
	local function C(p) return TransformToParentPoint(TCeph, p) end    -- (a ceph-frame point in the world)

	-- the abdomen: it droops and pulses, lifts when silk comes out
	local tail = -7 + 4 * math.sin(v.ph * 0.9) + (w.line and 32 or 0) + (air == "zip" and 10 or 0) + thrash * 12 * math.sin(t * 23)
	v.tail = (v.tail or tail) + (tail - (v.tail or tail)) * math.min(1, dt * 8)
	local RA = QuatRotateQuat(RB, QuatEuler(v.tail, math.sin(v.ph * 0.5) * 3, 0))
	local aj = P.abdomen.joint
	SetBodyTransform(v.abd.body, Transform(VecSub(bpos, QuatRotateVec(RA, Vec(aj[1], aj[2], aj[3]))), RA))
	local sp = P.abdomen.spin
	v.spin = TransformToParentPoint(GetBodyTransform(v.abd.body), Vec(sp[1], sp[2], sp[3]))

	-- fangs: as the server says, plus twitches of their own; pedipalps feel about
	local open = clamp(w.fangs or 0, 0, 1)
	if not dead then
		if t > (v.fangNext or 0) then
			v.fangNext = t + rnd(0.5, 3 - 2 * agit)
			v.fangTw, v.fangTwA = t + rnd(0.08, 0.2), rnd(0.15, 0.45)
		end
		if t < (v.fangTw or 0) then open = math.max(open, v.fangTwA) end
	else
		open = 0.3 + 0.5 * thrash
	end
	for _, f in ipairs(v.fangs) do
		if f.q then
			local R = QuatRotateQuat(TCeph.rot, QuatEuler(-open * 28, 0, f.side * open * 32))
			SetBodyTransform(f.q.body, Transform(VecSub(C(f.socket), QuatRotateVec(R, f.pivot)), R))
		end
	end
	for _, f in ipairs(v.palps) do
		if f.q then
			local s = 1 + 2 * agit
			local R = QuatRotateQuat(TCeph.rot, QuatEuler(8 * math.sin(t * 2.3 * s + f.side) - 6 + dk2 * 40,
				f.side * (6 + 7 * math.sin(t * 1.7 * s + f.side * 2)), 0))
			SetBodyTransform(f.q.body, Transform(VecSub(C(f.socket), QuatRotateVec(R, f.pivot)), R))
		end
	end

	-- eyes
	local eyes = (w.eyes or 0.5) * (dead and math.max(0, 1 - deadFor / 2.5) or 1)
	if hunt and math.random() < 0.06 then eyes = eyes * 0.6 end
	if not SV_NOGLOW then
		for _, sh in ipairs(v.ceph.shapes) do SetShapeEmissiveScale(sh, eyes) end
		if eyes > 0.05 then
			local e = P.ceph.eyes
			v.glowAt, v.glowI = C(Vec(e[1], e[2], e[3] + 0.08)), 0.05 + 0.16 * eyes
			PointLight(v.glowAt, 1, 0.06, 0.03, v.glowI)
		else
			v.glowAt = nil
		end
	end

	-- the legs
	local cam = GetCameraTransform().pos
	if dist(cam, pos) > SV_FAR then
		for _, l in ipairs(v.legs) do
			if not l.parked then
				l.parked = true
				if l.upper then SetBodyTransform(l.upper.body, Transform(SV_PARK)) end
				if l.lower then SetBodyTransform(l.lower.body, Transform(SV_PARK)) end
			end
			l.planted = nil
		end
		return bpos
	end
	local vel = Vec(0, 0, 0)
	if v.lastPos and dt > 1e-4 then vel = VecScale(VecSub(pos, v.lastPos), 1 / dt) end
	v.lastPos = VecCopy(pos)
	if VecLength(vel) > 30 then vel = Vec(0, 0, 0) end                -- (a jump between two updates)
	local grounded = air == "" and not dead
	if air ~= v.lastAir then                                        -- (it landed, or left: every foot finds its place anew)
		v.lastAir = air
		for _, l in ipairs(v.legs) do l.planted, l.step = nil, nil end
	end
	local thresh = 0.26 + 0.045 * math.min(speed, 8)
	local dur = clamp(0.2 - speed * 0.018, 0.07, 0.2)
	local stepping = {0, 0}
	for _, l in ipairs(v.legs) do if l.step then stepping[l.group + 1] = stepping[l.group + 1] + 1 end end
	-- a front leg lifted to feel the air, now and then, when it sits still
	if grounded and still > 0.8 and rear < 0.05 and t > v.feelNext and not v.feel then
		v.feel = {leg = math.random(1, 2), t0 = t, dur = rnd(0.5, 1.4)}
		v.feelNext = t + rnd(2, 7) / (0.5 + agit)
	end
	if v.feel and (t > v.feel.t0 + v.feel.dur or not grounded or still < 0.5) then v.feel = nil end

	for li, l in ipairs(v.legs) do
		l.parked = false
		local hip = C(l.hip)
		local restW = VecAdd(VecAdd(VecAdd(pos, VecScale(left, l.rest[1])), VecScale(up, l.rest[2])), VecScale(fwd, l.rest[3]))
		local foot
		if grounded then
			if not l.planted then l.planted = footOn(restW) or VecSub(restW, VecScale(up, 0.25)) end
			if l.step then
				local s = l.step
				local u = (t - s.t0) / s.dur
				if u >= 1 then
					l.planted, l.step = s.to, nil
					foot = l.planted
				else
					local e = u * u * (3 - 2 * u)
					foot = VecAdd(VecLerp(s.from, s.to, e), VecScale(up, s.lift * math.sin(math.pi * u)))
				end
			else
				local err = dist(l.planted, restW)
				local other = stepping[2 - l.group]
				if err > 1.7 then
					l.planted = footOn(restW) or VecSub(restW, VecScale(up, 0.25))
				elseif err > thresh and (other == 0 or err > thresh * 2.2) then
					local sp = VecLength(vel)
					local lead = sp > 0.2 and VecScale(vel, dur + thresh * 0.8 / sp) or Vec(0, 0, 0)
					local want = VecAdd(restW, lead)
					local to = footOn(want) or VecSub(want, VecScale(up, 0.25))
					l.step = {from = l.planted, to = to, t0 = t, dur = dur * rnd(0.9, 1.15), lift = 0.1 + 0.02 * math.min(speed, 7) + rnd(0, 0.05)}
					stepping[l.group + 1] = stepping[l.group + 1] + 1
				end
				foot = l.planted
				-- a single leg jerks on its own, now and then
				if t < l.tw then
					foot = VecAdd(foot, VecScale(up, l.twA))
				elseif math.random() < dt * (0.08 + 0.5 * still * agit) then
					l.tw, l.twA = t + rnd(0.06, 0.18), rnd(0.05, 0.2)
				end
			end
			-- the threat: the front pairs raised and spread, trembling
			local wr = l.pair == 1 and rear or (l.pair == 2 and math.max(0, rear - 0.5) * 1.4 or 0)
			if wr > 0.01 then
				local raised = B(Vec(l.side * (0.5 + 0.25 * l.pair), 0.85 + 0.12 * math.sin(t * 27 + li), 1.25 - 0.4 * l.pair))
				foot = VecLerp(foot, raised, math.min(1, wr))
			end
			if v.feel and l.pair == 1 and ((v.feel.leg == 1) == (l.side > 0)) then
				local u = (t - v.feel.t0) / v.feel.dur
				local k = math.sin(math.pi * clamp(u, 0, 1))
				local probe = B(Vec(l.side * 0.55, 0.25 + 0.2 * math.sin(t * 11), 1.5 + 0.12 * math.sin(t * 7)))
				foot = VecLerp(foot, probe, k)
			end
		else
			-- in the air, or dead: no ground under the feet
			local a = math.rad(SV_REST[l.pair][1])
			local r = SV_REST[l.pair][2]
			local q
			if dead then
				local tw = thrash * 0.25 * math.sin(t * (19 + li * 3) + li)
				q = Vec(l.side * (0.2 + 0.03 * l.pair + tw), -0.5 + tw, 0.75 - 0.3 * l.pair)   -- (curled over its belly)
				local last = l.lastFoot or B(q)
				foot = VecLerp(last, B(q), math.min(1, dt * 5))
			elseif air == "zip" then
				if l.pair <= 2 then q = Vec(l.side * 0.2 * l.pair, 0.15, 1.3 - 0.3 * l.pair)   -- (hauling itself along the line)
				else q = Vec(l.side * (0.45 + 0.1 * l.pair), -0.15, -0.3 - 0.35 * (l.pair - 2)) end
				q = VecAdd(q, Vec(0, 0.06 * math.sin(t * 14 + li * 1.3), 0.08 * math.sin(t * 17 + li)))
				foot = B(q)
			elseif air == "leap" then
				q = Vec(l.side * math.sin(a) * r * 1.05, 0.25 - 0.12 * l.pair, math.cos(a) * r + 0.45)   -- (flung wide)
				foot = B(q)
			else
				q = Vec(l.side * math.sin(a) * r * 0.8, -0.1 + 0.3 * math.sin(t * 13 + li * 2.1), math.cos(a) * r * 0.8 + 0.2 * math.sin(t * 11 + li))
				foot = B(q)
			end
		end
		l.lastFoot = foot
		local pole = VecAdd(VecScale(by, dead and -0.2 or 1), VecScale(bx, l.side * (dead and 1 or 0.3)))
		local k, f2 = knee(hip, foot, l.la, l.lb, VecNormalize(pole))
		bone(l.upper, hip, k, VecNormalize(VecAdd(by, VecScale(bx, l.side * 0.2))))
		bone(l.lower, k, f2, VecNormalize(VecSub(k, VecLerp(hip, f2, 0.5))))
	end
	return bpos
end

----- callbacks -----

function SpiderView.clientInit()
	svViews = {}
	svLastN = -1
	svSnaps = {}
	svLoadSounds()
end

function svTake()
	local W = shared.dw
	if not W or W.n == svLastN then return end
	svLastN = W.n
	local t = GetTime()
	for i = 1, #W do
		local w = W[i]
		local s = svSnaps[w.id] or {}
		s.prev, s.prevT = s.cur, s.curT
		local c = {}
		for k, x in pairs(w) do c[k] = x end                         -- (copy: shared hands out copies, keep ours)
		s.cur, s.curT, s.seen = c, t, t
		svSnaps[w.id] = s
	end
	svLive = {}
	for i = 1, #W do svLive[W[i].id] = true end
end

local BLEND = {"x", "y", "z", "ux", "uy", "uz", "fx", "fy", "fz", "speed", "rear", "fangs", "eyes"}

function SpiderView.clientTick(dt)
	if not SPIDER_PARTS then return end
	svTake()
	local t = GetTime()
	svFrame = (svFrame or 0) + 1
	local cam = GetCameraTransform().pos
	for id, s in pairs(svSnaps) do
		if not (svLive or {})[id] then                                -- (gone from the server's list)
			if svViews[id] then svDelete(svViews[id]); svViews[id] = nil end
			svSnaps[id] = nil
		else
			local w = s.cur
			local v = svViews[id]
			if not v then v = svSpawn(); svViews[id] = v end
			-- far from the camera it is posed less often: every 2nd, every 4th frame, the spiders taking turns.
			-- (Not while a line is out or it is in the air: the strand ends at its spinnerets.)
			local cd = dist(cam, Vec(w.x, w.y, w.z))
			local every = (w.line or (w.air or "") ~= "") and 1 or (cd > SV_LOW and 4 or (cd > SV_MID and 2 or 1))
			v.dtAcc = (v.dtAcc or 0) + dt
			local at
			if every == 1 or not v.at or (svFrame + id) % every == 0 then
				local o = w
				if s.prev and s.prevT and s.curT > s.prevT then
					local f = math.min(1, (t - s.curT) / (s.curT - s.prevT))
					local far = math.abs(w.x - s.prev.x) + math.abs(w.y - s.prev.y) + math.abs(w.z - s.prev.z) > 6
					if not far then
						o = {}
						for k, x in pairs(w) do o[k] = x end
						for _, k in ipairs(BLEND) do
							local a, b = s.prev[k], w[k]
							if a and b then o[k] = a + (b - a) * f end
						end
					end
				end
				local posed = svPose(v, o, v.dtAcc)                    -- (the time since its last pose: speeds come from it)
				at = posed or Vec(o.x, o.y, o.z)
				v.dtAcc = 0
				v.at = posed                                           -- (nil until its parts are ready: then every frame)
			else
				at = v.at
				if v.glowAt and not SV_NOGLOW then PointLight(v.glowAt, 1, 0.06, 0.03, v.glowI) end   -- (a light lasts one frame)
			end
			svSounds(v, w, at)
			svHits(v, w)
			-- the line it is shooting or riding
			if w.line and v.spin and wbStrand then
				local L = w.line
				local a, b = Vec(L[1], L[2], L[3]), Vec(L[4], L[5], L[6])
				local cam = GetCameraTransform().pos
				local c = (wbC and wbC.b) or 0.6
				if w.air == "zip" then
					wbStrand(a, v.spin, 0.06, c, 0.9, cam)
					wbStrand(v.spin, b, 0.06, c, 0.95, cam)
				else
					wbStrand(v.spin, VecLerp(v.spin, b, clamp(L[7] or 0, 0, 1)), 0.06, c, 0.95, cam)
				end
			end
		end
	end
end

-- the spawn menu's markers: the seconds until a spider comes out of each, over it
function SpiderView.clientDraw()
	local W = shared.dw
	local marks = W and W.marks
	if not marks then return end
	for i = 1, #marks, 4 do
		local x, y, d = UiWorldToPixel(Vec(marks[i], marks[i + 1] + 0.7, marks[i + 2]))
		if d > 0 and d < 80 then
			local txt = tostring(math.ceil(marks[i + 3]))
			UiPush()
			UiTranslate(x, y)
			UiAlign("center middle")
			UiFont("bold.ttf", 44)
			UiColor(0, 0, 0, 0.8)
			UiTranslate(2, 2)
			UiText(txt)
			UiTranslate(-2, -2)
			UiColor(1, 0.15, 0.1, 0.6 + 0.4 * math.sin(GetTime() * 8))
			UiText(txt)
			UiPop()
		end
	end
end
