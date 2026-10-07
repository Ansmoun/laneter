-- Laneter — cliente de terminal.

local Server   = require("lib.server")
local Window   = require("lib.window")
local theme    = require("lib.theme")
local cairo    = require("lib.cairo")
local log      = require("lib.log")
local Tabbed   = require("lib.tabbed")

local shell = arg and arg[1] or nil
log.info("laneter", "shell CLI=%s", tostring(shell))

local srv = Server.new({ exit_on_empty = false })
local T = theme.load()

-- shell = nil -> el Terminal usa config.shell o $SHELL.
-- font  = nil -> el Terminal compone "family size" desde config.
-- Antes pasaramos un font fijo "DejaVu Sans Mono 11" que pisaba
-- las preferencias guardadas. Ahora solo respetamos el argumento
-- de CLI si el usuario lo paso explicitamente.
local cli_shell = (arg and arg[1]) or nil
local app = Tabbed.new(srv, T, {
    shell = cli_shell,
})

-- El fondo de la Window es el mismo del terminal. Sin esto, en
-- el momento del mapeo la Window muestra basura del buffer (se
-- ve como restos de otras ventanas superpuestas).
local function bg_color()
    local t = app:active_term()
    local c = (t and t.default_bg) or { 20, 20, 24 }
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
        if app:on_key(key) then return end
        -- Sin fallback de Escape: se usa dentro del shell (vim,
        -- etc). Para cerrar la ventana: mod+shift+q del WM, o
        -- Archivo -> Cerrar ventana.
    end,
    on_close = function()
        app:destroy()
        srv:stop()
    end,
})

log.info("laneter", "Window creada, set_root")
win:set_root(app.widget)
log.info("laneter", "set_root OK")

srv:run()
log.info("laneter", "adios")
