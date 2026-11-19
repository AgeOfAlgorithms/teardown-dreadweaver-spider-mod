-- Dreadweaver options (Mod Manager): how many Dreadweavers hunt on a map.

function draw()
	local n = GetInt("savegame.mod.count")
	if n < 1 then n = 1 end
	local auto = not GetBool("savegame.mod.autooff")
	UiTranslate(UiCenter(), 260)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiText("Dreadweaver")
	UiTranslate(0, 80)
	UiFont("regular.ttf", 28)
	UiText("Spawn on its own when a map loads")
	UiTranslate(0, 55)
	UiFont("bold.ttf", 36)
	UiPush()
	for i, on in ipairs({true, false}) do
		UiPush()
		UiTranslate((i - 1.5) * 150, 0)
		if on == auto then UiColor(1, 0.4, 0.3) else UiColor(0.8, 0.8, 0.8) end
		if UiTextButton(on and "On" or "Off", 120, 56) then SetBool("savegame.mod.autooff", not on) end
		UiPop()
	end
	UiPop()
	UiTranslate(0, 75)
	UiFont("regular.ttf", 28)
	if auto then UiColor(1, 1, 1) else UiColor(0.5, 0.5, 0.5) end
	UiText("Dreadweavers on each map")
	UiTranslate(0, 60)
	UiFont("bold.ttf", 40)
	UiPush()
	for i = 1, 3 do
		UiPush()
		UiTranslate((i - 2) * 110, 0)
		if not auto then UiColor(0.4, 0.4, 0.4) elseif i == n then UiColor(1, 0.4, 0.3) else UiColor(0.8, 0.8, 0.8) end
		if UiTextButton(tostring(i), 80, 60) then SetInt("savegame.mod.count", i) end
		UiPop()
	end
	UiPop()
	UiTranslate(0, 90)
	UiFont("regular.ttf", 28)
	UiColor(1, 1, 1)
	UiText("Gold a killed one drops (McPuppet Inventory System)")
	UiTranslate(0, 60)
	UiFont("bold.ttf", 36)
	local g = GetInt("savegame.mod.gold")
	local cur = g > 0 and g - 1 or 200
	for i, amt in ipairs({0, 100, 200, 400}) do
		UiPush()
		UiTranslate((i - 2.5) * 130, 0)
		if amt == cur then UiColor(1, 0.4, 0.3) else UiColor(0.8, 0.8, 0.8) end
		if UiTextButton(tostring(amt), 110, 56) then SetInt("savegame.mod.gold", amt + 1) end
		UiPop()
	end
	UiTranslate(0, 70)
	UiFont("regular.ttf", 22)
	UiColor(0.8, 0.8, 0.8)
	UiText("Placed from the spawn menu (Creatures > Dreadweaver), up to 6.")
	UiTranslate(0, 100)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
