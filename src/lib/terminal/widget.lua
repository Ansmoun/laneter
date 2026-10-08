-- widget.lua: widget Area que integra PTY + vterm + render.
--
-- Bloque A + copy/paste:
--   - Cursor parpadeante (500 ms).
--   - Ctrl +/-/0 -> tamaño de fuente.
--   - Seleccion con mouse (drag).
--   - Ctrl+Shift+C / Ctrl+Insert -> copiar CLIPBOARD.
--   - Ctrl+Shift+V / Shift+Insert -> pegar CLIPBOARD.
--   - Boton del medio -> pegar PRIMARY (X11).
--   - Copy-on-select -> PRIMARY (convencion xterm).
--
-- NO se toca Ctrl+C: sigue siendo SIGINT al shell.

local Area   = require("lib.area")
local cairo  = require("lib.cairo")
local log    = require("lib.log")
local pty    = require("lib.terminal.pty")
local vterm  = require("lib.terminal.vterm")
local render = require("lib.terminal.render")
local keys   = require("lib.terminal.keys")
local Sel    = require("lib.terminal.selection")
local clip   = require("lib.terminal.clipboard")
local config = require("lib.config")
local kb     = require("lib.keybindings")
local timer  = require("lib.timer")
local termcaps = require("lib.terminal.termcaps")

local M = {}

local Terminal = setmetatable({}, { __index = Area })
Terminal.__index = Terminal

local DEFAULT_FG = { 220, 220, 220 }
local DEFAULT_BG = { 20, 20, 24 }

local DEFAULT_FONT = "DejaVu Sans Mono 11"
local MIN_SIZE = 6
local MAX_SIZE = 32
local CURSOR_BLINK_MS = 500
local SCROLLBACK_LINES = 2000

local function fill_bg(cr, x, y, w, h, bg)
    cairo.set_rgb(cr, bg[1] / 255, bg[2] / 255, bg[3] / 255)
    cairo.rectangle(cr, x, y, w, h)
    cairo.fill(cr)
end

