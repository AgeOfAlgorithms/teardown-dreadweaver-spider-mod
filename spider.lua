-- Spider: the Dreadweavers' brains and bodies on the server (PROJECT.md: Interfaces). A spider is a point riding
-- DW_RIDE m off whatever static surface is nearest (floor, wall, ceiling, the edge between two): every step it moves
-- along the surface's tangent and snaps back onto the closest surface point, so it rounds corners inside and out
-- without knowing what they are. Paths come from SNav (the shell of air that hugs geometry). Where the surface ends
-- it takes to the air: a web line shot to a surface and ridden (zip), a leap at its prey, or a plain fall.
--
-- States: roam (unaware; drifts toward life), stalk (knows of someone: silent, keeps its distance on walls and
-- ceilings above and behind them, creeps closer, freezes or scuttles off when looked at, speaks lures - lure.lua),
-- hunt (the only state with a voice: a screech, then the chase, web shots, leaps, bites), retreat (hit and run: back
-- into the dark, then it stalks again), flee (losing: far away), hide (still, healing), dead.
-- Sight is its first sense (the user): it hunts and stalks what it SEES (through glass too; all round but straight
-- behind it), and a hunt lasts only while it keeps seeing its prey. Hearing comes second: a sound, or a line said
-- over Proximity Comms within its range, is only a place to go and look. Its web trembling under someone, and
-- anyone touching it, it feels. What breaks easily (glass) it goes through instead of round - except when it stalks,
-- which it does quietly.

Spider = {}

