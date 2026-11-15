-- prey.lua: Prey, what the Dreadweaver hunts (server): the players, and - when the Villagers mod runs (its plain host
-- registry keys, villagers/mods/villagers/API.md) - the villagers, treated exactly like players: same senses, same
-- target choice, same attacks, same webs. A prey id is a player's number or the string "v:<villager id>".
-- Included by main.lua (no #version line). One global: Prey. The villagers' keys are refreshed by the Villagers mod
-- twice a second; positions here are read once per frame and velocities worked out from their changes.

Prey = {}

local cache, list, lastT = {}, {}, -1
local vcache, vlist, vT = {}, {}, -100      -- the villagers' part: read ten times a second at most
local vstate = {}                 -- "v:<id>" -> {feet, t, vel, face}
local hurtN = 0

local function flat(v) return math.sqrt(v[1] * v[1] + v[3] * v[3]) end

-- the players move between frames: call once at the start of each server callback
function Prey.dirty() lastT = -1 end

function Prey.refresh()
	local t = GetTime()
	if t == lastT then return end
	lastT = t
	cache, list = {}, {}
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerHealth(p) > 0 then
			local feet = GetPlayerTransform(p).pos
			cache[p] = {id = p, feet = feet, chest = VecAdd(feet, Vec(0, 1.1, 0))}
			list[#list + 1] = p
		end
	end
	if not GetBool("villagers.present") then vcache, vlist, vT = {}, {}, -100; return end
	if t - vT < 0.1 and t >= vT then
		for _, k in ipairs(vlist) do cache[k] = vcache[k]; list[#list + 1] = k end
		return
	end
	vT = t
	vcache, vlist = {}, {}
	for id in string.gmatch(GetString("villagers.list"), "[^,]+") do
		local b = "villagers.v." .. id .. "."
		if GetBool(b .. "alive") and not GetBool(b .. "carried") and GetFloat(b .. "hp") > 0 then
			local key = "v:" .. id
			local feet = Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z"))
			local st = vstate[key]
			if not st then
				st = {feet = feet, t = t, vel = Vec(0, 0, 0), face = Vec(0, 0, -1)}
				vstate[key] = st
			elseif VecLength(VecSub(feet, st.feet)) > 0.02 then
				local dt = math.max(0.1, t - st.t)
				local v = VecScale(VecSub(feet, st.feet), 1 / dt)
				if VecLength(v) > 12 then v = Vec(0, 0, 0) end         -- (a teleport, not a run)
				st.vel, st.feet, st.t = v, feet, t
				local h = flat(v)
				if h > 0.3 then st.face = Vec(v[1] / h, 0, v[3] / h) end
			elseif t - st.t > 1.2 then
				st.vel = Vec(0, 0, 0)
			end
			local e = {id = key, vid = id, feet = feet, chest = VecAdd(feet, Vec(0, 1.1, 0)), vel = st.vel, face = st.face,
				noise = GetFloat(b .. "noise"), hp = GetFloat(b .. "hp")}
			cache[key], vcache[key] = e, e
			list[#list + 1] = key
			vlist[#vlist + 1] = key
		end
	end
end

function Prey.isPlayer(p) return type(p) == "number" end

-- every living prey, players first
function Prey.all() Prey.refresh(); return list end

function Prey.ok(p) Prey.refresh(); return cache[p] ~= nil end

function Prey.feet(p)
	Prey.refresh()
	local c = cache[p]
	return c and c.feet or Vec(0, 0, 0)
end

function Prey.chest(p)
	Prey.refresh()
	local c = cache[p]
	return c and c.chest or Vec(0, 0, 0)
end

function Prey.vel(p)
	Prey.refresh()
	local c = cache[p]
	if not c then return Vec(0, 0, 0) end
	if c.vel then return c.vel end
	return GetPlayerVelocity(p)
end

-- where its eyes are and which way they look (a villager looks the way they walk)
function Prey.eye(p)
	Prey.refresh()
	local c = cache[p]
	if c and c.vid then
		local e = VecAdd(c.feet, Vec(0, 1.6, 0))
		return Transform(e, QuatLookAt(e, VecAdd(e, c.face)))
	end
	return GetPlayerEyeTransform(p)
end

function Prey.light(p)
	if not Prey.isPlayer(p) then return false end
	local fl = GetFlashlight(p)
	return fl ~= 0 and IsLightActive(fl)
end

-- how loud they are, 0..1 (villagers only: the players' sounds reach it through GetLastSound)
function Prey.noise(p)
	local c = cache[p]
	return c and c.vid and c.noise or 0
end

function Prey.inVehicle(p)
	if not Prey.isPlayer(p) then return false end
	return GetPlayerVehicle(p) ~= 0
end

-- a bite of `frac` of their health (a player's health is 0..1, a villager's 100 points): true when it killed
function Prey.hurt(p, frac, from)
	Prey.refresh()
	local c = cache[p]
	if not c then return true end
	if c.vid then
		hurtN = GetInt("villagers.hurt.last") + 1
		local k = "villagers.hurt." .. (hurtN % 16) .. "."
		SetString(k .. "target", c.vid)
		SetFloat(k .. "amount", frac * 100)
		SetString(k .. "by", "a giant spider")
		SetFloat(k .. "x", from[1]); SetFloat(k .. "y", from[2]); SetFloat(k .. "z", from[3])
		SetFloat(k .. "knock", 4)
		SetInt("villagers.hurt.last", hurtN)
		c.hp = c.hp - frac * 100
		return c.hp <= 0
	end
	local h = math.max(0, GetPlayerHealth(p) - frac)
	SetPlayerHealth(h, p)
	local push = VecSub(c.chest, from)
	push[2] = 0
	local l = VecLength(push)
	push = l > 0.01 and VecScale(push, 1 / l) or Vec(0, 0, 0)
	SetPlayerVelocity(VecAdd(GetPlayerVelocity(p), VecAdd(VecScale(push, 3.5), Vec(0, 1.5, 0))), p)
	return h <= 0
end

-- the web holds a villager: their walking speed factor for a moment (the Villagers mod's villagers.slow keys)
function Prey.slow(p, walk)
	local c = cache[p]
	if not (c and c.vid) then return end
	local k = "villagers.slow." .. c.vid .. "."
	SetFloat(k .. "factor", math.max(0.05, math.min(1, walk / 7)))
	SetFloat(k .. "until", GetTime() + 0.6)
end
