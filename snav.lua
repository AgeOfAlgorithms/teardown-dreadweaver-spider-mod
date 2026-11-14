-- snav.lua: SNav, the Dreadweaver's navigation over surfaces (server). Contract: spider/PROJECT.md "SNav".
-- Included by main.lua (no #version line here). One global: SNav. Everything else is file-local.
--
-- The spider walks on anything: floors, walls, ceilings, the outside of a roof. So the walkable space is the thin
-- shell of air that hugs static geometry. A lazy, sparse grid of CELL m cells: a cell is walkable when its centre is
-- at least CLEAR m from static geometry and has a surface within REACH m - one QueryClosestPoint, cached with the
-- point the spider would ride at (RIDE m off that surface) and the surface normal there. REACH is more than half a
-- cell's diagonal across a face, so the shell is connected round convex edges (the top of a wall to its side).
--
-- A* (26 neighbours, weighted) runs across frames on a per-frame query budget and a cap on expansions (Lua time).
-- Edges are checked lazily: when a node is popped, a thin ray from its parent's centre to its own (two cells on
-- either side of a thin wall are both walkable and adjacent; the ray says no). A failed edge is banned and the node
-- gets its best other closed neighbour as parent, or waits to be reached another way.
-- No string-pulling: a shortcut would leave the surface. The brain steers at a point a little ahead on the path.

SNav = {}

local CELL, REACH, CLEAR, RIDE, BUDGET, MAXN, MASK, WEIGHT, EXPAND, MAXCELLS, LEAF
local cells, cellN            -- key -> false | {x, y, z, nx, ny, nz, d} (ride point, normal, distance to the surface)
local edges                   -- edges[a][b] = true (clear) | false (banned), a < b
local reqs, order             -- id -> request; ids in round-robin order
local used, usedTotal, expanded
local NB                      -- the 26 neighbours: {dx, dy, dz, cost in cells}
local SNAPS                   -- cell offsets by distance, for snapping a point to a walkable cell
local qv = {0, 0, 0}

local K1, K2, OFF = 4096, 16777216, 2048

local function key(ix, iy, iz) return (ix + OFF) * K2 + (iy + OFF) * K1 + (iz + OFF) end
local function unkey(k)
	local iz = k % K1
	local iy = (k - iz) / K1 % K1
	local ix = (k - iz - iy * K1) / K2
	return ix - OFF, iy - OFF, iz - OFF
end
local function cellOf(x, y, z) return math.floor(x / CELL), math.floor(y / CELL), math.floor(z / CELL) end
local function centre(ix, iy, iz) return (ix + 0.5) * CELL, (iy + 0.5) * CELL, (iz + 0.5) * CELL end

local function filter()
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
end