DW_LAYER = 64                 -- the hit boxes' and the drawn parts' collision layer (nothing collides with them;
DW_MASK = 63                  -- players' CollisionMask leaves it out); our queries skip it and Dive's fish (128)
DW_MAX = 6                    -- spiders at most (the count option + spawn-menu spiders)
DW_RIDE = 0.45                -- m: the body's centre off the surface
DW_HP = 120
DW_PUBLISH_HZ = 15
DW_SENSE_HZ = 5
DW_GRAV = 13                  -- m/s2 in a leap or a fall
ZIP_SPEED = 17                -- m/s along a web line
ZIP_CAST = 0.32               -- s the line takes to shoot out
ZIP_MIN, ZIP_MAX = 5, 45      -- m
LINE_RUN = 11                 -- m/s along a line that is already strung (no shot needed: it just runs across)
LINE_WORTH = 0.75             -- it takes a strung line when the way over it is under this share of the straight way
SIGHT = 45                    -- m: a player in its line of sight (its first sense)
LIGHT_SIGHT = 65              -- m: ... with a flashlight on
SIGHT_BACK = -0.45            -- it sees all round but a cone straight behind it (the cosine to its heading), and
SIGHT_NEAR = 8                --  within this many m all round
TOUCH_SENSE = 3               -- m: felt whatever they do
MOVE_SENSE = 7                -- m: felt when they move fast
HEAR_K = 30                   -- m of hearing per unit of GetLastSound volume (second to sight: a place to look)
CHAT_HEAR = 1.0               -- x a Proximity Comms line's own range: it hears what is said
WEB_SENSE = 70                -- m: someone caught in a web is felt this far
FORGET_T = 20                 -- s: a stalk gives up this long after the last sensing
HUNT_LOSE = 5                 -- s without SEEING its prey, once it is where it last saw them: the hunt becomes a stalk
HUNT_LOSE_MAX = 12            --  ... or this long wherever it is
SMASH_REACH = 7               -- m: glass this near on the straight line to where it is going gets broken
SMASH_R = 1.0                 -- m: the hole (soft materials only)
CHEW_R = 1.3                  -- m: the bite out of a tree it is caught in (soft materials only)
CHEW_LOOK = 1.6               -- m: leaves this near count as "in a tree"
DW_GOLD = 200                 -- gold a killed one drops for the Inventory mod (option: 0 / 100 / 200 / 400)
SPAWN_MARK_T = 7              -- s: a spawn-menu marker lies this long before the spider comes out of it
dwMarkT0, dwMarks = {}, {}    -- marker body -> when first seen; {x, y, z, seconds left, ...} for the clients
BITE_R = 1.8
BITE_DMG = 0.22
LEAP_DMG = 0.34
LEAP_MIN, LEAP_MAX = 2.6, 8.5
SHOT_MIN, SHOT_MAX = 5, 28
CORPSE_T = 40
RESPAWN_T = 120
SPAWN_DELAY = 15
SPEED = {roam = 2.4, stalk = 3.4, hunt = 7.2, retreat = 8, flee = 9.5, hide = 0, dead = 0}
-- erratic tempo: {weight, speed factor, min s, max s} per state
TEMPO = {
	roam = {{0.30, 0, 1.0, 5.0}, {0.45, 0.6, 1.0, 3.0}, {0.25, 1.0, 0.5, 2.0}},
	stalk = {{0.20, 0, 0.5, 2.5}, {0.35, 0.5, 0.5, 1.5}, {0.35, 1.0, 0.4, 1.4}, {0.10, 2.0, 0.2, 0.5}},
	hunt = {{0.05, 0, 0.1, 0.3}, {0.45, 1.0, 0.4, 1.2}, {0.50, 1.25, 0.3, 0.9}},
	retreat = {{1.0, 1.0, 1.0, 2.0}},
	flee = {{1.0, 1.0, 1.0, 2.0}},
}
EYES = {roam = 0.45, stalk = 0.7, hunt = 1.0, retreat = 0.6, flee = 0.5, hide = 0.15, dead = 0}

local function now() return GetTime() end
local function vlen(v) return VecLength(v) end
local function dist(a, b) return VecLength(VecSub(a, b)) end
local function rnd(a, b) return a + math.random() * (b - a) end

function dwFilter()
	QueryRequire("physical static")
	QueryCollisionMask(DW_MASK)
end

-- ray / sphere cast against the static world: hit, distance, normal
function dwRay(o, dir, len, r)
	dwFilter()
	return QueryRaycast(o, dir, len, r or 0)
end

-- the static surface nearest to p within r: point, normal (from the surface toward p), distance; nil when none
function dwSurf(p, r)
	dwFilter()
	local hit, cp, n = QueryClosestPoint(p, r)
	if not hit then return nil end
	local d = VecSub(p, cp)
	local l = VecLength(d)
	if l > 0.03 then return cp, VecScale(d, 1 / l), l end
	if n and VecLength(n) > 0.5 then return cp, VecNormalize(n), l end
	return cp, Vec(0, 1, 0), l
end

-- nothing static between a and b that it cannot see through (glass does not hide anyone)
function dwSee(a, b)
	local d = VecSub(b, a)
	local l = VecLength(d)
	if l < 0.01 then return true end
	dwFilter()
	return not QueryRaycast(a, VecScale(d, 1 / l), l, 0, true)
end

-- is what a cast hit at `at` (going along dir) glass?
function dwGlass(shape, at, dir)
	if not shape or shape == 0 then return false end
	for _, k in ipairs({0.03, 0.1, 0.18}) do
		local m = GetShapeMaterialAtPosition(shape, VecAdd(at, VecScale(dir, k)))
		if m == "glass" then return true end
	end
	return false
end

function dwChest(p) return Prey.chest(p) end

-- where a spider would stand for point p: on the surface next to it, else on what lies below it. Point, normal
function dwGround(p)
	local cp, n = dwSurf(VecAdd(p, Vec(0, 0.3, 0)), 1.4)
	if cp then return VecAdd(cp, VecScale(n, DW_RIDE)), n end
	local hit, d, hn = dwRay(p, Vec(0, -1, 0), 40)
	if hit then return VecAdd(p, Vec(0, DW_RIDE - d, 0)), hn end
	return nil
end

-- v without its part along n, unit length (nil when nothing is left)
local function tangent(v, n)
	local t = VecSub(v, VecScale(n, VecDot(v, n)))
	local l = VecLength(t)
	if l < 1e-4 then return nil end
	return VecScale(t, 1 / l), l
end

local function anyTangent(n)
	local a = math.abs(n[2]) < 0.9 and Vec(0, 1, 0) or Vec(1, 0, 0)
	return VecNormalize(VecCross(a, n))
end

local function pick(list)
	local r, acc = math.random(), 0
	for _, e in ipairs(list) do
		acc = acc + e[1]
		if r <= acc then return e end
	end
	return list[#list]
end

----- hit boxes (server): invisible, in DW_LAYER, mask 0 (bullets find them by query; nothing collides) -----

local HIT_BOXES = {{size = 6, at = 0.42, head = true}, {size = 8, at = -0.5, head = false}}

function spBoxesSpawn(s)
	s.boxes = {}
	for i, hb in ipairs(HIT_BOXES) do
		local n = hb.size
		local xml = string.format("<body tags='dreadweaverhit'><voxbox tags='invisible unbreakable' pos='%.2f %.2f %.2f' size='%d %d %d' color='0 0 0'/></body>",
			-n * 0.05, -n * 0.05, -n * 0.05, n, n, n)
		local ents = Spawn(xml, Transform(Vec(0, -500, 0)))
		for _, e in ipairs(ents or {}) do
			if GetEntityType(e) == "body" then
				for _, sh in ipairs(GetBodyShapes(e)) do
					SetShapeCollisionFilter(sh, DW_LAYER, 0)
					dwHitShapes[sh] = {s = s, head = hb.head}
				end
				s.boxes[#s.boxes + 1] = {body = e, hb = hb}
			end
		end
	end
end

function spBoxesDelete(s)
	for _, b in ipairs(s.boxes) do
		for _, sh in ipairs(GetBodyShapes(b.body)) do dwHitShapes[sh] = nil end
		Delete(b.body)
	end
	s.boxes = {}
end

function spBoxPos(s, hb) return VecAdd(s.pos, VecScale(s.fwd, hb.at)) end

function spBoxesMove(s)
	for _, b in ipairs(s.boxes) do SetBodyTransform(b.body, Transform(spBoxPos(s, b.hb))) end
end

----- the registry API (any mod; PROJECT.md) -----

-- The Villagers mod (villagers/mods/villagers/API.md): plain host registry keys, harmless when it is not running.
-- The kind is described once; each living spider is a "thing" kept up to date twice a second.
local VL_DOING = {roam = "crawling about", stalk = "creeping closer, watching", hunt = "hunting, charging",
	retreat = "backing off into the dark", flee = "running away, hurt", hide = "lurking out of sight"}
function dwVillagersInit()
	SetString("villagers.kind.spider.name", "a giant spider")
	SetString("villagers.kind.spider.feel", "fear")
	SetString("villagers.kind.spider.note", "as big as a man, eight red eyes; crawls on walls and ceilings, spits sticky webs and bites")
	SetFloat("villagers.kind.spider.danger", 0.8)
	SetFloat("villagers.kind.spider.flee", 22)
	SetString("villagers.kind.spider.doing", "crawling")
	SetString("villagers.kind.spider.sound", "a dry skittering and clicking")
	SetFloat("villagers.kind.spider.hear", 0)
	dwVlThings = {}
end

function dwVillagersTick()
	local now0 = {}
	for _, s in ipairs(dwList) do
		local k = "villagers.thing.dw" .. s.id .. "."
		if s.alive then
			now0[s.id] = true
			SetString(k .. "kind", "spider")
			SetFloat(k .. "x", s.pos[1]); SetFloat(k .. "y", s.pos[2]); SetFloat(k .. "z", s.pos[3])
			SetString(k .. "doing", VL_DOING[s.state] or "crawling")
			SetBool(k .. "hidden", s.state == "hide")
			SetFloat(k .. "hear", (s.state == "hunt" or s.state == "flee" or s.state == "retreat") and 15 or 0)
			SetBool(k .. "gone", false)
		end
	end
	for id in pairs(dwVlThings) do
		if not now0[id] then
			SetBool("villagers.thing.dw" .. id .. ".gone", true)
			dwVlThings[id] = nil
		end
	end
	for id in pairs(now0) do dwVlThings[id] = true end
end

function dwPublishHitpoints()
	if DW_ASSET then return end                                    -- (one registry key for all: the main script's)
	local out = {}
	for _, s in ipairs(dwList) do
		if s.alive then
			for _, hb in ipairs(HIT_BOXES) do
				local p = spBoxPos(s, hb)
				out[#out + 1] = string.format("%d %.2f %.2f %.2f %.2f %d;", s.id, p[1], p[2], p[3], hb.size * 0.05 + 0.2, hb.head and 1 or 0)
			end
		end
	end
	local str = table.concat(out)
	if str ~= dwHitpointsLast then
		SetString("dreadweaver.hitpoints", str)
		dwHitpointsLast = str
	end
end

local function finite(x) return x and x == x and x > -1e9 and x < 1e9 end

function dwTakeApiDamage()
	if DW_ASSET then return end
	local q = GetString("dreadweaver.damage")
	if q == "" then return end
	SetString("dreadweaver.damage", "")
	local taken = 0
	for entry in string.gmatch(q, "[^;]+") do
		if taken >= 32 then break end
		taken = taken + 1
		local x, y, z, a = string.match(entry, "^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*$")
		x, y, z, a = tonumber(x), tonumber(y), tonumber(z), tonumber(a)
		if finite(x) and finite(y) and finite(z) and finite(a) and a > 0 then
			local p = Vec(x, y, z)
			local best, bestD = nil, 1.5
			for _, s in ipairs(dwList) do
				if s.alive then
					local d = dist(p, s.pos)
					if d < bestD then best, bestD = s, d end
				end
			end
			if best then spDamage(best, math.min(a, DW_HP), "api", p) end
		end
	end
end

----- damage -----

-- point: where it was hit (nil: the body's middle)
function spDamage(s, d, kind, point)
	if not s.alive or d <= 0 then return end
	local t = now()
	local p = point or s.pos
	s.hitSeq = s.hitSeq + 1
	local h = s.hits
	h[#h + 1] = s.hitSeq; h[#h + 1] = p[1]; h[#h + 1] = p[2]; h[#h + 1] = p[3]; h[#h + 1] = d
	while #h > 30 do
		for _ = 1, 5 do table.remove(h, 1) end
	end
	s.hp = s.hp - d
	s.hurtT = t
	s.ev.hurt = s.ev.hurt + 1
	s.act = nil
	s.rear = 0
	if s.hp <= 0 then return spDie(s) end
	-- it runs away, at random: the faster it is losing health and the less it has left, the likelier
	local log = s.dmgLog
	log[#log + 1] = {t, d}
	local recent = 0
	for i = #log, 1, -1 do
		if t - log[i][1] > 3 then table.remove(log, i) else recent = recent + log[i][2] end
	end
	local chance = 0
	if recent >= 28 then chance = chance + 0.45 end
	if s.hp < DW_HP * 0.4 then chance = chance + 0.4 end
	if s.hp < DW_HP * 0.2 then chance = 1 end
	-- whoever is nearest did it, as far as it knows
	local best, bd = 0, 80
	for _, q in ipairs(Prey.all()) do
		local dd = dist(Prey.chest(q), s.pos)
		if dd < bd then best, bd = q, dd end
	end
	if best ~= 0 then
		s.target = best
		s.known = dwChest(best)
		s.knownT = t
		s.seenT = t                                                  -- (it knows where that came from)
	end
	if d >= 4 and not s.air then                                   -- (it flinches sideways)
		s.flinchUntil = t + 0.22
		local side = VecCross(s.n, s.fwd)
		s.flinchDir = VecNormalize(VecAdd(VecScale(side, math.random() < 0.5 and -1 or 1), VecScale(s.fwd, -0.6)))
	end
	if s.state ~= "flee" and math.random() < chance then
		spFlee(s)
	elseif s.state == "roam" or s.state == "stalk" or s.state == "hide" or s.state == "retreat" then
		if s.hp > DW_HP * 0.45 and math.random() < 0.6 then spSetState(s, "hunt") else spRetreat(s) end
	end
end

-- gold for the McPuppet Inventory System: where it dies, on the ground below it, "x,y,z,amount" appended to
-- inventory.dropgold (host). Nothing happens without that mod. The amount is an option (savegame.mod.gold, stored +1).
function dwDropGold(s)
	if not GetBool("inventory.present") then return end
	local g = GetInt("savegame.mod.gold")
	local amount = g > 0 and g - 1 or DW_GOLD
	if amount <= 0 then return end
	local at = VecCopy(s.pos)
	local hit, d = dwRay(VecAdd(s.pos, Vec(0, 0.3, 0)), Vec(0, -1, 0), 30)
	if hit then at = VecAdd(s.pos, Vec(0, 0.3 - d + 0.2, 0)) end
	local cur = GetString("inventory.dropgold")
	SetString("inventory.dropgold", (cur == "" and "" or cur .. " ") .. string.format("%.2f,%.2f,%.2f,%d", at[1], at[2], at[3], amount))
	s.goldDropped = amount
end

function spDie(s)
	if s.alive then dwDropGold(s) end
	s.alive = false
	s.state = "dead"
	s.stateT = now()
	s.deadT = now()
	s.ev.die = s.ev.die + 1
	s.act, s.line = nil, nil
	s.speed = 0
	spBoxesDelete(s)
	SNav.cancel(s.id)
	if not s.air and s.n[2] < 0.7 then                             -- (off a wall or a ceiling: it drops)
		s.air = {kind = "fall", vel = VecScale(s.n, 1.5), t0 = now()}
	end
end

-- villagers fighting back (the Villagers mod's villagers.strike ring): a punch hurts it a little
function dwTakeStrikes()
	if not GetBool("villagers.present") then return end
	local last = GetInt("villagers.strike.last")
	if dwStrikeSeen == nil or last < dwStrikeSeen then dwStrikeSeen = last end
	for n = math.max(dwStrikeSeen + 1, last - 15), last do
		local k = "villagers.strike." .. (n % 16) .. "."
		local id = string.match(GetString(k .. "thing"), "^dw(%d+)$")
		if id then
			for _, s in ipairs(dwList) do
				if s.alive and s.id == tonumber(id) then
					local from = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
					spDamage(s, math.max(2, GetFloat(k .. "amount") * 0.5), "villager", VecLerp(s.pos, from, 0.25))
				end
			end
		end
	end
	dwStrikeSeen = last
end

function dwTakeHits()
	for i = 1, GetEventCount("projectilehit") do
		local shape, point = GetEvent("projectilehit", i)
		local h = dwHitShapes[shape]
		if h then spDamage(h.s, h.head and 9 or 6, "bullet", point) end
	end
	for i = 1, GetEventCount("explosion") do
		local point, strength = GetEvent("explosion", i)
		strength = strength or 1
		SNav.forget(point, 2 + 2 * strength)
		for _, s in ipairs(dwList) do
			if s.alive then
				local d = dist(point, s.pos)
				local r = 3.5 * strength
				if d < r then spDamage(s, 80 * strength * (1 - d / r), "explosion", VecLerp(s.pos, point, 0.3)) end
			end
		end
	end
	for _, q in ipairs(GetAllPlayers()) do                          -- sledge swings at it
		if GetPlayerTool(q) == "sledge" and InputPressed("usetool", q) and GetPlayerHealth(q) > 0 then
			local eye = GetPlayerEyeTransform(q)
			for _, s in ipairs(dwList) do
				if s.alive then
					local v = VecSub(s.pos, eye.pos)
					local d = vlen(v)
					if d < 3.2 and VecDot(VecScale(v, 1 / math.max(d, 0.01)), TransformToParentVec(eye, Vec(0, 0, -1))) > 0.55 then
						spDamage(s, 14, "sledge", VecLerp(s.pos, eye.pos, 0.25))
					end
				end
			end
		end
	end
end

----- spawning -----

function dwMapBounds()
	local lo, hi = GetBodyBounds(GetWorldBody())
	if not lo or (hi[1] - lo[1]) < 10 then
		local p = GetAllPlayers()[1]
		local c = p and GetPlayerTransform(p).pos or Vec(0, 0, 0)
		return VecAdd(c, Vec(-120, -20, -120)), VecAdd(c, Vec(120, 40, 120))
	end
	return lo, hi
end

-- a random lair candidate and its score (nil: unusable): on a surface, far from everyone, out of their sight
function dwCandidate(lo, hi, minD)
	local p = Vec(rnd(lo[1], hi[1]), rnd(lo[2], hi[2]), rnd(lo[3], hi[3]))
	if dwSurf(p, 0.35) then return nil end
	local down, dd, dn = dwRay(p, Vec(0, -1, 0), 30)
	if not down then return nil end
	local at = VecAdd(p, Vec(0, DW_RIDE - dd, 0))
	if IsPointInWater(at) then return nil end
	local score = 0
	for _, q in ipairs(Prey.all()) do
		local e = Prey.eye(q).pos
		local d = dist(e, at)
		if d < minD then return nil end
		if d < 70 and dwSee(e, at) then return nil end
		score = score + math.min(d, 150) * 0.01
	end
	local up = dwRay(at, Vec(0, 1, 0), 14)
	if up then score = score + 2 end                               -- under cover: dark
	return at, score, dn
end

function spNew(pos, n)
	local t = now()
	n = n or Vec(0, 1, 0)
	local s = {
		id = dwNextId, pos = VecCopy(pos), n = VecCopy(n), up = VecCopy(n), fwd = anyTangent(n), vel = Vec(0, 0, 0),
		speed = 0, lair = VecCopy(pos), alive = true, hp = DW_HP, state = "roam", stateT = t, born = t,
		tempo = 1, tempoUntil = 0, target = 0, known = nil, knownT = -100, seeing = false, seenT = -100, far = 1e9,
		glassT = 0, smash = nil, smashed = 0,
		goal = nil, path = nil, pathI = 1, planT = -100, planGoal = nil, planning = false, planOk = false, planLen = 0,
		wanderT = 0, stuckT = t, stuckD = 1e9, stuckN = 0,
		air = nil, line = nil, act = nil, rear = 0, fangs = 0,
		zipCd = t + 2, shotCd = 0, leapCd = 0, biteCd = 0, zipTryT = 0, chitT = 0,
		patience = 0, vantage = nil, vantageUntil = 0, watch = 0, spotCd = 0, stareUntil = 0, huntMax = 0,
		hurtT = -100, deadT = 0, flinchUntil = 0,
		ev = {screech = 0, hiss = 0, spit = 0, leap = 0, bite = 0, hurt = 0, die = 0, zip = 0},
		hits = {}, hitSeq = 0, dmgLog = {}, boxes = {},
	}
	dwNextId = dwNextId + 1
	spBoxesSpawn(s)
	return s
end

----- states -----

function spSetState(s, st)
	if s.state == st then return end
	local t = now()
	s.state = st
	s.stateT = t
	s.tempoUntil = 0
	s.vantage = nil
	s.goal = nil
	s.stuckN = 0
	if st == "hunt" then
		-- the hunt begins: it rears up and screeches (the first sound it makes)
		s.act = {kind = "screech", t0 = t, dur = 0.75}
		s.ev.screech = s.ev.screech + 1
		s.huntMax = rnd(32, 50)
		s.shotCd = 0                                                 -- (a web first, if it has the range: then the chase)
		s.leapCd = t + 0.9
	elseif st == "stalk" then
		s.patience = t + rnd(35, 90)
		s.watch = 0
	end
end

-- a spot to go to away from `from`: on the ground, far from everyone, out of sight if it can
function spHideSpot(s, from, minD, maxD)
	local best, bs = nil, -1e9
	local away = tangent(VecSub(s.pos, from), Vec(0, 1, 0)) or Vec(1, 0, 0)
	for _ = 1, 10 do
		local a = rnd(-1.9, 1.9)
		local dir = Vec(away[1] * math.cos(a) - away[3] * math.sin(a), 0, away[1] * math.sin(a) + away[3] * math.cos(a))
		local p = VecAdd(VecAdd(s.pos, VecScale(dir, rnd(minD, maxD))), Vec(0, rnd(2, 10), 0))
		if not dwSurf(p, 0.4) then
			local hit, d = dwRay(p, Vec(0, -1, 0), 40)
			if hit then
				local at = VecAdd(p, Vec(0, DW_RIDE - d, 0))
				local sc = 0
				for _, q in ipairs(Prey.all()) do
					local e = Prey.eye(q).pos
					sc = sc + math.min(60, dist(e, at)) * 0.2
					if not dwSee(e, at) then sc = sc + 10 end
				end
				if dwRay(at, Vec(0, 1, 0), 12) then sc = sc + 4 end
				if IsPointInWater(at) then sc = sc - 100 end
				if sc > bs then best, bs = at, sc end
			end
		end
	end
	return best
end

function spFlee(s)
	local from = s.known or s.pos
	spSetState(s, "flee")
	s.hide = spHideSpot(s, from, 35, 70) or VecCopy(s.lair)
	s.zipCd = 0
	-- a web dropped behind it, for whoever follows
	local cp, n = dwSurf(s.pos, DW_RIDE + 0.5)
	if cp then Webs.addPatch(cp, n, 1.5) end
end

function spRetreat(s)
	local from = s.known or s.pos
	spSetState(s, "retreat")
	s.hide = spHideSpot(s, from, 16, 30) or VecCopy(s.lair)
	s.zipCd = 0
end

-- a place to watch its prey from: a surface the prey's eye could see, preferably above and behind them, ring m away
function spVantage(s, p, ring)
	local eye = Prey.eye(p)
	local back = TransformToParentVec(eye, Vec(0, 0, 1))
	back = tangent(back, Vec(0, 1, 0)) or Vec(1, 0, 0)
	local best, bs, bn = nil, -1e9, nil
	for _ = 1, 10 do
		local a = rnd(-2.2, 2.2)
		local dir = Vec(back[1] * math.cos(a) - back[3] * math.sin(a), 0, back[1] * math.sin(a) + back[3] * math.cos(a))
		dir = VecNormalize(VecAdd(dir, Vec(0, rnd(0.1, 1.4), 0)))       -- (it looks for a place above them)
		local hit, d, hn = dwRay(eye.pos, dir, ring + 8)
		local at, n
		if hit and d > 3 then
			at, n = VecAdd(VecAdd(eye.pos, VecScale(dir, d)), VecScale(hn, DW_RIDE)), hn
		elseif not hit then                                         -- (open ground: what lies below the ray's end)
			local e = VecAdd(eye.pos, VecScale(dir, ring))
			local h2, d2, n2 = dwRay(e, Vec(0, -1, 0), 30)
			if h2 then at, n = VecAdd(e, Vec(0, DW_RIDE - d2, 0)), n2 end
		end
		if at and not IsPointInWater(at) then
			local sc = -math.abs(dist(at, eye.pos) - ring) * 0.4
			local up = at[2] - eye.pos[2]
			sc = sc + math.max(-4, math.min(8, up)) * 1.1              -- above them: what it wants most
			if up < 0.5 then sc = sc - 3 end                           -- (level with them or below: only when there is nothing else)
			if n[2] < 0.5 then sc = sc + 2 end                         -- on a wall or a ceiling
			sc = sc + (1 - math.abs(a) / 2.2) * 2                      -- behind them
			sc = sc - dist(at, s.pos) * 0.03
			if sc > bs then best, bs, bn = at, sc, n end
		end
	end
	return best, bn
end

-- a goal it may wander to
function spWanderGoal(s)
	local best, bd = nil, 1e9
	for _, p in ipairs(Prey.all()) do
		local d = dist(dwChest(p), s.pos)
		if d < bd then best, bd = p, d end
	end
	if best and math.random() < (s.far > 45 and 0.9 or 0.55) then    -- drawn to life
		local c = dwChest(best)
		local spread = math.max(8, math.min(26, bd * 0.4))
		local hi = nil                                                -- (of a few places near them, the highest)
		for _ = 1, 5 do
			local g = dwGround(VecAdd(c, Vec(rnd(-spread, spread), rnd(0, 9), rnd(-spread, spread))))
			if g and not IsPointInWater(g) and (not hi or g[2] > hi[2]) then hi = g end
		end
		if hi then return hi end
	end
	for _ = 1, 6 do
		local g = dwGround(VecAdd(s.pos, Vec(rnd(-18, 18), rnd(0, 8), rnd(-18, 18))))
		if g and not IsPointInWater(g) then return g end
	end
	return VecCopy(s.lair)
end

-- hearing, its second sense: a place to go and look at - unless its eyes have someone
function spHear(s, pos, t)
	if t - s.seenT < 2 then return end
	s.known = VecCopy(pos)
	s.knownT = t
	s.heard = (s.heard or 0) + 1
	if s.state == "roam" then spSetState(s, "stalk") end
end

function spSense(s)
	local t = now()
	local heard = dwHeard
	if heard and heard.vol > 0.04 then
		local own = false                                           -- (its own splats and the like: not prey)
		for _, o in ipairs(dwList) do if o.alive and dist(heard.pos, o.pos) < 3 then own = true end end
		if not own and dist(heard.pos, s.pos) < heard.vol * HEAR_K then spHear(s, heard.pos, t) end
	end
	for _, c in ipairs(dwChat) do                                   -- what was said over Proximity Comms
		if dist(c.pos, s.pos) < c.r * CHAT_HEAR then
			spHear(s, c.pos, t)
			s.heardChat = (s.heardChat or 0) + 1
		end
	end
	local eye = VecAdd(s.pos, VecScale(s.n, 0.25))
	local best, bestS, bestSaw = 0, 0, false
	for _, p in ipairs(Prey.all()) do
		do
			local c = dwChest(p)
			local d = dist(c, s.pos)
			local sc, saw = 0, false
			local lit = Prey.light(p)
			if d < (lit and LIGHT_SIGHT or SIGHT) then                -- sight
				local dir = VecScale(VecSub(c, eye), 1 / math.max(d, 0.01))
				if (d < SIGHT_NEAR or VecDot(dir, s.fwd) > SIGHT_BACK) and dwSee(eye, c) then
					sc, saw = lit and 5 or 4, true
				end
			end
			if sc == 0 then                                           -- what it feels
				if d < WEB_SENSE and Webs.level(p) > 0 then sc = 3      -- (its web trembles)
				elseif d < TOUCH_SENSE then sc = 2.5
				elseif d < MOVE_SENSE and vlen(Prey.vel(p)) > 2.5 then sc = 2
				elseif d < Prey.noise(p) * HEAR_K * 0.5 then sc = 1.5 end      -- (a villager's noise: heard, as a sound is)
			end
			if sc > 0 then sc = sc + 1 / (1 + d) + (p == s.target and 0.3 or 0) end
			if sc > bestS then best, bestS, bestSaw = p, sc, saw end
		end
	end
	if best ~= 0 then
		s.target = best
		s.known = dwChest(best)
		s.knownT = t
		s.seeing = bestSaw
		if bestSaw then s.seenT = t end
		if s.state == "roam" then spSetState(s, "stalk") end
	else
		s.seeing = false
	end
	s.far = 1e9
	for _, p in ipairs(Prey.all()) do
		s.far = math.min(s.far, dist(dwChest(p), s.pos))
	end
end

local function targetOk(s)
	local p = s.target
	return p ~= 0 and Prey.ok(p)
end

-- is player p looking at it?
local function lookedAt(s, p)
	local eye = Prey.eye(p)
	local v = VecSub(s.pos, eye.pos)
	local d = vlen(v)
	if d > 32 or d < 0.5 then return false end
	if VecDot(VecScale(v, 1 / d), TransformToParentVec(eye, Vec(0, 0, -1))) < 0.92 then return false end
	return dwSee(eye.pos, VecAdd(s.pos, VecScale(s.n, 0.2)))
end

-- decisions, a few times a second
function spThink(s, dts)
	local t = now()
	local st = s.state
	if st == "dead" or s.air or s.act then return end
	if st == "roam" then
		s.hp = math.min(DW_HP, s.hp + 0.8 * dts)
	elseif st == "stalk" then
		s.hp = math.min(DW_HP, s.hp + 0.8 * dts)
		if t - s.knownT > FORGET_T then return spSetState(s, "roam") end
		if targetOk(s) then
			local p = s.target
			local c = dwChest(p)
			local d = dist(c, s.pos)
			local sensed = t - s.seenT < 1.5
			-- the hunt, only for prey it sees: out of patience, prey close, prey in a web, prey's back turned close by
			local go = false
			if sensed then
				if t > s.patience and d < 30 then go = true end
				if s.seeing and d < 4 then go = true end
				if Webs.level(p) > 0 and t - s.stateT > rnd(0.5, 2.5) then go = true end
				if s.seeing and d < 8 and t - s.stateT > 20 then
					local eye = Prey.eye(p)
					if VecDot(VecNormalize(VecSub(s.pos, eye.pos)), TransformToParentVec(eye, Vec(0, 0, -1))) < -0.3 and math.random() < 0.08 then go = true end
				end
			end
			if go then return spSetState(s, "hunt") end
			-- looked at: it freezes and stares, or scuttles off to somewhere else, or it comes
			if lookedAt(s, p) then s.watch = s.watch + dts else s.watch = math.max(0, s.watch - dts * 0.5) end
			if s.watch > 0.9 and t > s.spotCd then
				s.spotCd = t + rnd(5, 9)
				s.watch = 0
				local r = math.random()
				if r < 0.45 then
					s.stareUntil = t + rnd(1.5, 4)
				elseif r < 0.9 then
					s.vantage = nil
					s.tempo, s.tempoUntil = 2.2, t + 1.5                  -- (a dart)
				else
					return spSetState(s, "hunt")
				end
			end
			-- its vantage: closer the longer it has stalked
			local ring = math.max(7, 18 - 0.1 * (t - s.stateT))
			-- (felt close by but not seen, e.g. through a floor: no use sitting there - a vantage, where their eyes reach)
			local feltNear = s.known and t - s.knownT < 2 and dist(s.known, s.pos) < 3.5
			if t - s.seenT > 5 and not feltNear then
				s.vantage = nil                                          -- (out of its sight: it goes to look where it last knew them)
			elseif not s.vantage or t > s.vantageUntil or dist(s.vantage, c) > ring + 12 or dist(s.vantage, c) < 3 then
				local v = spVantage(s, p, ring)
				if v then
					s.vantage = v
					s.vantageUntil = t + rnd(9, 20)
				end
			elseif dist(s.vantage, s.pos) < 1.3 and s.vantageUntil - t > 8 then
				s.vantageUntil = t + rnd(3, 8)                           -- (there: it sits a while, then moves again)
			end
		end
	elseif st == "hunt" then
		if not targetOk(s) then
			s.target = 0
			return spSetState(s, "roam")
		end
		-- out of sight: it runs to where it last saw them, and only there (or after a while) gives the hunt up
		local lost = t - s.seenT
		if lost > HUNT_LOSE_MAX or (lost > HUNT_LOSE and (not s.known or dist(s.known, s.pos) < 3.5)) then
			return spSetState(s, "stalk")
		end
		if t - s.stateT > s.huntMax then return spRetreat(s) end      -- (it tires: back into the dark)
	elseif st == "retreat" then
		if (s.hide and dist(s.hide, s.pos) < 2) or t - s.stateT > 9 then
			if s.known then s.knownT = t end
			spSetState(s, "stalk")
			s.patience = t + rnd(25, 60)
		end
	elseif st == "flee" then
		if (s.hide and dist(s.hide, s.pos) < 2.5) or t - s.stateT > 22 then spSetState(s, "hide") end
	elseif st == "hide" then
		s.hp = math.min(DW_HP, s.hp + 4 * dts)
		if s.far < 7 and s.seeing then
			if s.hp > DW_HP * 0.45 then spSetState(s, "hunt") else spFlee(s) end
		elseif s.hp > DW_HP * 0.7 or t - s.stateT > 45 then
			spSetState(s, "roam")
		end
	end
end

-- where it is going, per state (nil: nowhere)
function spGoal(s)
	local t = now()
	local st = s.state
	if st == "roam" then
		if not s.goal or t > s.wanderT or dist(s.goal, s.pos) < 1.5 then
			s.goal = spWanderGoal(s)
			s.wanderT = t + rnd(8, 28)
		end
		return s.goal
	elseif st == "stalk" then
		if t < s.stareUntil then return nil end
		if s.vantage and targetOk(s) then
			if dist(s.vantage, s.pos) < 1.2 then return nil end
			return s.vantage
		end
		if s.known then
			if not s.goal or dist(s.goal, s.known) > 4 then s.goal = dwGround(s.known) or s.known end
			if dist(s.goal, s.pos) < 2 then return nil end
			return s.goal
		end
		return nil
	elseif st == "hunt" then
		if targetOk(s) and t - s.knownT < 1 then
			local feet = Prey.feet(s.target)
			if not s.goal or dist(s.goal, feet) > 1.2 then s.goal = dwGround(feet) or feet end
			return s.goal
		end
		if s.known then return dwGround(s.known) or s.known end
		return nil
	elseif st == "retreat" or st == "flee" then
		return s.hide
	end
	return nil
end

----- the path -----

-- the point to steer at on the way to goal
function spAim(s, goal)
	local t = now()
	local d = dist(goal, s.pos)
	s.pathEnd = false
	if d < 1.3 then
		s.path = nil
		return goal
	end
	local replan = not s.planGoal or dist(s.planGoal, goal) > math.max(2, 0.2 * d) or t - s.planT > 5 or s.replan
	if replan and not s.planning and t >= (s.planHold or 0) then
		SNav.request(s.id, s.pos, goal)
		s.planGoal = VecCopy(goal)
		s.planT = t
		s.planning = true
		s.replan = false
	end
	if s.planning then
		local r = SNav.result(s.id)
		if r then
			s.planning = false
			s.planOk, s.planLen = r.ok, r.len
			if #r.points >= 2 then
				s.path, s.pathI = r.points, 1
			else
				s.path = nil
				s.planHold = t + 1.5
				s.pathEnd = true
			end
		end
	end
	local P = s.path
	if P then
		local i = s.pathI
		for j = i + 1, math.min(#P, i + 4) do                        -- (a later point is nearer: it cut a corner)
			if dist(P[j], s.pos) < dist(P[i], s.pos) then i = j end
		end
		while i < #P and dist(P[i], s.pos) < 0.8 do i = i + 1 end
		s.pathI = i
		if i >= #P and dist(P[i], s.pos) < 0.9 then                  -- the end of the plan
			if s.planOk then return goal end
			s.pathEnd = true                                          -- (as far as the surface goes: a web line, a drop)
			if s.via then                                             -- (no way to that line's end: not that end again soon)
				local l = s.via.line
				l.bad = l.bad or {}
				l.bad[s.via.k] = t + 60
				s.via, s.viaT = nil, t + 2
			end
			return goal
		end
		return P[i]
	end
	return goal                                                    -- (no plan yet: straight at it)
end

----- motion on a surface -----

function spTempo(s)
	local tab = TEMPO[s.state]
	if not tab then return 1 end
	if now() >= s.tempoUntil then
		local e = pick(tab)
		s.tempo = e[2]
		s.tempoUntil = now() + rnd(e[3], e[4])
	end
	return s.tempo
end

function spLand(s, pos, n)
	local was = s.air
	if not dwSurf(pos, DW_RIDE + 0.8) then                         -- (what it was coming to is gone, e.g. broken glass: it falls)
		s.pos = VecCopy(pos)
		s.line = nil
		s.air = {kind = "fall", vel = Vec(0, 0, 0), t0 = now()}
		return
	end
	s.pos = VecCopy(pos)
	s.n = VecNormalize(n)
	s.air = nil
	s.line = nil
	s.fwd = tangent(s.fwd, s.n) or anyTangent(s.n)
	s.speed = 0
	s.vel = Vec(0, 0, 0)
	s.path, s.planGoal = nil, nil
	s.stuckT, s.stuckD = now(), 1e9
	s.landT = now()
	if was and was.kind == "zip" then
		if was.reuse then
			Webs.renewLine(was.reuse)
		else
			Webs.addLine(was.anchor0, was.n0, was.anchor, was.toN)     -- (it stays strung: a way across for later)
			Webs.addPatch(was.anchor, was.toN, 0.7)
		end
	end
end

-- one step toward aim at `want` m/s along the surface it is on
function spStep(s, aim, want, dt)
	local t = now()
	if t < s.flinchUntil and s.flinchDir then
		aim = VecAdd(s.pos, VecScale(s.flinchDir, 3))
		want = 9
	end
	local k = want > s.speed and 9 or 14                           -- (snappy starts, dead stops)
	s.speed = s.speed + (want - s.speed) * math.min(1, k * dt)
	local n = s.n
	local d = aim and tangent(VecSub(aim, s.pos), n)
	local dir = tangent(s.fwd, n) or anyTangent(n)
	local headway = 1
	if d then
		local turn = VecLerp(dir, d, math.min(1, (s.state == "hunt" and 11 or 7) * dt))
		if vlen(turn) < 0.2 then turn = d end                        -- (straight behind it: it just turns)
		dir = tangent(turn, n) or d
		headway = math.max(0.12, VecDot(dir, d))
	end
	s.fwd = dir
	local step = s.speed * dt * headway
	if step < 0.0004 or not d then
		s.vel = Vec(0, 0, 0)
		s.blocked = false
		-- (still: what it sat on may have been blown away, or was gone when it landed - then it falls)
		if not dwSurf(s.pos, DW_RIDE + 0.8) then
			s.air = {kind = "fall", vel = Vec(0, 0, 0), t0 = t}
			SNav.forget(s.pos, 2)
		end
		return
	end
	-- something in its way: up to it (the snap below then puts it on that surface)
	local hit, hd = dwRay(s.pos, dir, step + 0.15, 0.1)
	if hit then step = math.max(0, math.min(step, hd - 0.02)) end
	local cand = VecAdd(s.pos, VecScale(dir, step))
	local cp, nn = dwSurf(cand, DW_RIDE + 0.8)
	if not cp then                                                 -- nothing under it any more: it falls
		s.air = {kind = "fall", vel = VecScale(dir, s.speed), t0 = t}
		SNav.forget(s.pos, 2)
		return
	end
	local np = VecAdd(cp, VecScale(nn, DW_RIDE))
	s.vel = VecScale(VecSub(np, s.pos), 1 / dt)
	s.blocked = dist(np, s.pos) < step * 0.2
	s.pos = np
	s.n = nn
end

----- its own lines, used again: a line strung earlier is a way across for as long as it hangs -----

-- the best strung line toward goal: {line, start, startN, to, toN, a, b} (walk to start, run the line to `to`)
function spLineRoute(s, goal)
	local dg = dist(goal, s.pos)
	local best, bc = nil, LINE_WORTH * dg
	for _, l in ipairs(Webs.lines()) do
		if l.len >= 4 then
			for k = 1, 2 do
				local a, an, b, bn = l.a, l.an, l.b, l.bn
				if k == 2 then a, an, b, bn = l.b, l.bn, l.a, l.an end
				local start = VecAdd(a, VecScale(an, DW_RIDE))
				local to = VecAdd(b, VecScale(bn, DW_RIDE))
				local d0 = dist(s.pos, start)
				local cost = d0 + 0.35 * l.len + dist(to, goal)
				if d0 < 25 and cost < bc and now() > ((l.bad or {})[k] or 0) then
					best, bc = {line = l, start = start, startN = an, to = to, toN = bn, a = a, b = b, k = k}, cost
				end
			end
		end
	end
	return best
end

-- onto a strung line at its end (no shot): it runs across
function spRideLine(s, v)
	local t = now()
	local from = VecAdd(s.pos, VecScale(s.n, 0.3))
	s.air = {kind = "zip", from = from, to = v.to, toN = v.toN, anchor = v.b, anchor0 = v.a, reuse = v.line,
		len = math.max(0.5, dist(from, v.to)), u = 0, sag = wbSag(v.line.len), n0 = VecCopy(s.n), t0 = t, speed = LINE_RUN}
	s.line = {a = v.a, b = v.b, grow = 1}
	s.pos = from
	s.reused = (s.reused or 0) + 1
	s.via = nil
end

----- glass: what breaks easily it goes through, not round (not when it stalks: that is done quietly) -----

-- glass within SMASH_REACH on the straight line toward `toward`: the point, the direction
function spGlassAhead(s, toward)
	local o = VecAdd(s.pos, VecScale(s.n, 0.2))
	local d = VecSub(toward, o)
	local l = vlen(d)
	if l < 0.8 then return nil end
	local dir = VecScale(d, 1 / l)
	dwFilter()
	local hit, hd, hn, shape = QueryRaycast(o, dir, math.min(l, SMASH_REACH), 0.1)
	if not hit then return nil end
	local at = VecAdd(o, VecScale(dir, hd + 0.1))
	if dwGlass(shape, at, dir) then return at, dir end
	return nil
end

function spSmash(s, at, dir)
	MakeHole(VecAdd(at, VecScale(dir, 0.1)), SMASH_R, 0, 0)
	SNav.forget(at, 3)
	s.smashed = s.smashed + 1
	s.path, s.planGoal = nil, nil
	s.stuckT, s.stuckD = now(), 1e9
end

----- vegetation: a tree's twigs and leaves are a maze of tiny surfaces; where it makes no headway it chews through -----

local LEAF_DIRS = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

local function isLeaf(shape, at)
	return shape and shape ~= 0 and GetShapeMaterialAtPosition(shape, at) == "foliage"
end

-- leaves at or about it (what it sits on, what lies toward aim, anything within CHEW_LOOK m): where to bite, or nil
function spLeaves(s, aim)
	dwFilter()
	local hit, cp, _, shape = QueryClosestPoint(s.pos, DW_RIDE + 0.8)
	if hit then
		local d = VecSub(cp, s.pos)
		local l = vlen(d)
		if l > 0.01 and isLeaf(shape, VecAdd(cp, VecScale(d, 0.05 / l))) then return cp end
	end
	local dirs = {}
	local toAim = aim and VecSub(aim, s.pos)
	if toAim and vlen(toAim) > 0.1 then dirs[1] = VecNormalize(toAim) end
	for _, d in ipairs(LEAF_DIRS) do dirs[#dirs + 1] = d end
	local o = VecAdd(s.pos, VecScale(s.n, 0.1))
	for _, dir in ipairs(dirs) do
		dwFilter()
		local h, hd, _, sh = QueryRaycast(o, dir, CHEW_LOOK, 0.05)
		if h and isLeaf(sh, VecAdd(o, VecScale(dir, hd + 0.05))) then return VecAdd(o, VecScale(dir, hd)) end
	end
	return nil
end

-- a bite out of the tree: the leaves and twigs round it and toward aim (soft materials only), then it plans afresh
function spChew(s, at, aim)
	local c = VecLerp(s.pos, at, 0.5)
	local d = aim and VecSub(aim, s.pos)
	if d and vlen(d) > 0.1 then c = VecAdd(c, VecScale(VecNormalize(d), 0.5)) end
	MakeHole(c, CHEW_R, 0, 0, s.state == "stalk" or s.state == "hide")      -- (stalking: without a sound)
	SNav.forget(c, CHEW_R + 2)
	s.chewed = (s.chewed or 0) + 1
	s.path, s.planGoal = nil, nil
	s.fangs = 1
end

----- through the air -----

-- a surface to shoot a line at that brings it nearer to goal: anchor point, its normal, the landing point
function spFindZip(s, goal, minGain)
	local o = VecAdd(s.pos, VecScale(s.n, 0.55))
	local to = VecSub(goal, o)
	local dg = vlen(to)
	if dg < ZIP_MIN then return nil end
	local gdir = VecScale(to, 1 / dg)
	local best, bs = nil, minGain
	for i = 1, 6 do
		local dir = gdir
		if i > 1 then
			dir = VecNormalize(VecAdd(gdir, Vec(rnd(-0.45, 0.45), rnd(-0.1, 0.75), rnd(-0.45, 0.45))))
		end
		if VecDot(dir, s.n) > -0.2 then                              -- (not into what it stands on)
			local hit, d, hn = dwRay(o, dir, math.min(ZIP_MAX, dg + 6))
			if hit and d >= ZIP_MIN then
				local anchor = VecAdd(o, VecScale(dir, d))
				local landAt = VecAdd(anchor, VecScale(hn, DW_RIDE))
				local gain = dg - dist(landAt, goal)
				local sc = gain - 0.12 * d + (hn[2] < 0.5 and 1.5 or 0)
				if sc > bs and not IsPointInWater(landAt) and not dwRay(o, dir, d - 0.6, 0.22) then
					best, bs = {anchor = anchor, n = hn, to = landAt, len = d}, sc
				end
			end
		end
	end
	return best
end

function spZip(s, z)
	local t = now()
	s.act = {kind = "zipcast", t0 = t, dur = ZIP_CAST, z = z}
	s.line = {a = VecCopy(s.pos), b = z.anchor, grow = 0}
	s.zipCd = t + rnd(3, 6)
	s.speed = 0
	if s.state == "hunt" then s.ev.zip = s.ev.zip + 1 end          -- (silent unless it hunts)
	local d = tangent(VecSub(z.anchor, s.pos), s.n)
	if d then s.fwd = d end
end

-- should it take a line now? Where the surface path fails or winds, and now and then just because it can
function spMaybeZip(s, goal, dt)
	local t = now()
	if t < s.zipCd or t < s.zipTryT or not goal then return false end
	local dg = dist(goal, s.pos)
	if dg < ZIP_MIN + 1 then return false end
	local need, gain = false, math.max(4, 0.35 * dg)
	if s.pathEnd or (not s.planning and s.planGoal and not s.planOk) then
		need, gain = true, 2.5                                       -- (the surface does not go there)
	elseif not s.planning and s.planOk and s.planLen > 1.6 * dg + 4 then
		need = true                                                   -- (the long way round)
	elseif s.stuckN >= 2 then
		need, gain = true, 2
	else
		local rate = (s.state == "hunt" or s.state == "flee" or s.state == "retreat") and 0.3 or
			(s.state == "stalk" and 0.1 or (s.far > 45 and 0.15 or 0.03))
		need = dg > 9 and math.random() < rate * 0.5                  -- (called every 0.5 s)
	end
	s.zipTryT = t + 0.5
	if not need then return false end
	local z = spFindZip(s, goal, gain)
	if not z then return false end
	spZip(s, z)
	return true
end

function spLeap(s, p)
	local t = now()
	local c = dwChest(p)
	local from = VecAdd(s.pos, VecScale(s.n, 0.25))
	local d = dist(c, from)
	local T = math.max(0.28, math.min(0.65, d / 13))
	local lead = VecAdd(c, VecScale(Prey.vel(p), T * 0.6))
	local v = VecScale(VecSub(lead, from), 1 / T)
	v[2] = v[2] + 0.5 * DW_GRAV * T
	s.pos = from
	s.air = {kind = "leap", vel = v, t0 = t, target = p}
	s.ev.leap = s.ev.leap + 1
	s.leapCd = t + rnd(2.5, 4.5)
	s.fangs = 1
end

function spBite(s, p, dmg)
	local killed = Prey.hurt(p, dmg, s.pos)
	s.ev.bite = s.ev.bite + 1
	s.fangs = 1
	s.biteCd = now() + rnd(0.9, 1.4)
	s.bites = (s.bites or 0) + 1
	if killed then
		s.target = 0
		spRetreat(s)                                                 -- (it has fed: back into the dark)
	elseif math.random() < 0.3 then
		spRetreat(s)                                                 -- (hit and run)
	end
end

function spAir(s, dt)
	local a = s.air
	local t = now()
	if a.kind == "zip" then
		a.u = a.u + (a.speed or ZIP_SPEED) * dt / a.len
		local u = math.min(1, a.u)
		local p = VecLerp(a.from, a.to, u)
		p[2] = p[2] - a.sag * math.sin(math.pi * u)
		local d = VecSub(p, s.pos)
		local l = vlen(d)
		if l > 1e-4 and u < 0.92 then
			local dir = VecScale(d, 1 / l)
			local hit, hd, hn = dwRay(s.pos, dir, l + 0.1, 0.12)
			if hit then                                               -- something in the line's way: it lands there
				a.anchor = VecAdd(s.pos, VecScale(dir, hd + 0.12))
				a.toN = hn
				return spLand(s, VecAdd(VecAdd(s.pos, VecScale(dir, hd)), VecScale(hn, DW_RIDE - 0.12)), hn)
			end
		end
		s.vel = VecScale(d, 1 / dt)
		s.pos = p
		s.up = VecNormalize(VecLerp(a.n0, a.toN, u))
		s.speed = a.speed or ZIP_SPEED
		if s.line then s.line.a = VecCopy(a.anchor0); s.line.grow = 1 end
		if u >= 1 then spLand(s, a.to, a.toN) end
		return
	end
	-- a leap or a fall
	a.vel = VecAdd(a.vel, Vec(0, -DW_GRAV * dt, 0))
	local d = VecScale(a.vel, dt)
	local l = vlen(d)
	if a.kind == "leap" and not a.bit and a.target and Prey.ok(a.target)
		and not Prey.inVehicle(a.target) and dist(s.pos, dwChest(a.target)) < 1.3 then
		a.bit = true
		a.vel = VecScale(a.vel, 0.25)
		spBite(s, a.target, LEAP_DMG)
	end
	if l > 1e-5 then
		local dir = VecScale(d, 1 / l)
		local hit, hd, hn, shape = dwRay(s.pos, dir, l + 0.05, 0.15)
		if hit and s.alive and dwGlass(shape, VecAdd(s.pos, VecScale(dir, hd + 0.15)), dir) then
			spSmash(s, VecAdd(s.pos, VecScale(dir, hd + 0.15)), dir)    -- (a leap goes straight through a window)
			hit = false
		end
		if hit then
			return spLand(s, VecAdd(VecAdd(s.pos, VecScale(dir, hd)), VecScale(hn, DW_RIDE - 0.15)), hn)
		end
		s.pos = VecAdd(s.pos, d)
		s.vel = VecCopy(a.vel)
		local f = tangent(a.vel, Vec(0, 1, 0))
		if f and s.alive then s.fwd = f end
	end
	s.speed = vlen(a.vel)
	if t - a.t0 > 6 or s.pos[2] < dwLo[2] - 30 then                -- (out of the world: back to where it came from)
		local g, gn = dwGround(s.lair)
		spLand(s, g or s.lair, gn or Vec(0, 1, 0))
	end
end

----- actions: short moments it stands still for -----

function spAct(s, dt)
	local a = s.act
	local t = now()
	local u = (t - a.t0) / a.dur
	s.speed = 0
	s.vel = Vec(0, 0, 0)
	if targetOk(s) and a.kind ~= "zipcast" then                    -- (it faces its prey)
		local d = tangent(VecSub(dwChest(s.target), s.pos), s.n)
		if d then s.fwd = tangent(VecLerp(s.fwd, d, math.min(1, 12 * dt)), s.n) or d end
	end
	if a.kind == "screech" then
		s.rear = math.min(1, u * 4)
		s.fangs = 1
	elseif a.kind == "spit" then
		s.rear = math.min(0.8, u * 3)
		s.fangs = 1
	elseif a.kind == "leapwind" then
		s.rear = 0.35
		s.fangs = 0.8
	elseif a.kind == "zipcast" then
		if s.line then s.line.grow = math.min(1, u) end
	end
	if u < 1 then return end
	s.act = nil
	if a.kind == "spit" then
		if targetOk(s) then
			local p = s.target
			local from = VecAdd(VecAdd(s.pos, VecScale(s.fwd, 0.6)), VecScale(s.n, 0.25))
			local c = dwChest(p)
			local T = dist(c, from) / SHOT_SPEED
			local aim = VecAdd(c, VecScale(Prey.vel(p), T * rnd(0.6, 1.0)))
			aim = VecAdd(aim, Vec(rnd(-0.35, 0.35), rnd(-0.3, 0.2), rnd(-0.35, 0.35)))
			local v = VecScale(VecSub(aim, from), 1 / math.max(0.05, T))
			v[2] = v[2] + 0.5 * SHOT_G * T
			Webs.shoot(from, VecScale(VecNormalize(v), SHOT_SPEED), s.id)
			s.ev.spit = s.ev.spit + 1
		end
		s.shotCd = t + rnd(3.5, 6.5)
	elseif a.kind == "leapwind" then
		if targetOk(s) then spLeap(s, s.target) end
	elseif a.kind == "zipcast" then
		local z = a.z
		local from = VecAdd(s.pos, VecScale(s.n, 0.3))
		s.air = {kind = "zip", from = from, to = z.to, toN = z.n, anchor = z.anchor, anchor0 = VecSub(s.pos, VecScale(s.n, DW_RIDE)),
			len = math.max(0.5, dist(from, z.to)), u = 0, sag = wbSag(z.len), n0 = VecCopy(s.n), t0 = t}
		s.pos = from
	end
end

-- the hunt's attacks; true when one began
function spAttack(s)
	local t = now()
	if not targetOk(s) or t - s.knownT > 1 then return false end
	local p = s.target
	local c = dwChest(p)
	local d = dist(c, s.pos)
	local veh = Prey.inVehicle(p)
	if d < BITE_R and t > s.biteCd and not veh then
		spBite(s, p, BITE_DMG)
		return s.state ~= "hunt"
	end
	if veh then return false end
	local see = s.seeing and dwSee(VecAdd(s.pos, VecScale(s.n, 0.3)), c)
	if not see then return false end
	if d > LEAP_MIN and d < LEAP_MAX and t > s.leapCd then
		s.act = {kind = "leapwind", t0 = t, dur = 0.3}
		s.ev.hiss = s.ev.hiss + 1
		return true
	end
	if d > SHOT_MIN and d < SHOT_MAX and t > s.shotCd and Webs.level(p) < 2 then
		s.act = {kind = "spit", t0 = t, dur = 0.42}
		s.ev.hiss = s.ev.hiss + 1
		return true
	end
	return false
end

function spUpdate(s, dt)
	local t = now()
	s.fangs = math.max(0, s.fangs - dt * 2.2)
	if s.air then
		spAir(s, dt)
		s.up = VecNormalize(VecLerp(s.up, s.air and Vec(0, 1, 0) or s.n, math.min(1, 6 * dt)))
		return
	end
	if not s.alive then return end
	s.up = VecNormalize(VecLerp(s.up, s.n, math.min(1, 10 * dt)))
	if vlen(s.up) < 0.5 then s.up = VecCopy(s.n) end
	if s.act then return spAct(s, dt) end
	s.rear = math.max(0, s.rear - dt * 3)
	if s.state == "hunt" and spAttack(s) then return end
	local goal = spGoal(s)
	if goal and s.state ~= "stalk" and s.state ~= "hide" and t > s.glassT then
		s.glassT = t + 0.3
		local at, dir = spGlassAhead(s, goal)
		s.smash = at and {at = at, dir = dir, untilT = t + 3} or nil
	end
	if s.state == "stalk" or not goal then s.smash = nil end
	-- a line it strung before, if that is the short way: to its end, then across
	if goal and t > (s.viaT or 0) then
		s.viaT = t + 1
		s.via = (not s.smash and dist(goal, s.pos) > 8) and spLineRoute(s, goal) or nil
	end
	if not goal then s.via = nil end
	if s.via then
		if dist(s.via.start, s.pos) < 1.6 then
			spRideLine(s, s.via)
			return
		end
		goal = s.via.start
	end
	if goal and s.state ~= "hide" and not s.smash and not s.via and spMaybeZip(s, goal, dt) then return end
	local aim = goal and spAim(s, goal) or nil
	local base = SPEED[s.state] or 0
	if s.state == "roam" and s.far > 45 then base = SPEED.stalk * 1.4 end        -- (far from everyone: it travels)
	if s.state == "stalk" and targetOk(s) and Webs.level(s.target) > 0 then base = SPEED.hunt * 0.8 end   -- (its web has someone)
	local want = aim and base * spTempo(s) or 0
	-- stalking prey that walks away, it keeps up (silently, without its pauses); near its vantage it creeps
	if aim and s.state == "stalk" and goal and dist(goal, s.pos) > 9 then want = math.max(want, 6.5) end
	if aim and s.planning and not s.path then want = want * 0.5 end
	if s.smash then                                                -- glass in its way: straight at it and through
		if t > s.smash.untilT then
			s.smash = nil
		elseif dist(s.smash.at, s.pos) < 1.4 then
			spSmash(s, s.smash.at, s.smash.dir)
			local d = tangent(s.smash.dir, s.n)
			if d then s.flinchUntil, s.flinchDir = t + 0.3, d end       -- (a dash through the hole)
			s.smash = nil
		else
			aim = s.smash.at
			want = math.max(want, base)
		end
	end
	spStep(s, aim, want, dt)
	if not aim then                                                -- still: it faces its prey, or looks about
		if targetOk(s) and (s.state == "stalk" or s.state == "hide") then
			local d = tangent(VecSub(dwChest(s.target), s.pos), s.n)
			if d then s.fwd = tangent(VecLerp(s.fwd, d, math.min(1, 3 * dt)), s.n) or s.fwd end
		elseif math.random() < 0.25 * dt then
			local side = VecCross(s.n, s.fwd)
			s.fwd = tangent(VecAdd(s.fwd, VecScale(side, rnd(-1.2, 1.2))), s.n) or s.fwd
		end
		s.stuckT, s.stuckD = t, 1e9
		return
	end
	-- stuck: no headway toward the aim for a while -> plan again, then a line, a drop, or somewhere else
	local d = dist(aim, s.pos)
	if d < s.stuckD - 0.25 then
		s.stuckD = d
		s.stuckT = t
		if s.stuckN > 0 and d < 1 then s.stuckN = 0 end
	elseif want > 0.5 and t - s.stuckT > 1.2 then
		s.stuckT, s.stuckD = t, 1e9
		s.stuckN = s.stuckN + 1
		s.replan = true
		SNav.forget(s.pos, 1.5)
		local leaf = spLeaves(s, aim)
		if leaf then                                                 -- caught in a tree: it chews its way out
			spChew(s, leaf, aim)
			s.stuckN = 0
		elseif s.stuckN >= 3 then
			s.stuckN = 0
			if goal and goal[2] < s.pos[2] - 1.5 and s.n[2] < 0.9 then            -- (what it wants is below: it lets go)
				s.air = {kind = "fall", vel = VecScale(s.n, 1.2), t0 = t}
			elseif s.state == "roam" then
				s.goal = nil
				s.wanderT = 0
			elseif s.state == "stalk" then
				s.vantage = nil
			elseif s.state == "retreat" or s.state == "flee" then
				s.hide = spHideSpot(s, s.known or s.pos, 12, 30) or s.hide
			end
		end
	end
	if d > s.stuckD + 2 then s.stuckD = d end
end

----- publishing -----

function dwPublish()
	dwSeq = dwSeq + 1
	local t = now()
	local out = {n = dwSeq, t = t, marks = dwMarks or {}}
	for i, s in ipairs(dwList) do
		local eyes = EYES[s.state] or 0.5
		if t < s.stareUntil then eyes = 1.3 end
		if s.act and s.act.kind == "screech" then eyes = 1.4 end
		local e = s.ev
		local o = {id = s.id, alive = s.alive, state = s.state, x = s.pos[1], y = s.pos[2], z = s.pos[3],
			ux = s.up[1], uy = s.up[2], uz = s.up[3], fx = s.fwd[1], fy = s.fwd[2], fz = s.fwd[3],
			speed = s.speed, air = s.air and s.air.kind or "", rear = s.rear, fangs = s.fangs, eyes = eyes,
			hunt = s.state == "hunt", deadT = s.deadT, hp = s.hp / DW_HP,
			screech = e.screech, hiss = e.hiss, spit = e.spit, leap = e.leap, bite = e.bite, hurt = e.hurt, die = e.die,
			zip = e.zip, hits = s.hits}
		if s.line then
			local l = s.line
			o.line = {l.a[1], l.a[2], l.a[3], l.b[1], l.b[2], l.b[3], l.grow}
		end
		out[i] = o
	end
	shared.dw = out
end

----- callbacks -----

function Spider.serverInit()
	dwList = {}
	dwHitShapes = {}
	dwNextId = 1
	if DW_ASSET then                                               -- (several scripts at once: ids that do not collide)
		dwNextId = 1000 + GetInt("dreadweaver.assetseq")
		SetInt("dreadweaver.assetseq", GetInt("dreadweaver.assetseq") + 1)
	end
	dwStrikeSeen = nil
	dwSeq = 0
	dwPubT = 0
	dwSenseT = 0
	dwMaskT = 0
	dwSpawnSearch = nil
	dwRespawnAt = {}
	dwHitpointsLast = nil
	dwHeard = nil
	dwChat = {}
	dwSaid = nil
	dwLo, dwHi = Vec(-200, -50, -200), Vec(200, 100, 200)
	if not DW_ASSET then
		SetString("dreadweaver.hitpoints", "")
		SetString("dreadweaver.damage", "")
	end
	dwVillagersInit()
	local c = GetInt("savegame.mod.count")
	if c < 1 then c = 1 end
	DW_COUNT = math.min(3, c)
	DW_AUTO = not GetBool("savegame.mod.autooff")                  -- off: only the spawn menu's markers make spiders
	if not DW_AUTO then DW_COUNT = 0 end
	if not DW_ASSET then for _, b in ipairs(FindBodies("dreadweaverhit", true) or {}) do Delete(b) end end
	SNav.init({cell = 0.5, reach = 0.9, clear = 0.2, ride = DW_RIDE, budget = 400, maxNodes = 3000, mask = DW_MASK})
	for i = 1, DW_COUNT do dwRespawnAt[#dwRespawnAt + 1] = SPAWN_DELAY + (i - 1) * 8 end
	shared.dw = {n = 0, t = 0}
end

-- look for a lair over a few frames: 16 candidates per frame, the best after 2 s
function dwSpawnTick()
	local t = now()
	if not dwSpawnSearch then
		local due = false
		for _, at in ipairs(dwRespawnAt) do if t >= at then due = true end end
		if not due or #GetAllPlayers() == 0 then return end
		local lo, hi = dwMapBounds()
		dwLo, dwHi = lo, hi
		dwSpawnSearch = {lo = lo, hi = hi, minD = math.min(45, 0.3 * dist(lo, hi)), best = nil, score = -1, untilT = t + 2}
	end
	local q = dwSpawnSearch
	for _ = 1, 16 do
		local p, sc, n = dwCandidate(q.lo, q.hi, q.minD)
		if p and sc > q.score then q.best, q.score, q.bestN = p, sc, n end
	end
	if t >= q.untilT then
		if q.best then
			table.remove(dwRespawnAt, 1)
			dwList[#dwList + 1] = spNew(q.best, q.bestN)
			dwSpawnSearch = nil
		else
			q.minD = q.minD * 0.7                                     -- (a small map: closer)
			q.untilT = t + 2
		end
	end
end

-- spawn-menu spiders: the marker prefab (prefab/spawner.xml) stays where it is put (or is carried to) for
-- SPAWN_MARK_T s, the seconds counted down over it (SpiderView.clientDraw), then becomes a spider where it is by then
function dwSpawnMenu()
	local t = now()
	local seen, marks = {}, {}
	local tag = DW_ASSET and "dwasset" or "dreadweaverspawn"
	for _, b in ipairs(FindBodies(tag, not DW_ASSET) or {}) do      -- (asset mode: only this script's own marker)
		seen[b] = true
		if not dwMarkT0[b] then
			-- the spawn menu holds a PREVIEW of the prefab in front of the camera before the click (the game's
			-- spawn.lua: every shape on layer 0, mask 0); the placed marker has mask 255. The count starts when it is
			-- put down, not while the player still aims (the user, 2026-11-13). No shapes: counts as placed.
			local shapes = GetBodyShapes(b) or {}
			local preview = #shapes > 0
			for _, sh in ipairs(shapes) do
				local _, mask = GetShapeCollisionFilter(sh)
				if (mask or 0) ~= 0 then preview = false end
			end
			if not preview then dwMarkT0[b] = t end
		end
		local t0 = dwMarkT0[b]
		if t0 then                                                     -- (nil: the menu's preview - nothing yet)
			local p = GetBodyTransform(b).pos
			local left = SPAWN_MARK_T - (t - t0)
			if left <= 0 then
				Delete(b)
				dwMarkT0[b] = nil
				local alive = 0
				for _, s in ipairs(dwList) do if s.alive then alive = alive + 1 end end
				if alive < DW_MAX then                                     -- (at the cap the marker just goes)
					local g, n = dwGround(VecAdd(p, Vec(0, 0.5, 0)))
					dwList[#dwList + 1] = spNew(g or VecAdd(p, Vec(0, DW_RIDE, 0)), n)
				end
			else
				local k = #marks
				marks[k + 1], marks[k + 2], marks[k + 3], marks[k + 4] = p[1], p[2], p[3], left
			end
		end
	end
	for b in pairs(dwMarkT0) do if not seen[b] then dwMarkT0[b] = nil end end
	dwMarks = marks
end

-- what players say over Proximity Comms (its events in the host's registry: proxchat.said.*; typed lines and voice
-- alike): heard within the line's own range (a whisper 8 m, speech 25, a yell 40). Global lines are not sounds
function dwHearChat()
	local last = GetInt("proxchat.said.last")
	if dwSaid == nil or last < dwSaid then dwSaid = last end
	for n = math.max(dwSaid + 1, last - 15), last do
		local k = "proxchat.said." .. (n % 16) .. "."
		local mode = GetString(k .. "mode")
		if GetString(k .. "agent") == "" and GetString(k .. "channel") == "" and mode ~= "global" and mode ~= "g"
			and not GetBool(k .. "lobby") then
			local r = GetFloat(k .. "radius")
			if r <= 0 then r = 25 end
			dwChat[#dwChat + 1] = {pos = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z")), r = math.min(r, 60),
				p = GetInt(k .. "player")}
		end
	end
	dwSaid = last
end

function Spider.serverTick(dt)
	Prey.dirty()
	local t = now()
	SNav.tick()
	dwSpawnTick()
	if math.floor(t * 10) ~= math.floor((t - dt) * 10) then dwSpawnMenu() end
	dwTakeHits()
	dwTakeStrikes()
	dwTakeApiDamage()
	-- GetLastSound is the loudest sound of the last frame only: listen every frame, keep the loudest until the senses
	local sv, sp = GetLastSound()
	if sv and sv > 0.04 and sp and (not dwHeard or sv > dwHeard.vol) then dwHeard = {vol = sv, pos = VecCopy(sp)} end
	dwHearChat()
	local sense = t - dwSenseT > 1 / DW_SENSE_HZ
	local dts = t - dwSenseT
	if sense then dwSenseT = t end
	for i = #dwList, 1, -1 do
		local s = dwList[i]
		if s.alive then
			if sense then
				spSense(s)
				spThink(s, math.min(0.5, dts))
			end
			spBoxesMove(s)
		elseif t - s.deadT > CORPSE_T then
			table.remove(dwList, i)
			if DW_AUTO then dwRespawnAt[#dwRespawnAt + 1] = t + RESPAWN_T end
		end
	end
	if sense then dwHeard, dwChat = nil, {} end
	dwPublishHitpoints()
	if math.floor(t * 2) ~= math.floor((t - dt) * 2) then dwVillagersTick() end
	if t - dwMaskT > 0.25 then                                     -- players pass through the spiders' layer
		dwMaskT = t
		for _, p in ipairs(GetAllPlayers()) do
			local m = GetPlayerParam("CollisionMask", p)
			if type(m) == "number" and math.floor(m / DW_LAYER) % 2 == 1 then SetPlayerParam("CollisionMask", m - DW_LAYER, p) end
		end
	end
	if t - dwPubT >= 1 / DW_PUBLISH_HZ then
		dwPubT = t
		dwPublish()
	end
end

function Spider.serverUpdate(dt)
	for _, s in ipairs(dwList) do spUpdate(s, dt) end
end
