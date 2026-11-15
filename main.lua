#version 2
-- Dreadweaver: a global enemy mod (PROJECT.md). The modules are global tables of callbacks: SNav (navigation over
-- surfaces), Webs (its silk: patches, shots, lines), Spider (the brains, server), Lure (its spoken lines through
-- Proximity Comms), SpiderView (drawing and sound, every machine). SPIDER_PARTS / SPIDER_SOUNDS are generated.

#include "spiderparts.lua"
#include "spidersounds.lua"
#include "snav.lua"
#include "prey.lua"
#include "webs.lua"
#include "spider.lua"
#include "lure.lua"
#include "spiderview.lua"

-- (test builds add their modules here)

function server.init()
	math.randomseed(GetInt("savegame.mod.seed") + 1)
	SetInt("savegame.mod.seed", (GetInt("savegame.mod.seed") + 7919) % 100000)
	Webs.serverInit()
	Spider.serverInit()
	Lure.serverInit()
	if DW_TEST then DW_TEST.serverInit() end
end

function server.tick(dt)
	Spider.serverTick(dt)
	Webs.serverTick(dt)
	Lure.serverTick(dt)
	if DW_TEST then DW_TEST.serverTick(dt) end
end

function server.update(dt)
	Spider.serverUpdate(dt)
	Webs.serverUpdate(dt)
	if DW_TEST then DW_TEST.serverUpdate(dt) end
end

function client.init()
	Webs.clientInit()
	SpiderView.clientInit()
	if DW_TEST then DW_TEST.clientInit() end
end

function client.tick(dt)
	SpiderView.clientTick(dt)
	Webs.clientTick(dt)
	if DW_TEST then DW_TEST.clientTick(dt) end
end

function client.draw()
	Webs.clientDraw()
	SpiderView.clientDraw()
	if DW_TEST then DW_TEST.clientDraw() end
end