function M.new(opts)
    opts = opts or {}
    local self = setmetatable(Area.new({}), Terminal)

    self.opts = opts

    -- Preferencias: opts explicitos > config > defaults.
    -- Permite que un consumidor (tabbed) pase opts.shell, opts.font
    -- desde el mismo config, y que ademas opts.overrides (del
    -- preferences) tengan la ultima palabra cuando se aplican en
    -- caliente.
    local cfg_family = config.get("font_family") or "DejaVu Sans Mono"
    local cfg_size   = tonumber(config.get("font_size")) or 11
    local cfg_shell  = config.get("shell")   -- puede ser nil
    local cfg_sb     = tonumber(config.get("scrollback_lines")) or 2000
    local cfg_blink  = config.get("cursor_blink")
    if cfg_blink == nil then cfg_blink = true end

    -- Cuidado: "" es truthy en Lua. Un input vacio en Preferencias
    -- guarda "" como shell, y execvp("") falla con ENOENT: el
    -- hijo muere al instante, PTY devuelve POLLHUP, y el server
    -- cierra la app entera. Normalizar "" -> nil.
    local function nn(v) return (v ~= nil and v ~= "") and v or nil end
    self.shell = nn(opts.shell) or nn(cfg_shell)
        or os.getenv("SHELL") or "/bin/sh"
    self.default_font = opts.font
        or (cfg_family .. " " .. cfg_size)
    self.font = self.default_font
    self.renderer = render.new(self.font)
    self.cols = 80
    self.rows = 24

    -- Scrollback maximo desde config (puede cambiar en runtime via
    -- apply_preferences).
    SCROLLBACK_LINES = cfg_sb
    self._initial_blink = cfg_blink and true or false

    -- Scrollback: array circular de strings (una linea de texto
    -- por elemento). 'head' apunta al proximo slot a escribir,
    -- 'count' cuenta cuantas lineas hay actualmente (0..MAX).
    self.scrollback      = {}
    self.scrollback_head = 1
    self.scrollback_count = 0
    self.scrollback_max  = SCROLLBACK_LINES  -- se puede cambiar luego

    self.term = vterm.new(self.cols, self.rows)
    assert(self.term, "vterm.new fallo")

    -- Estado del mouse reporting. Lo activa/desactiva la app que
    -- corre dentro del terminal (via ESC[?1000h) y libvterm nos
    -- avisa por el callback settermprop.
    self._mouse_enabled = false
    self._mouse_mode = 0   -- flags de libvterm: 1 click, 2 drag, 4 move
    -- Default del terminfo (kmous): "sgr" o "x10". Se puede override
    -- en runtime si la app pide 1006h/l explicito (ver vterm.feed).
    self._mouse_encoding = termcaps.mouse_encoding()
    self._mouse_last_row = 0
    self._mouse_last_col = 0
    self._mods_cache = 0
    self._mods_cache_t = 0

    -- Registrar callbacks de scrollback + mouse.
    self.term:set_scrollback_callbacks {
        on_pushline = function(text, cols)
            self:_push_scrollback_line(text)
        end,
        on_clear = function()
            self.scrollback = {}
            self.scrollback_head = 1
            self.scrollback_count = 0
        end,
        on_settermprop = function(prop, value)
            if prop == self.term.PROP_MOUSE then
                self._mouse_enabled = (value ~= 0)
                self._mouse_mode = value
                log.info("terminal",
                    "mouse reporting: %s (flags 0x%x)",
                    tostring(self._mouse_enabled), value)
            end
        end,
    }

    local h, err = pty.spawn(self.shell, self.cols, self.rows)
    assert(h, err or "pty.spawn fallo")
    self.pty = h
    log.info("terminal", "PTY abierto: pid=%d fd=%d", h.pid, h.fd)
    log.info("terminal", "font: %s", self.font)

    -- Colores. Orden de precedencia: opts explicitos > config >
    -- theme de LANE > defaults hardcoded. Si config.color_mode es
    -- "theme", usar los del theme; si es "custom", usar los hex de
    -- config.text_color/bg_color/cursor_color.
    local T = opts.theme or {}
    local cfg_mode   = config.get("color_mode") or "theme"
    local cfg_fg_hex = config.get("text_color")
    local cfg_bg_hex = config.get("bg_color")
    local cfg_cur_hex = config.get("cursor_color")

    local function hex_to_rgb255(hex)
        if not hex or hex == "" then return nil end
        local G = require("lib.helpers.graphics")
        local ok, r, g, b = pcall(G.hex_to_rgba, hex)
        if not ok or r == nil then return nil end
        return { math.floor(r*255), math.floor(g*255), math.floor(b*255) }
    end

    if cfg_mode == "custom" then
        self.default_fg = opts.fg or hex_to_rgb255(cfg_fg_hex) or DEFAULT_FG
        self.default_bg = opts.bg or hex_to_rgb255(cfg_bg_hex) or DEFAULT_BG
    else
        self.default_fg = opts.fg
            or (T.fg_rgb and { T.fg_rgb[1]*255, T.fg_rgb[2]*255, T.fg_rgb[3]*255 })
            or DEFAULT_FG
        self.default_bg = opts.bg
            or (T.bg_rgb and { T.bg_rgb[1]*255, T.bg_rgb[2]*255, T.bg_rgb[3]*255 })
            or DEFAULT_BG
    end
    self._theme = T
    self.default_cursor = hex_to_rgb255(cfg_cur_hex)
        or { 230, 230, 230 }

    self.sel = Sel.new()
    self._cursor_visible = true
    self._blink_enabled = self._initial_blink
    self._dragging = false
    -- 0 = en vivo (viewport sigue al vterm). Positivo = cuantas
    -- filas hacia atras estamos mirando en el scrollback.
    self.scrollback_offset = 0

    self.min_w, self.max_w = 100, 10000
    self.min_h, self.max_h = 50, 10000
    return self
end

function Terminal:set_window(win)
    -- Idempotente: en new_tab se llama explicito Y el Stack
    -- propaga, registrando el fd dos veces. Con el guard, solo el
    -- primer llamado tiene efecto.
    if self._registered_window == win then return end
    self._registered_window = win

    if Area.set_window then Area.set_window(self, win) end
    self.window = win
    self.server = win.server
    win.server:add_fd(self.pty.fd, function() self:_on_pty_readable() end)

    if win.server.add_timer then
        self._cursor_timer = win.server:add_timer(CURSOR_BLINK_MS,
            function()
                if not self._blink_enabled then return end
                if not self.term then return end
                self._cursor_visible = not self._cursor_visible
                if self.window then self.window:damage_all() end
            end)
    end
end

-- Activa/desactiva el parpadeo. Cuando esta desactivado, el
-- cursor queda siempre visible.
function Terminal:set_blink_enabled(v)
    self._blink_enabled = v and true or false
    if not self._blink_enabled then
        self._cursor_visible = true
        if self.window then self.window:damage_all() end
    end
end

function Terminal:is_blink_enabled()
    return self._blink_enabled
end

function Terminal:_on_pty_readable()
    -- Si el terminal ya se destruyo (cerrar ventana), no hay pty
    -- ni term. Sin este guard, el fd callback dispara una vez mas
    -- durante el cierre y crashea con "attempt to index field
    -- 'pty' (a nil value)".
    if not self.pty or not self.term then return end
    -- Limitar cuanto procesamos por invocacion del callback. Con
    -- 1 GB de output (por ejemplo `seq 1 1000000` x varias veces)
    -- el while drenaria el PTY sin ceder, sin dejar correr el GC,
    -- y el heap de LuaJIT crece hasta el OOM kill. En su lugar,
    -- procesamos a lo sumo 256 KB por tick; si queda mas, el fd
    -- sigue marcado y volvemos a entrar en el proximo ciclo del
    -- server (que da tiempo al GC de correr).
    local budget = 256 * 1024
    local read_total = 0
    while read_total < budget do
        local chunk = pty.read(self.pty.fd, 4096)
        if chunk == nil then
            if self.window then self.window:close("shell exit") end
            return
        end
        if chunk == "" then break end
        self.term:feed(chunk)
        read_total = read_total + #chunk
    end
    -- GC completo despues de cada budget. Un "step" individual no
    -- alcanza: dentro de vterm_input_write el GC esta en stop, y
    -- con 64 feeds dentro del budget (256 KB / 4 KB) se acumulan
    -- decenas de miles de strings temporales. Un step por
    -- invocacion no los libera. Un collect completo tarda pocos
    -- ms cada 256 KB; a la velocidad tipica de un PTY eso es
    -- imperceptible y mantiene el heap acotado.
    collectgarbage("collect")

    -- Afuera del callback FFI: seguro tocar el scrollbar y
    -- redibujar.
    if self._scrollback_dirty then
        self._scrollback_dirty = false
        self:_sync_scrollbar()
    end
    -- La grilla del vterm pudo haber cambiado: el proximo draw
    -- tiene que re-leer las celdas.
    self.renderer:invalidate_snapshot()
    -- NO reseteamos el offset al recibir output. Convencion de
    -- gnome-terminal / kitty / alacritty: mientras el usuario
    -- mira historia, el output nuevo sigue llegando abajo pero el
    -- viewport no salta. El usuario vuelve al presente con
    -- Ctrl+End, rueda hacia abajo, o escribiendo.
    --
    -- Antes saltabamos al vivo cuando llegaba output, y eso
    -- rompia el drag de la scrollbar: llegaba un byte del `seq`,
    -- el offset volvia a 0, el SB se sincronizaba, el usuario
    -- seguia arrastrando, nueva pelea. Resultado: texto sin
    -- renderizar.
    self._cursor_visible = true
    self:damage()
    if self.window then self.window:damage_all() end
end

-- ── Scrollback ─────────────────────────────────────────────

-- IMPORTANTE: este metodo se invoca DESDE dentro del callback
-- FFI de libvterm (sb_pushline), en medio de vterm_input_write.
-- NO tocar el ScrollBar ni llamar damage desde aca: si lo
-- hacemos, self:damage() puede disparar un draw que vuelve a
-- entrar a libvterm (term:cell) mientras libvterm todavia esta
-- procesando -> "bad callback" de LuaJIT. El sync del scrollbar
-- se hace desde _on_pty_readable, afuera del callback.
function Terminal:_push_scrollback_line(text)
    self.scrollback[self.scrollback_head] = text
    self.scrollback_head = (self.scrollback_head % self.scrollback_max) + 1
    if self.scrollback_count < self.scrollback_max then
        self.scrollback_count = self.scrollback_count + 1
    end
    self._scrollback_dirty = true
    self._layout_cache = nil   -- invalidar layout
end

-- Devuelve la linea N-esima contada desde el final del scrollback.
-- idx = 1 es la mas reciente. Fuera de rango devuelve "".
function Terminal:scrollback_line(idx)
    if idx < 1 or idx > self.scrollback_count then return "" end
    -- Formula wrap 1-indexed. head apunta al proximo hueco.
    -- La linea idx mas reciente esta en (head - idx), mapeado a
    -- [1, max]. El -1 / +1 evita el caso pos==0 (cuando
    -- head==idx, la linea mas nueva esta en el ultimo slot antes
    -- del wrap).
    local pos = ((self.scrollback_head - idx - 1) % self.scrollback_max) + 1
    return self.scrollback[pos] or ""
end

function Terminal:scrollback_size()
    return self.scrollback_count
end

-- ── Navegacion del scrollback ─────────────────────────────

-- Cuantas filas podemos scrollear hacia arriba.
function Terminal:scrollback_max_offset()
    return self.scrollback_count
end

function Terminal:scrollback_up(n)
    n = n or 1
    local max = self:scrollback_max_offset()
    local new = self.scrollback_offset + n
    if new > max then new = max end
    if new ~= self.scrollback_offset then
        self.scrollback_offset = new
        self:_sync_scrollbar()
        if self.window then self.window:damage_all() end
    end
end

function Terminal:scrollback_down(n)
    n = n or 1
    local new = self.scrollback_offset - n
    if new < 0 then new = 0 end
    if new ~= self.scrollback_offset then
        self.scrollback_offset = new
        self:_sync_scrollbar()
        if self.window then self.window:damage_all() end
    end
end

function Terminal:scrollback_top()
    self.scrollback_offset = self:scrollback_max_offset()
    self:_sync_scrollbar()
    if self.window then self.window:damage_all() end
end

function Terminal:scrollback_bottom()
    self.scrollback_offset = 0
    self:_sync_scrollbar()
    if self.window then self.window:damage_all() end
end

-- Conecta un ScrollBar externo (de LaneTK). El SB es la fuente
-- de verdad del offset "del lado del usuario" (0 = arriba). El
-- Terminal traduce a su scrollback_offset (0 = vivo, N = atras).
function Terminal:set_scrollbar(sb)
    self._scrollbar = sb
    sb:on_change(function(new_sb_offset)
        -- IMPORTANTE: el ScrollBar calcula el offset con
        -- drag_base + (delta / range) * offset_max -> float.
        -- Si ese float llega a scrollback_line(), el indice
        -- self.scrollback[1999.7] es nil en Lua (no hay claves
        -- float en una tabla con claves enteras) y devuelve "".
        -- Resultado: filas vacias en medio del scrollback.
        -- Redondear y clampear antes de asignar.
        local new_off = self.scrollback_count - new_sb_offset
        if new_off < 0 then new_off = 0 end
        if new_off > self.scrollback_count then
            new_off = self.scrollback_count
        end
        new_off = math.floor(new_off + 0.5)
        if new_off ~= self.scrollback_offset then
            self.scrollback_offset = new_off
            self:damage()
            if self.window then self.window:damage_all() end
        end
    end)
    self:_sync_scrollbar()
end

-- Empuja el estado del scrollback al ScrollBar. silent = true
-- porque somos nosotros los que movemos, no el usuario: no hay
-- que disparar su on_change (seria loop).
function Terminal:_sync_scrollbar()
    if not self._scrollbar then return end
    self._scrollbar:set_offset_max(self.scrollback_count)
    local sb_offset = self.scrollback_count - self.scrollback_offset
    if sb_offset < 0 then sb_offset = 0 end
    self._scrollbar:set_offset(sb_offset, true)
end

-- Construye el row_layout para el renderer segun el offset.
-- Devuelve nil si estamos en vivo (draw usa el camino rapido).
--
-- Cacheado por (offset, count, rows): solo se reconstruye cuando
-- cambian. Durante scroll continuo, el offset cambia cada frame
-- pero el costo por frame pasa de ~40 tablas nuevas a 1
-- (invalidacion + reconstruccion).
function Terminal:_build_scrollback_layout()
    if self.scrollback_offset == 0 then
        self._layout_cache = nil
        return nil
    end
    -- Defensa: forzar enteros y clampear. Si algo deja pasar un
    -- float, scrollback_line() devolveria "" para indices
    -- fraccionarios (nil en la tabla).
    local n = math.floor(self.scrollback_offset + 0.5)
    if n < 0 then n = 0 end
    if n > self.scrollback_count then n = self.scrollback_count end
    local total = self.scrollback_count
    local rows = self.rows
    local cache = self._layout_cache
    if cache and cache.n == n and cache.total == total
       and cache.rows == rows then
        return cache.layout
    end

    local layout = {}
    for vy = 0, rows - 1 do
        local buffer_row = total - n + vy
        if buffer_row < 0 then
            layout[vy + 1] = { source = "scrollback", text = "" }
        elseif buffer_row < total then
            local idx = total - buffer_row
            layout[vy + 1] = {
                source = "scrollback",
                text = self:scrollback_line(idx),
            }
        else
            local vrow = buffer_row - total
            layout[vy + 1] = { source = "vterm", row = vrow }
        end
    end
    self._layout_cache = {
        n = n, total = total, rows = rows, layout = layout,
    }
    return layout
end

function Terminal:askMinMax(minw, minh, maxw, maxh)
    return minw + self.min_w, minh + self.min_h,
           maxw + 10000, maxh + 10000
end

function Terminal:_refit()
    local avail_w = self:getWidth()
    local avail_h = self:getHeight()
    if avail_w <= 0 or avail_h <= 0 then return end
    local cw, ch = self.renderer:cell_size()
    local new_cols = math.floor(avail_w / cw)
    local new_rows = math.floor(avail_h / ch)
    if new_cols < 1 then new_cols = 1 end
    if new_rows < 1 then new_rows = 1 end
    if new_cols ~= self.cols or new_rows ~= self.rows then
        self.cols = new_cols
        self.rows = new_rows
        self.term:resize(new_cols, new_rows)
        self:damage()
        self.renderer:invalidate_snapshot()
        self:_schedule_pty_resize()
    end
end

-- El pty.resize se manda con debounce: durante la creacion del
-- widget, el layout se llama varias veces con tamanos intermedios
-- antes del definitivo (por ejemplo 98x29, luego 51x30, luego
-- 112x31). Si mandamos TIOCSWINSZ en cada uno, el PTY termina
-- con 51x30 en el momento en que la app (htop, vim) abre, y esa
-- app lee el tamano equivocado al initscr(). SIGWINCH posterior
-- no siempre la corrije.
--
-- 80 ms es suficiente para que los layouts intermedios se
-- estabilicen sin que el usuario note el delay.
function Terminal:_schedule_pty_resize()
    if not self.server or not self.server.add_timeout then
        -- Sin server (etapa temprana): mandar directo.
        if self.pty then pty.resize(self.pty.fd, self.cols, self.rows) end
        return
    end
    if self._pty_resize_timer then
        self._pty_resize_timer:cancel()
    end
    self._pty_resize_timer = self.server:add_timeout(80, function()
        self._pty_resize_timer = nil
        if self.pty then
            pty.resize(self.pty.fd, self.cols, self.rows)
        end
    end)
end

function Terminal:layout(x0, y0, x1, y1)
    Area.layout(self, x0, y0, x1, y1)
    self:_refit()
end

function Terminal:_set_font(font)
    self.font = font
    self.renderer = render.new(font)
    log.info("terminal", "font: %s", font)
    self:_refit()
    if self.window then self.window:damage_all() end
end

function Terminal:adjust_font_size(delta)
    local family, size = self.font:match("^(.+)%s+(%d+)$")
    if not family then return end
    size = tonumber(size) + delta
    if size < MIN_SIZE then size = MIN_SIZE end
    if size > MAX_SIZE then size = MAX_SIZE end
    self:_set_font(family .. " " .. size)
end

function Terminal:reset_font_size()
    self:_set_font(self.default_font)
end

function Terminal:draw(cr)
    fill_bg(cr, self.x0, self.y0, self:getWidth(), self:getHeight(),
        self.default_bg)

    -- En modo scrollback el cursor no se muestra (estamos viendo
    -- historia, no la fila viva). En modo live, respeta blink y
    -- la ausencia de seleccion.
    local in_sb = self.scrollback_offset > 0
    local cursor = self.term:cursor()
    local cursor_vis = {
        row = cursor.row, col = cursor.col,
        visible = (not in_sb)
            and self._cursor_visible
            and self.sel:is_empty(),
        color = self.default_cursor,
    }

    -- El highlight de seleccion se pinta tambien en modo
    -- scrollback: con el auto-scroll el usuario esta scrolleado
    -- justo cuando esta seleccionando, y sin esto la banda azul
    -- desaparecia al arrastrar mas alla del viewport.
    local selected = nil
    if not self.sel:is_empty() then
        selected = function(r, c) return self.sel:contains(r, c) end
    end

    local layout = self:_build_scrollback_layout()

    self.renderer:draw(cr, self.term,
        self.x0, self.y0, self.cols, self.rows,
        cursor_vis,
        self.default_fg, self.default_bg,
        selected, layout)
end

-- ── Mouse ──────────────────────────────────────────────────

-- Convierte (mx, my) local al widget en (row, col) del vterm.
function Terminal:_cell_at(mx, my)
    local cw, ch = self.renderer:cell_size()
    local col = math.floor(mx / cw)
    local row = math.floor(my / ch)
    if col < 0 then col = 0 end
    if row < 0 then row = 0 end
    if col >= self.cols then col = self.cols - 1 end
    if row >= self.rows then row = self.rows - 1 end
    return row, col
end

-- Version sin clamp. Devuelve row/col crudos (pueden ser negativos
-- o mas alla del viewport). El llamador decide. Necesario para
-- detectar que el mouse salio del widget durante un drag.
function Terminal:_cell_at_unclamped(mx, my)
    local cw, ch = self.renderer:cell_size()
    return math.floor(my / ch), math.floor(mx / cw)
end

-- Mods del mouse: bitmask xterm.
--   4 = shift, 8 = alt, 16 = ctrl
-- Cacheados: sin cache, cada MotionNotify con mouse reporting hace
-- un query_keymap sincrono al X server (round-trip + allocs), y
-- con 60+ eventos/s eso satura un core. El cache dura 50 ms.
function Terminal:_mouse_mods()
    if not self.window or not self.window.server then return 0 end
    local now = timer.now_ms()
    if (now - self._mods_cache_t) < 50 then
        return self._mods_cache
    end
    local xcb = require("lib.xcb")
    local km = xcb.query_keymap(self.window.server.conn)
    local m = 0
    if km then
        -- keycodes fisicos: 50=Shift_L, 64=Alt_L, 37=Control_L.
        if xcb.key_pressed(km, 50) then m = m + 4 end
        if xcb.key_pressed(km, 64) then m = m + 8 end
        if xcb.key_pressed(km, 37) then m = m + 16 end
    end
    self._mods_cache = m
    self._mods_cache_t = now
    return m
end

-- Genera la secuencia xterm de mouse reporting (formato X10-compat).
--   ESC [ M <Cb> <Cx> <Cy>
-- Cb = 32 + button_code + mods (+32 si es movimiento)
-- Cx = 33 + col  (0-indexado)
-- Cy = 33 + row
-- button_code: 0=izq, 1=medio, 2=der, 3=release, 64=rueda arriba,
--              65=rueda abajo.
--
-- No usamos vterm_mouse_move/button de libvterm: en 0.3.3 esas
-- funciones dependen de un callback mousefunc que no esta
-- expuesto, y el output se pierde silenciosamente. Generar la
-- secuencia aca es equivalente y no depende de detalles internos.
function Terminal:_mouse_seq(button, row, col, is_motion, is_release)
    if row < 0 then row = 0 end
    if col < 0 then col = 0 end
    if row > 222 then row = 222 end
    if col > 222 then col = 222 end

    local m = self:_mouse_mods()

    -- Elegir protocolo: override del vterm si lo hay; si no, el
    -- default del terminfo (kmous via termcaps.mouse_encoding()).
    local use_sgr
    if self.term and self.term._mouse_override ~= nil then
        use_sgr = self.term._mouse_override
    else
        use_sgr = (self._mouse_encoding == "sgr")
    end

    local seq
    if use_sgr then
        -- SGR (1006): ESC[<Cb;Cx;CyM (press) / ESC[<Cb;Cx;Cym (release).
        --
        -- CRITICO: en SGR el Cb es SIEMPRE el numero del boton
        -- (0=izq, 1=medio, 2=der) tanto en press como en release.
        -- La distincion la hace la letra final (M vs m).
        -- El "codigo 3 = release" es del protocolo X10 viejo y no
        -- aplica a SGR. Mandarlo hace que ncurses interprete un
        -- release del boton 3 sin press previo y descarte el click.
        local cb = button + m
        if is_motion then cb = cb + 32 end
        local terminator = is_release and "m" or "M"
        seq = string.format("\27[<%d;%d;%d%s", cb, col + 1, row + 1, terminator)
    else
        -- X10: ESC[M + 3 bytes (Cb+32, Cx+33, Cy+33).
        -- Aca SI se usa bcode=3 para release.
        local bcode = button
        if is_release then bcode = 3 end
        local cb = bcode + m
        if is_motion then cb = cb + 32 end
        seq = string.char(27, 91, 77, 32 + cb, 32 + col + 1, 32 + row + 1)
    end

    if os.getenv("LANET_MOUSE_DEBUG") == "1" then
        local t = require("lib.timer").now_ms()
        local hex = {}
        for i = 1, #seq do hex[#hex + 1] = string.format("%02x", seq:byte(i)) end
        io.stderr:write(string.format(
            "[mouse %d] seq b=%d row=%d col=%d sgr=%s mot=%s rel=%s -> %s\n",
            t, button, row, col,
            tostring(use_sgr),
            tostring(is_motion), tostring(is_release),
            table.concat(hex, " ")))
    end
    return seq
end

function Terminal:on_mouse_press(mx, my, button)
    local row, col = self:_cell_at(mx, my)
    if os.getenv("LANET_MOUSE_DEBUG") == "1" then
        local cw, ch = self.renderer:cell_size()
        local t = require("lib.timer").now_ms()
        io.stderr:write(string.format(
            "[mouse %d] press mx=%d my=%d x0=%d y0=%d cell=%dx%d -> row=%d col=%d\n",
            t, mx, my, self.x0, self.y0, cw, ch, row, col))
    end
    self._mouse_last_row = row
    self._mouse_last_col = col

    local shift_held = bit.band(self:_mouse_mods(), 4) ~= 0
    if self._mouse_enabled and not shift_held then
        if not self.pty then return false end
        -- X button 1=left, 2=middle, 3=right.
        local b = button - 1   -- 0=left, 1=middle, 2=right
        if b < 0 or b > 2 then return true end
        local seq = self:_mouse_seq(b, row, col, false, false)
        pty.write(self.pty.fd, seq)
        return true
    end

    if button == 1 then
        -- Grab de puntero: X redirige los MotionNotify a nuestra
        -- ventana aunque el mouse salga del rect del widget. Sin
        -- esto, arrastrar hacia arriba del widget corta los
        -- eventos y no se puede seleccionar mas alla de lo visible.
        if self.window and self.window.conn then
            local xcb = require("lib.xcb")
            xcb.grab_pointer(self.window.conn, self.window.id)
        end
        self.sel:start(row, col)
        self._dragging = true
        if self.window then self.window:damage_all() end
        return true
    elseif button == 2 then
        -- Boton del medio: pegar PRIMARY.
        local text = clip.paste_from("primary")
        if text then
            pty.write(self.pty.fd, text)
        end
        return true
    end
    return false
end

function Terminal:on_mouse_move(mx, my)
    local row, col = self:_cell_at(mx, my)

    if self._mouse_enabled then
        local shift_held = bit.band(self:_mouse_mods(), 4) ~= 0
        if not shift_held then
            -- Solo emitir motion si el modo lo pide:
            --   bit 1 (0x02) = drag (mientras boton apretado)
            --   bit 2 (0x04) = move (cualquier movimiento)
            -- En modo 1000 (solo click), no emitir nada: sin esto,
            -- cada MotionNotify hacia un round-trip al X server
            -- para leer mods. Es lo que causaba el 50% de CPU.
            local mode = self._mouse_mode or 0
            local wants_move = bit.band(mode, 0x04) ~= 0
            local wants_drag = bit.band(mode, 0x02) ~= 0
            local dragging = self._dragging_mouse
            if wants_move or (wants_drag and dragging) then
                if row ~= self._mouse_last_row
                   or col ~= self._mouse_last_col then
                    self._mouse_last_row = row
                    self._mouse_last_col = col
                    -- button_code = 3 (release) + 32 (motion) en X10.
                    -- Es lo que esperan los apps para motion.
                    local seq = self:_mouse_seq(0, row, col, true, false)
                    if self.pty then pty.write(self.pty.fd, seq) end
                end
            end
        end
        if not self._dragging then return true end
    end

    if not self._dragging then return false end

    -- Auto-scroll: si el mouse salio del rect del widget, scrollear
    -- el scrollback por 1 linea y ajustar el ancla de la seleccion.
    --
    -- El ancla apunta a una fila VISUAL (0..rows-1). Cuando el
    -- viewport scrollea, el contenido de la fila N se corre a N+1
    -- (scroll hacia arriba) o N-1 (scroll hacia abajo). Sin el
    -- ajuste, la seleccion se deforma al scrollear.
    local urow = self:_cell_at_unclamped(mx, my)
    if urow < 0 then
        self:scrollback_up(1)
        if self.sel.anchor then
            self.sel.anchor.row = self.sel.anchor.row + 1
            if self.sel.anchor.row > self.rows - 1 then
                self.sel.anchor.row = self.rows - 1
            end
        end
        row = 0
    elseif urow >= self.rows then
        self:scrollback_down(1)
        if self.sel.anchor then
            self.sel.anchor.row = self.sel.anchor.row - 1
            if self.sel.anchor.row < 0 then
                self.sel.anchor.row = 0
            end
        end
        row = self.rows - 1
    end

    -- Clamp horizontal al borde de la fila (no hay scroll lateral).
    if col < 0 then col = 0 end
    if col >= self.cols then col = self.cols - 1 end

    self.sel:extend(row, col)
    if self.window then self.window:damage_all() end
    return true
end

function Terminal:on_wheel(direction)
    if not self.term or not self.pty then return false end
    -- Si la app pidio mouse reporting, mandarle el scroll como
    -- boton 4 (arriba) / 5 (abajo) de xterm. Convencion universal.
    if self._mouse_enabled and self.pty then
        local shift_held = bit.band(self:_mouse_mods(), 4) ~= 0
        if not shift_held then
            -- button_code: 64=up, 65=down (convencion xterm).
            -- Press + release (no hay boton fisico que soltar).
            local code = (direction == 4) and 64 or 65
            local cx = self._mouse_last_col
            local cy = self._mouse_last_row
            local seq_press = self:_mouse_seq(code, cy, cx, false, false)
            local seq_release = self:_mouse_seq(0, cy, cx, false, true)
            pty.write(self.pty.fd, seq_press .. seq_release)
            return true
        end
    end

    -- 3 lineas por click de rueda. direction 4 = arriba,
    -- 5 = abajo (convencion X11).
    if direction == 4 then
        self:scrollback_up(3)
        return true
    elseif direction == 5 then
        self:scrollback_down(3)
        return true
    end
    return false
end

function Terminal:on_mouse_release(mx, my, button)
    local row, col = self:_cell_at(mx, my)

    if self._mouse_enabled then
        local shift_held = bit.band(self:_mouse_mods(), 4) ~= 0
        if not shift_held and self.pty then
            local b = button - 1
            if b < 0 or b > 2 then return true end
            local seq = self:_mouse_seq(b, row, col, false, true)
            pty.write(self.pty.fd, seq)
            return true
        end
        -- Shift apretado: caer al flujo de seleccion local.
    end

    if button ~= 1 then return false end
    if not self._dragging then return false end
    self._dragging = false

    -- Liberar el grab de puntero tras la seleccion.
    if self.window and self.window.conn then
        local xcb = require("lib.xcb")
        xcb.ungrab_pointer(self.window.conn)
    end

    self.sel:extend(row, col)
    self.sel:finish()
    -- Copy-on-select: si hay seleccion, copiar a PRIMARY.
    if not self.sel:is_empty() then
        local text = self.sel:get_text(self.term, self.cols)
        if text and text ~= "" then
            clip.copy_to("primary", text)
        end
    end
    if self.window then self.window:damage_all() end
    return true
end

-- ── Teclado ────────────────────────────────────────────────

function Terminal:on_key(key)
    if not key or not key.pressed then return false end

    -- Hook para overrides locales (atajos personales del
    -- desarrollador). Si existe lib.terminal.local_overrides, se
    -- le da la chance de consumir la tecla ANTES de los defaults.
    -- Ese archivo esta en .gitignore: no se commitea. Si no
    -- existe (repo limpio en otra maquina), se usan los defaults.
    local has_ov, overrides = pcall(require, "lib.terminal.local_overrides")
    if has_ov and type(overrides) == "table"
       and type(overrides.on_key) == "function" then
        if overrides.on_key(self, key) then return true end
    end

    self._cursor_visible = true

    local n = key.name
    local m = key.mods or {}

    -- ── Atajos configurables ──
    -- El binding efectivo viene de config.keybindings pisado por
    -- los defaults. Los modificadores solos (Control_L, Shift_L)
    -- no matchean ningun combo, asi que el flujo sigue.
    local b = kb.effective()

    -- Aliases tradicionales que no son configurables (Ctrl+Insert
    -- y Shift+Insert). Se mantienen porque son parte del estandar
    -- X11 y casi nadie los reasigna.
    if m.ctrl and not m.shift and (n == "Insert") then
        local text = self.sel:get_text(self.term, self.cols)
        if text and text ~= "" then clip.copy_to("clipboard", text) end
        return true
    end
    if m.shift and not m.ctrl and (n == "Insert") then
        local text = clip.paste_from("clipboard")
        if text then self:_paste(text) end
        return true
    end

    -- Copy.
    if kb.match(key, b.copy) then
        local text = self.sel:get_text(self.term, self.cols)
        if text and text ~= "" then
            clip.copy_to("clipboard", text)
            log.info("terminal", "copy %d bytes", #text)
        end
        return true
    end
    -- Paste.
    if kb.match(key, b.paste) then
        local text = clip.paste_from("clipboard")
        if text then
            self:_paste(text)
        end
        return true
    end

    -- Scrollback.
    if kb.match(key, b.scrollback_up) then
        local step = self.rows - 1
        if step < 1 then step = 1 end
        self:scrollback_up(step)
        return true
    end
    if kb.match(key, b.scrollback_down) then
        local step = self.rows - 1
        if step < 1 then step = 1 end
        self:scrollback_down(step)
        return true
    end
    if kb.match(key, b.scrollback_top) then
        self:scrollback_top()
        return true
    end
    if kb.match(key, b.scrollback_bot) then
        self:scrollback_bottom()
        return true
    end

    -- Fuente.
    if kb.match(key, b.font_bigger) then
        self:adjust_font_size(1)
        return true
    end
    if kb.match(key, b.font_smaller) then
        self:adjust_font_size(-1)
        return true
    end
    if kb.match(key, b.font_reset) then
        self:reset_font_size()
        return true
    end

    -- Traducir primero. Modificadores solos (Control_L, Shift_L,
    -- Alt_L, Super_L) no traducen y salen por aca sin limpiar la
    -- seleccion.
    local tr = keys.translate(key)
    if not tr then return false end

    -- Escribir con scrollback activo: volver al vivo. El usuario
    -- quiso enviar input, no seguir mirando historia.
    if self.scrollback_offset > 0 then
        self.scrollback_offset = 0
        self:_sync_scrollbar()
        if self.window then self.window:damage_all() end
    end

    -- Va al shell. Limpiar seleccion (convencion xterm: escribir
    -- invalida la seleccion previa).
    if not self.sel:is_empty() then
        self.sel:clear()
    end

    local bytes
    if tr.type == "key" then
        bytes = self.term:key(tr.code, tr.mods)
    else
        bytes = self.term:unichar(tr.cp, tr.mods)
    end
    if bytes and #bytes > 0 then
        pty.write(self.pty.fd, bytes)
    end
    return true
end

-- Aplica preferencias nuevas sin recrear el objeto. Actualiza
-- fuente (rebuild del renderer + refit), blink, scrollback maximo.
-- El shell NO se puede cambiar en vivo (el PTY ya esta corriendo).
-- Un cambio de shell requiere nueva tab.
function Terminal:apply_preferences(prefs)
    if not prefs then return end

    -- Fuente.
    if prefs.font_family and prefs.font_size then
        local new_font = prefs.font_family .. " " .. tostring(prefs.font_size)
        if new_font ~= self.font then
            self:_set_font(new_font)
        end
    end

    -- Cursor parpadea.
    if prefs.cursor_blink ~= nil then
        self:set_blink_enabled(prefs.cursor_blink)
    end

    -- Colores. Recalcular default_fg/default_bg segun modo.
    if prefs.color_mode ~= nil
       or prefs.text_color ~= nil
       or prefs.bg_color ~= nil
       or prefs.cursor_color ~= nil then
        local T = self._theme or {}
        local function hex_to_rgb255(hex)
            if not hex or hex == "" then return nil end
            local G = require("lib.helpers.graphics")
            local ok, r, g, b = pcall(G.hex_to_rgba, hex)
            if not ok or r == nil then return nil end
            return { math.floor(r*255), math.floor(g*255), math.floor(b*255) }
        end
        local mode = prefs.color_mode or "theme"
        if mode == "custom" then
            self.default_fg = hex_to_rgb255(prefs.text_color)
                or self.default_fg or DEFAULT_FG
            self.default_bg = hex_to_rgb255(prefs.bg_color)
                or self.default_bg or DEFAULT_BG
        else
            self.default_fg = (T.fg_rgb
                and { T.fg_rgb[1]*255, T.fg_rgb[2]*255, T.fg_rgb[3]*255 })
                or DEFAULT_FG
            self.default_bg = (T.bg_rgb
                and { T.bg_rgb[1]*255, T.bg_rgb[2]*255, T.bg_rgb[3]*255 })
                or DEFAULT_BG
        end
        self.default_cursor = hex_to_rgb255(prefs.cursor_color)
            or self.default_cursor
        -- Los colores default cambiaron: el snapshot guardaba
        -- referencias viejas.
        self.renderer:invalidate_snapshot()
        self:damage()
        if self.window then self.window:damage_all() end
    end

    -- Scrollback maximo. Si el nuevo es menor que el actual,
    -- descartamos las lineas mas viejas.
    if prefs.scrollback_lines then
        local new_max = math.floor(prefs.scrollback_lines)
        if new_max < 100 then new_max = 100 end
        if new_max ~= self.scrollback_max then
            if new_max < self.scrollback_count then
                -- Reconstruir el buffer con las ultimas new_max lineas.
                local kept = {}
                for i = 1, new_max do
                    kept[i] = self:scrollback_line(i)
                end
                -- kept[1] es la mas reciente. Guardar en orden inverso.
                self.scrollback = {}
                self.scrollback_head = 1
                self.scrollback_count = 0
                for i = new_max, 1, -1 do
                    self.scrollback[self.scrollback_head] = kept[i]
                    self.scrollback_head = (self.scrollback_head % new_max) + 1
                    self.scrollback_count = self.scrollback_count + 1
                end
                if self.scrollback_offset > self.scrollback_count then
                    self.scrollback_offset = self.scrollback_count
                end
            end
            self.scrollback_max = new_max
            self._sync_scrollbar()
            if self.window then self.window:damage_all() end
        end
    end
end

-- Envia el texto al PTY. Si el shell activo bracketed paste
-- (ESC[?2004h), lo envuelve en ESC[200~ ... ESC[201~. Sin esto,
-- pegar un bloque multilinea hace que cada \n lo procese el
-- shell como Enter y ejecute cada linea como comando separado.
function Terminal:_paste(text)
    if not self.pty then return end
    local seq = text
    if self.term and self.term._bracketed_paste then
        seq = "\27[200~" .. text .. "\27[201~"
    end
    pty.write(self.pty.fd, seq)
    log.info("terminal", "paste %d bytes (bracketed=%s)",
        #text, tostring(self.term and self.term._bracketed_paste))
end

function Terminal:destroy()
    if self._cursor_timer then
        self._cursor_timer:cancel()
        self._cursor_timer = nil
    end
    if self.pty then
        pty.kill(self.pty.pid)
        pty.close(self.pty.fd)
        self.pty = nil
    end
    if self.term then
        self.term:free()
        self.term = nil
    end
end

return M
