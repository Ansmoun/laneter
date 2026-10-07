-- Laneter — cliente de terminal.

local Server   = require("lib.server")
local Window   = require("lib.window")
local theme    = require("lib.theme")
local cairo    = require("lib.cairo")
local log      = require("lib.log")
local Terminal = require("lib.terminal.widget")

local shell = arg and arg[1] or os.getenv("SHELL") or "/bin/sh"
log.info("laneter", "shell=%s", shell)

local srv = Server.new({ exit_on_empty = false })
local T = theme.load()

local term = Terminal.new {
    shell = shell,
    theme = T,
    font  = "DejaVu Sans Mono 11",
}

-- El buffer de la Window NO se limpia solo. Si no pintamos el
-- fondo completo en on_draw, quedan restos de frames previos o
-- de otras ventanas que se solaparon durante el mapeo (bug
-- observado con lane-bar sobre laneter). El color de fondo es el
-- mismo que usa el Terminal, para que no haya diferencia visible
-- entre el fondo del widget y el fondo de la Window.
local function bg_color()
    local c = term.default_bg
    return c[1]/255, c[2]/255, c[3]/255
end

local win
win = Window.new(srv, {
    kind = "normal",
    width = 900, height = 560,
    x = "center", y = "center",
    title = "Laneter",
    disable_q_close = true,
    on_draw = function(cr, cw, ch)
        local r, g, b = bg_color()
        cairo.set_rgb(cr, r, g, b)
        cairo.rectangle(cr, 0, 0, cw, ch)
        cairo.fill(cr)
    end,
    on_key = function(key)
        if term:on_key(key) then return end
        if key.pressed and key.name == "Escape"
           and not key.mods.ctrl
           and not key.mods.alt
           and not key.mods.super then
            win:close("escape")
        end
    end,
    on_close = function()
        term:destroy()
        srv:stop()
    end,
})

log.info("laneter", "Window creada, set_root")
win:set_root(term)
log.info("laneter", "set_root OK")

srv:run()
log.info("laneter", "adios")
