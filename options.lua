-- Dreadweaver options (Mod Manager): how many Dreadweavers hunt on a map.

function draw()
	local n = GetInt("savegame.mod.count")
	if n < 1 then n = 1 end
	UiTranslate(UiCenter(), 300)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiText("Dreadweaver")
	UiTranslate(0, 90)
	UiFont("regular.ttf", 28)
	UiText("Dreadweavers on each map")
	UiTranslate(0, 60)
	UiFont("bold.ttf", 40)
	UiPush()
	for i = 1, 3 do
		UiPush()
		UiTranslate((i - 2) * 110, 0)
		if i == n then UiColor(1, 0.4, 0.3) else UiColor(0.8, 0.8, 0.8) end
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
	UiText("More can be placed from the spawn menu (up to 6).")
	UiTranslate(0, 100)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
