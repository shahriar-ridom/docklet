-- =============================================================================
-- hyprsess snippets for Hyprland 0.56 (Lua config). Nothing here is applied
-- automatically — copy what you want into ~/.config/hypr/config/*.lua.
-- =============================================================================

-- --- binds.lua ---------------------------------------------------------------
-- Save now / restore last autosave.
-- (SUPER+SHIFT+S/R and SUPER+CTRL+S are already used in your binds.lua.)
hl.bind(Mod .. " + CTRL + ALT + S", hl.dsp.exec_cmd("hyprsess save && hyprctl notify 5 2000 0 'session saved'"))
hl.bind(Mod .. " + CTRL + R", hl.dsp.exec_cmd("hyprsess restore autosave"))

-- Save-then-exit. Use these instead of a raw exit/poweroff so the last state
-- is always captured (the most reliable "save on logout" on Hyprland).
hl.bind(Mod .. " + SHIFT + Escape", hl.dsp.exec_cmd("hyprsess-power logout"))

-- --- startup.lua (OPT-IN: restore the last autosave on login) ----------------
-- Put inside your existing hl.on("hyprland.start", function() ... end) block,
-- AFTER noctalia. The sleep lets the shell/portals come up first.
--
-- hl.exec_cmd("sleep 3 && hyprsess restore autosave")

-- =============================================================================
-- Sidebar (Quickshell)
-- =============================================================================

-- --- startup.lua: launch the sidebar (inside hl.on("hyprland.start", ...)) ----
-- hl.exec_cmd("qs -c sessionbar")

-- --- rules.lua: blur behind the translucent panel -----------------------------
hl.layer_rule({
	name = "sessionbar",
	match = { namespace = "^sessionbar$" },
	blur = true,
	ignore_alpha = 0.2,   -- don't blur the fully transparent parts of the surface
})