-- test cell k: one query the first time; returns its cached value
local function test(k, ix, iy, iz)
	local v = cells[k]
	if v ~= nil then return v end
	used = used + 1
	local cx, cy, cz = centre(ix, iy, iz)
	qv[1], qv[2], qv[3] = cx, cy, cz
	filter()
	local hit, p, _, shape = QueryClosestPoint(qv, REACH)
	v = false
	if hit then
		local dx, dy, dz = cx - p[1], cy - p[2], cz - p[3]
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d >= CLEAR then
			local nx, ny, nz = dx / d, dy / d, dz / d
			-- (leaves and twigs: walkable, but dear - a way through a tree's crown only when there is no other)
			local leaf = 1
			if shape and shape ~= 0 and GetShapeMaterialAtPosition then
				qv[1], qv[2], qv[3] = p[1] - nx * 0.05, p[2] - ny * 0.05, p[3] - nz * 0.05
				if GetShapeMaterialAtPosition(shape, qv) == "foliage" then leaf = LEAF end
			end
			v = {p[1] + nx * RIDE, p[2] + ny * RIDE, p[3] + nz * RIDE, nx, ny, nz, d, leaf}
		end
	end
	if cellN >= MAXCELLS then cells, cellN, edges = {}, 0, {} end   -- (a huge map: start over rather than grow for ever)
	cells[k] = v
	cellN = cellN + 1
	return v
end

-- is the step a -> b (neighbouring cells) open? One thin ray between the centres the first time. nil = cached state
local function edgeState(a, b)
	if a > b then a, b = b, a end
	local e = edges[a]
	return e and e[b]
end
local function edgeSet(a, b, ok)
	if a > b then a, b = b, a end
	local e = edges[a]
	if not e then e = {}; edges[a] = e end
	e[b] = ok
end
local dv = {0, 0, 0}
local function edgeOk(a, b)
	local s = edgeState(a, b)
	if s ~= nil then return s end
	local ax, ay, az = centre(unkey(a))
	local bx, by, bz = centre(unkey(b))
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	qv[1], qv[2], qv[3] = ax, ay, az
	dv[1], dv[2], dv[3] = dx / l, dy / l, dz / l
	used = used + 1
	filter()
	local hit = QueryRaycast(qv, dv, l, 0.05)
	edgeSet(a, b, not hit)
	return not hit
end

----- the open list: a binary heap of (f, key) -----

local function hpush(q, f, k)
	local hf, hk = q.hf, q.hk
	local i = #hf + 1
	while i > 1 do
		local p = math.floor(i / 2)
		if hf[p] <= f then break end
		hf[i], hk[i] = hf[p], hk[p]
		i = p
	end
	hf[i], hk[i] = f, k
end

local function hpop(q)
	local hf, hk = q.hf, q.hk
	local n = #hf
	if n == 0 then return nil end
	local topF, topK = hf[1], hk[1]
	local f, k = hf[n], hk[n]
	hf[n], hk[n] = nil, nil
	n = n - 1
	if n > 0 then
		local i = 1
		while true do
			local c = i * 2
			if c > n then break end
			if c < n and hf[c + 1] < hf[c] then c = c + 1 end
			if hf[c] >= f then break end
			hf[i], hk[i] = hf[c], hk[c]
			i = c
		end
		hf[i], hk[i] = f, k
	end
	return topK, topF
end

----- a request -----

local function heur(q, ix, iy, iz)
	local dx, dy, dz = ix - q.gx, iy - q.gy, iz - q.gz
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function finish(q, reached, e)
	local pts, len = {}, 0
	local k = e
	local guard = 0
	while k and guard < 20000 do
		local v = cells[k]
		if v then table.insert(pts, 1, {v[1], v[2], v[3], v[4], v[5], v[6]}) end
		k = q.par[k]
		guard = guard + 1
	end
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		len = len + math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
	end
	q.result = {ok = reached, partial = not reached, points = pts, len = len, nodes = q.nodes, queries = q.queries,
		ticks = q.ticks, gap = q.bestH and q.bestH * CELL or 0}
	q.stage = "done"
	q.hf, q.hk, q.g, q.par, q.closed = nil, nil, nil, nil, nil
end

-- snap a point to the walkable cell nearest to it within SNAPS (pauses on budget): "wait", a key, or false
local function snap(q, x, y, z, slot)
	local s = q[slot]
	if not s then
		local ix, iy, iz = cellOf(x, y, z)
		s = {i = 1, ix = ix, iy = iy, iz = iz, best = nil, bestD = 1e9, stop = 1e9}
		q[slot] = s
	end
	while s.i <= #SNAPS do
		local o = SNAPS[s.i]
		if o[4] > s.stop then break end
		if used >= BUDGET then return "wait" end
		local ix, iy, iz = s.ix + o[1], s.iy + o[2], s.iz + o[3]
		local k = key(ix, iy, iz)
		local v = test(k, ix, iy, iz)
		if v then
			local d = (v[1] - x) ^ 2 + (v[2] - y) ^ 2 + (v[3] - z) ^ 2
			if d < s.bestD then s.best, s.bestD = k, d end
			if s.stop > 1e8 then s.stop = o[4] + 1.01 end          -- (found one: finish this shell and the next)
		end
		s.i = s.i + 1
	end
	return s.best or false
end

local function step(q)
	if q.stage == "snap" then
		local a = snap(q, q.from[1], q.from[2], q.from[3], "snapA")
		if a == "wait" then return end
		local b = snap(q, q.to[1], q.to[2], q.to[3], "snapB")
		if b == "wait" then return end
		if not a or not b then
			q.result = {ok = false, partial = true, points = {}, len = 0, nodes = 0, queries = q.queries, ticks = q.ticks,
				nostart = not a, nogoal = not b}
			q.stage = "done"
			return
		end
		q.sk, q.gk = a, b
		q.gx, q.gy, q.gz = unkey(b)
		q.hf, q.hk, q.g, q.par, q.closed = {}, {}, {[a] = 0}, {}, {}
		q.nodes = 0
		q.best, q.bestH = a, heur(q, unkey(a))
		hpush(q, WEIGHT * q.bestH, a)
		q.stage = "astar"
		return
	end
	if q.stage ~= "astar" then return end
	local g, par, closed = q.g, q.par, q.closed
	while used < BUDGET and expanded < EXPAND do
		local k = hpop(q)
		if not k then return finish(q, false, q.best) end
		if not closed[k] and g[k] then
			local p = par[k]
			local fine = true
			if p and not edgeOk(p, k) then
				-- the step from its parent is walled off: the best other closed neighbour, or wait for another way in
				fine = false
				g[k], par[k] = nil, nil
				local ix, iy, iz = unkey(k)
				local bg, bn = 1e18, nil
				for i = 1, 26 do
					local o = NB[i]
					local n = key(ix + o[1], iy + o[2], iz + o[3])
					if closed[n] and edgeState(n, k) ~= false then
						local ng = g[n] + o[4]
						if ng < bg then bg, bn = ng, n end
					end
				end
				if bn then
					g[k], par[k] = bg, bn
					hpush(q, bg + WEIGHT * heur(q, ix, iy, iz), k)
				end
			end
			if fine then
				closed[k] = true
				q.nodes = q.nodes + 1
				expanded = expanded + 1
				local ix, iy, iz = unkey(k)
				local h = heur(q, ix, iy, iz)
				if h < q.bestH then q.best, q.bestH = k, h end
				if k == q.gk then return finish(q, true, k) end
				if q.nodes >= MAXN then return finish(q, false, q.best) end
				local gk = g[k]
				local vk = cells[k]
				for i = 1, 26 do
					local o = NB[i]
					local jx, jy, jz = ix + o[1], iy + o[2], iz + o[3]
					local n = key(jx, jy, jz)
					if not closed[n] then
						local v = test(n, jx, jy, jz)
						if v and edgeState(k, n) ~= false then
							-- (cells at the riding height are the cheapest: it keeps to the surface's skin)
							local ng = gk + o[4] * (1 + 0.5 * math.abs(v[7] - RIDE)) * v[8]
							local og = g[n]
							if not og or ng < og - 1e-6 then
								g[n], par[n] = ng, k
								hpush(q, ng + WEIGHT * heur(q, jx, jy, jz), n)
							end
						end
					end
				end
			end
		end
	end
end

----- API -----

function SNav.init(opts)
	opts = opts or {}
	CELL = opts.cell or 0.5
	REACH = opts.reach or 0.9
	CLEAR = opts.clear or 0.2
	RIDE = opts.ride or 0.45
	BUDGET = opts.budget or 400
	MAXN = opts.maxNodes or 3000
	MASK = opts.mask or 63
	WEIGHT = opts.weight or 1.5
	EXPAND = opts.expand or 30
	MAXCELLS = opts.maxCells or 150000
	LEAF = opts.leaf or 4                 -- cost factor of a cell on foliage
	cells, cellN, edges = {}, 0, {}
	reqs, order = {}, {}
	used, usedTotal, expanded = 0, 0, 0
	NB = {}
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		if dx ~= 0 or dy ~= 0 or dz ~= 0 then NB[#NB + 1] = {dx, dy, dz, math.sqrt(dx * dx + dy * dy + dz * dz)} end
	end end end
	SNAPS = {}
	local R = opts.snap or 3
	for dx = -R, R do for dy = -R, R do for dz = -R, R do
		SNAPS[#SNAPS + 1] = {dx, dy, dz, math.sqrt(dx * dx + dy * dy + dz * dz)}
	end end end
	table.sort(SNAPS, function(a, b) return a[4] < b[4] end)
end

function SNav.tick()
	used, expanded = 0, 0
	local n = #order
	if n == 0 then return end
	-- round robin: the request that went first last frame goes last now
	table.insert(order, table.remove(order, 1))
	for _, id in ipairs(order) do
		local q = reqs[id]
		if q and q.stage ~= "done" then
			local u0 = used
			q.ticks = q.ticks + 1
			step(q)
			q.queries = q.queries + used - u0
		end
		if used >= BUDGET or expanded >= EXPAND then break end
	end
	usedTotal = usedTotal + used
end

function SNav.request(id, from, to)
	if not reqs[id] then order[#order + 1] = id end
	reqs[id] = {id = id, from = {from[1], from[2], from[3]}, to = {to[1], to[2], to[3]}, stage = "snap", ticks = 0,
		queries = 0, nodes = 0}
end

function SNav.result(id)
	local q = reqs[id]
	return q and q.result or nil
end

function SNav.cancel(id)
	if not reqs[id] then return end
	reqs[id] = nil
	for i, o in ipairs(order) do if o == id then table.remove(order, i); break end end
end

-- the cells within r of p are tested again when next needed (something broke there)
function SNav.forget(p, r)
	local n = math.ceil(r / CELL)
	local ix, iy, iz = cellOf(p[1], p[2], p[3])
	for dx = -n, n do for dy = -n, n do for dz = -n, n do
		local k = key(ix + dx, iy + dy, iz + dz)
		if cells[k] ~= nil then cells[k] = nil; cellN = cellN - 1 end
	end end end
	edges = {}                                                    -- (cheap to check again; no stale walls or openings)
end

-- the walkable cell's ride point and normal at p, if its cell is walkable (cached or one query): {x, y, z, nx, ny, nz}
function SNav.at(p)
	local ix, iy, iz = cellOf(p[1], p[2], p[3])
	local v = test(key(ix, iy, iz), ix, iy, iz)
	return v or nil
end

function SNav.stats()
	return {queries = usedTotal, cells = cellN, last = used}
end
