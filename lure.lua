-- Lure: the Dreadweaver talks (server). While it stalks, out of its prey's sight, it says short human sentences
-- through Proximity Comms to draw players to it: each spider is one of the chat's agents with only scripted lines
-- (proxchat.agent.<id>.say - no language model is asked, .hears = none), so its words show as a speech bubble where
-- it sits and in the chat, heard by whoever is in range, under a plain human name. Without Proximity Comms running
-- on the host nothing happens. It never speaks while it hunts: then it has its own voice (spiderview.lua).

Lure = {}

LURE_NAMES = {"Sam", "Alex", "Jo", "Max", "Robin", "Chris", "Pat", "Lee", "Kim", "Nico"}
LURE_VOICES = {"Plain", "Low", "Chirpy", "Deep"}
-- the sentences: a call, then what it wants; some are said alone, some doubled (it does not quite have speech down)
LURE_CALLS = {"Hello?", "Hey.", "Hey!", "Help.", "Please.", "Psst.", "Wait.", "Is someone there?", "Anyone?"}
LURE_WANTS = {"I'm hurt.", "I can't move.", "Come here.", "Come closer.", "I found something.", "Don't leave me.",
	"It's safe here.", "I need help.", "Can you hear me?", "I'm stuck.", "Over here.", "Follow my voice.",
	"I'm so cold.", "Help me up.", "Look what I found.", "This way.", "Where are you going?", "I can see you."}
LURE_CLOSE = {"Behind you.", "Up here.", "Don't turn around.", "Shh.", "Closer.", "I can see you.", "Stay still."}
LURE_FAR = {"HELP!", "OVER HERE!", "HELLO?", "IS ANYONE THERE?", "PLEASE! HELP ME!"}

local function now() return GetTime() end
local function rnd(a, b) return a + math.random() * (b - a) end
local function one(l) return l[math.random(#l)] end

local function chatOn()
	return GetInt("proxchat.version") >= 17 and math.abs(GetTime() - GetFloat("proxchat.alive")) <= 2
end

function lureLine(p, d)
	if d < 7 then return one(LURE_CLOSE), "whisper" end
	if d > 24 then return one(LURE_FAR), "yell" end
	local r = math.random()
	local line
	if r < 0.12 then
		local name = GetPlayerName(p)
		if type(name) == "string" and #name > 0 and #name < 24 then line = name .. "? " .. one(LURE_WANTS) end
	end
	if not line then
		if r < 0.55 then line = one(LURE_CALLS) .. " " .. one(LURE_WANTS)
		elseif r < 0.8 then line = one(LURE_WANTS)
		else
			local w = one({"Help.", "Please.", "Come here.", "Hello?"})
			line = w .. " " .. w .. " " .. one(LURE_WANTS)                 -- (the same word twice: not quite human)
		end
	end
	return line, "speak"
end

local function put(k, v) if GetString(k) ~= v then SetString(k, v) end end

local function agentKey(s) return "proxchat.agent.dreadweaver" .. s.id end

local function place(s)
	local p = VecAdd(s.pos, VecScale(s.up, 0.3))
	put(agentKey(s) .. ".at", string.format("%.1f,%.1f,%.1f", p[1], p[2], p[3]))
end

function Lure.serverInit()
	lureT = 0
	lureA = {}                                                       -- spider id -> {name, voice, next, say, sayAt, showTill}
	local ok, ids = pcall(ListKeys, "proxchat.agent")                -- (ours from a run before)
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		if id:sub(1, 11) == "dreadweaver" then ClearKey("proxchat.agent." .. id) end
	end
end

function Lure.serverTick(dt)
	local t = now()
	if t - lureT < 0.25 then return end
	lureT = t
	if not chatOn() then return end
	local seen = {}
	for _, s in ipairs(dwList or {}) do
		local a = lureA[s.id]
		if s.alive then
			seen[s.id] = true
			if not a then
				a = {name = one(LURE_NAMES), voice = one(LURE_VOICES), next = t + rnd(12, 30), showTill = 0}
				lureA[s.id] = a
			end
			local k = agentKey(s)
			-- (the chat clears proxchat.* when it starts: keep the definition there)
			put(k .. ".persona", "A creature that only ever says the scripted lines its mod gives it.")
			put(k .. ".name", a.name)
			put(k .. ".hears", "none")
			put(k .. ".voice", a.voice)
			if GetString(k .. ".at") == "" then place(s) end
			if a.say and t >= a.sayAt then                               -- (its place and range went first)
				if s.state ~= "hunt" then SetString(k .. ".say", a.say) end   -- (the hunt began meanwhile: it does not talk)
				a.say = nil
			end
			if t < a.showTill then place(s) end                             -- (the bubble stays over it while it shows)
			local quiet = (s.state == "stalk" or (s.state == "roam" and s.far < 35)) and not s.air and not s.act
			if quiet and t > a.next and not a.say then
				-- the nearest living player it is not being watched by
				local best, bd = 0, 40
				for _, p in ipairs(GetAllPlayers()) do
					if GetPlayerHealth(p) > 0 then
						local d = VecLength(VecSub(dwChest(p), s.pos))
						if d > 3.5 and d < bd then best, bd = p, d end
					end
				end
				if best ~= 0 then
					local eye = GetPlayerEyeTransform(best)
					local to = VecNormalize(VecSub(s.pos, eye.pos))
					local facing = VecDot(to, TransformToParentVec(eye, Vec(0, 0, -1))) > 0.6
					if not (facing and dwSee(eye.pos, VecAdd(s.pos, VecScale(s.n, 0.2)))) then
						local line, mode = lureLine(best, bd)
						place(s)
						put(k .. ".mode", mode)
						a.say, a.sayAt = line, t + 0.6
						a.showTill = t + 9
						a.next = t + rnd(22, 55)
						s.lures = (s.lures or 0) + 1
						s.lastLure = line
					else
						a.next = t + rnd(3, 8)                                  -- (watched: later)
					end
				else
					a.next = t + rnd(5, 10)
				end
			end
		elseif a then
			ClearKey(agentKey(s))                                         -- (dead: the chat drops it)
			lureA[s.id] = nil
		end
	end
	for id in pairs(lureA) do
		if not seen[id] then
			ClearKey("proxchat.agent.dreadweaver" .. id)
			lureA[id] = nil
		end
	end
end
