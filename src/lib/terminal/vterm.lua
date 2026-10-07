-- vterm.lua: wrapper de libvterm 0.3.3.
--
-- libvterm es el parser VT + modelo de pantalla. Le alimentamos
-- bytes del PTY y leemos celdas de la grilla. La generacion de
-- bytes para el shell (teclas) tambien la hace libvterm, para no
-- reimplementar el mapeo keysym -> secuencia VT.
--
-- API:
--   M.new(cols, rows)               -> handle | nil, err
--   handle:feed(bytes)              alimenta bytes del PTY
--   handle:cell(row, col)           -> { utf8, width, fg, bg, attrs } | nil
--   handle:cursor()                 -> { row, col }
--   handle:resize(cols, rows)
--   handle:key(keycode, mods)       -> bytes para el shell | ""
--   handle:unichar(codepoint, mods) -> bytes para el shell | ""
--   handle:free()
--
-- fg/bg son {r,g,b} con componentes 0-255, o nil si la celda usa
-- el color por defecto del terminal. El consumidor decide que
-- pintar en ese caso (tipicamente el fg/bg del tema).
--
-- attrs es un table con: bold, underline, italic, blink, reverse,
-- conceal, strike (booleanos) y font (entero 0-15).

local ffi = require("bindings.cdef.vterm")
local lib = ffi.load("libvterm.so.0")

local M = {}

-- ── Tabla de handlers para los callbacks C ──
--
-- LuaJIT no permite closures con upvalues en function pointers
-- C. El patrón seguro: un callback estático por evento, que
-- recibe un 'user' (entero cast a void*) y busca su handler en
-- esta tabla. El entero lo asignamos al crear cada VTermHandle.
local _handlers = {}
local _next_id = 0

-- Footgun de LuaJIT FFI: cuando se asigna un closure Lua a un
-- campo funcion-pointer de un cdata (VTermScreenCallbacks), la
-- cdata guarda el puntero C de la funcion, pero NO mantiene viva
-- la parte Lua del closure. Si el GC lo libera, el puntero queda
-- colgando -> "bad callback" (PANIC) cuando libvterm lo invoca.
--
-- Fix: guardar los closures en esta tabla del modulo para que
-- vivan mientras el modulo este cargado. Es barato y elimina la
-- clase entera de bugs. Se asignan mas abajo, apenas se definen.
local _cb_keepalive = {}

-- Extrae el texto UTF-8 de un array de VTermScreenCell. Tambien
-- devuelve las celdas como tabla para el scrollback en color.
local function cells_to_utf8(cells, cols)
    local parts = {}
    for i = 0, cols - 1 do
        local cell = cells[i]
        if cell.chars[0] == 0 then
            parts[#parts + 1] = " "
        else
            for j = 0, 5 do
                local cp = cell.chars[j]
                if cp == 0 then break end
                -- Reusamos el mismo encoder de mas abajo. Es
                -- intencional: no queremos depender de una
                -- funcion que todavia no esta definida.
                if cp < 0x80 then
                    parts[#parts + 1] = string.char(cp)
                elseif cp < 0x800 then
                    parts[#parts + 1] = string.char(
                        0xC0 + math.floor(cp / 0x40),
                        0x80 + (cp % 0x40))
                elseif cp < 0x10000 then
                    parts[#parts + 1] = string.char(
                        0xE0 + math.floor(cp / 0x1000),
                        0x80 + math.floor((cp / 0x40) % 0x40),
                        0x80 + (cp % 0x40))
                else
                    parts[#parts + 1] = string.char(
                        0xF0 + math.floor(cp / 0x40000),
                        0x80 + math.floor((cp / 0x1000) % 0x40),
                        0x80 + math.floor((cp / 0x40) % 0x40),
                        0x80 + (cp % 0x40))
                end
            end
        end
    end
    return table.concat(parts)
end

-- Callback: una linea sale por arriba del viewport. libvterm la
-- pasa como array de celdas de tamano 'cols'.
-- Callbacks FFI planos (sin anidar closures). LuaJIT castea
-- estos closures a function pointers C: cada uno captura SOLO
-- _handlers (upvalue compartido del modulo). Nada de safe(fn):
-- anidar un closure dentro de otro rompe el trampolin FFI en
-- algunos casos y el GC libera el interno.
--
-- El pcall va adentro: si algo falla, el error queda en stderr
-- y devolvemos 0. No protege de un callback recolectado (eso lo
-- evita _cb_keepalive y el id poblado a tiempo en M.new), pero
-- protege de cualquier error de Lua en la logica interna.
_cb_keepalive.pushline = function(cols, cells, user)
    local ok, err = pcall(function()
        local id = tonumber(ffi.cast("intptr_t", user))
        local h = _handlers[id]
        if h and h.on_pushline then
            local text = cells_to_utf8(cells, cols)
            text = text:gsub("%s+$", "")
            h.on_pushline(text, cols)
        end
    end)
    if not ok then
        io.stderr:write("[vterm pushline] " .. tostring(err) .. "\n")
    end
    return 0
end

_cb_keepalive.popline = function(cols, cells, user)
    -- No soportamos pop todavia.
    return 0
end

_cb_keepalive.clear = function(user)
    local ok, err = pcall(function()
        local id = tonumber(ffi.cast("intptr_t", user))
        local h = _handlers[id]
        if h and h.on_clear then h.on_clear() end
    end)
    if not ok then
        io.stderr:write("[vterm clear] " .. tostring(err) .. "\n")
    end
    return 0
end

-- settermprop: libvterm lo dispara cuando la app que corre en el
-- terminal (vim, htop, less) cambia alguna propiedad del terminal.
-- Nos interesa VTERM_PROP_MOUSE (id 8): cuando la app pide mouse
-- reporting, libvterm avisa y nosotros empezamos a mandarle los
-- eventos del mouse. val es VTermValue*, union cuyo primer campo
-- es int (o int boolean/number, mismo layout).
_cb_keepalive.settermprop = function(prop, val, user)
    local ok, err = pcall(function()
        local id = tonumber(ffi.cast("intptr_t", user))
        local h = _handlers[id]
        if h and h.on_settermprop then
            local number = ffi.cast("int*", val)[0]
            h.on_settermprop(prop, number)
        end
    end)
    if not ok then
        io.stderr:write("[vterm settermprop] " .. tostring(err) .. "\n")
    end
    return 0
end

-- Mascaras de VTermScreenCellAttrs (bits LSB-first segun layout
-- de gcc en x86_64 System V).
local BOLD      = 0x0001
local UNDERLINE = 0x0006  -- 2 bits
local ITALIC    = 0x0008
local BLINK     = 0x0010
local REVERSE   = 0x0020
local CONCEAL   = 0x0040
local STRIKE    = 0x0080
local FONT_MASK = 0x0F00  -- 4 bits

-- Encoder UTF-8 minimo. Codepoints > 0x10FFFF no son validos pero
-- libvterm nunca los produce.
local function utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor((cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor((cp / 0x1000) % 0x40),
            0x80 + math.floor((cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
end

-- Extrae {r,g,b} de un VTermColor*. nil si es default fg/bg.
-- Si es indexed, libvterm lo convierte via su paleta.
local function color_to_rgb(screen, color)
    local type_ = color.type
    -- Bits 0x02 (default_fg) y 0x04 (default_bg).
    if bit.band(type_, 0x06) ~= 0 then return nil end
    local tmp = ffi.new("VTermColor")
    ffi.copy(tmp, color, ffi.sizeof("VTermColor"))
    lib.vterm_screen_convert_color_to_rgb(screen, tmp)
    return { tmp.rgb.red, tmp.rgb.green, tmp.rgb.blue }
end

local VTermHandle = {}
VTermHandle.__index = VTermHandle

-- Cache global de colores convertidos. El indice es (R<<16)|(G<<8)|B.
-- Hay 256 colores de paleta + RGBs custom. Reusar la tabla evita
-- crear 3472 tablas nuevas por snapshot.
local _color_cache = {}
local function cached_color(r, g, b)
    local key = r * 65536 + g * 256 + b
    local c = _color_cache[key]
    if c then return c end
    c = { r, g, b }
    _color_cache[key] = c
    return c
end

-- Cdata reusado para pos y cell. Un solo par por instancia.
-- Antes cada cell() creaba dos cdata nuevos; con 3472 celdas por
-- snapshot eran 6944 allocaciones nuevas cada vez.
local function ensure_scratch(self)
    if not self._pos then
        self._pos  = ffi.new("VTermPos")
        self._cell = ffi.new("VTermScreenCell")
    end
end

function M.new(cols, rows)
    cols = cols or 80
    rows = rows or 24

    local vt = lib.vterm_new(rows, cols)
    if vt == nil then return nil, "vterm_new nil" end

    lib.vterm_set_utf8(vt, 1)

    local screen = lib.vterm_obtain_screen(vt)
    -- Alt screen: lo necesitan vim, less, htop.
    lib.vterm_screen_enable_altscreen(screen, 1)
    -- Reflow: cuando redimensionamos, las lineas se reajustan.
    lib.vterm_screen_enable_reflow(screen, 1)
    -- Sin callbacks: leemos la grilla directamente en el draw.
    -- Registrar callbacks. Estado: id del handle en _handlers.
    local cbs = ffi.new("VTermScreenCallbacks")
    cbs.sb_pushline = _cb_keepalive.pushline
    cbs.sb_popline  = _cb_keepalive.popline
    cbs.sb_clear    = _cb_keepalive.clear
    cbs.settermprop = _cb_keepalive.settermprop
    _next_id = _next_id + 1
    local my_id = _next_id
    lib.vterm_screen_set_callbacks(screen, cbs,
        ffi.cast("void*", my_id))
    -- Damage merge fino (por celda). No usamos damages aun, pero
    -- dejarlo fino es lo mas util para F2+.
    lib.vterm_screen_set_damage_merge(screen, 0)

    local state = lib.vterm_obtain_state(vt)

    -- Poblar el handler ANTES de cualquier reset. Los resets
    -- pueden disparar callbacks (por ejemplo sb_clear). Si el
    -- handler no esta todavia en _handlers, el callback corre con
    -- h = nil y no hace nada, pero cualquier carrera con el GC
    -- del trampolin puede dejar el cdata de la cbs en mal estado.
    local self = setmetatable({
        vt = vt, screen = screen, state = state,
        cols = cols, rows = rows,
        _id = my_id,
        -- Mantener viva la struct de callbacks. libvterm guarda el
        -- puntero internamente; sin esta referencia, el GC puede
        -- liberar la cdata y el siguiente callback lee memoria
        -- invalida -> "bad callback".
        _cbs = cbs,
    }, VTermHandle)
    _handlers[my_id] = self

    -- Reset inicial para aplicar la configuracion.
    lib.vterm_state_reset(state, 1)
    lib.vterm_screen_reset(screen, 1)

    return self
end

-- El consumidor (widget) registra sus funciones. Se llaman desde
-- el callback C cuando libvterm decide que una linea salio.
--
--   h.on_pushline(text, cols)  linea empujada al scrollback
--   h.on_clear()               scrollback limpiado (reset)
function VTermHandle:set_scrollback_callbacks(handler)
    -- El handler reemplaza a self en la tabla: guardamos la
    -- funcion adentro de self, y usamos self como handler.
    -- Mantenemos la referencia al self (que ya esta registrado
    -- en _handlers[id]).
    self.on_pushline    = handler.on_pushline
    self.on_popline     = handler.on_popline
    self.on_clear       = handler.on_clear
    -- settermprop es opcional: la app lo usa para saber cuando el
    -- terminal debe entrar en mouse reporting.
    self.on_settermprop = handler.on_settermprop
end

-- ── Mouse reporting ────────────────────────────────────────
--
-- Cuando la app que corre dentro del terminal pide mouse
-- reporting (via ESC[?1000h o 1002h o 1003h o 1006h), libvterm
-- dispara on_settermprop(VTERM_PROP_MOUSE, mode) donde mode != 0
-- significa "activo". El widget consulta self._mouse_enabled y,
-- si esta activo, redirige los eventos del mouse a estas
-- funciones.
--
-- button: 1 = izquierda, 2 = medio, 3 = derecha (mismos codigos
-- que xterm y que los eventos X11).
-- mods: bitmask: 4 = shift, 8 = alt/meta, 16 = ctrl.

function VTermHandle:mouse_move(row, col, mods)
    lib.vterm_mouse_move(self.vt, row, col, mods or 0)
end

function VTermHandle:mouse_button(button, pressed, mods)
    lib.vterm_mouse_button(self.vt, button, pressed, mods or 0)
end

-- Drena el buffer de output de libvterm (las secuencias de mouse
-- que genero a partir de los eventos). Se escribe al PTY.
function VTermHandle:drain_output()
    local buf = ffi.new("char[128]")
    local n = lib.vterm_output_read(self.vt, buf, 128)
    if n == 0 then return "" end
    return ffi.string(buf, n)
end

VTermHandle.PROP_MOUSE = 8

function VTermHandle:feed(bytes)
    if type(bytes) ~= "string" or #bytes == 0 then return end
    -- Detectar modo 1006 (SGR extended mouse). libvterm 0.3.3 no
    -- expone el encoding en VTERM_PROP_MOUSE, solo on/off. Cuando
    -- htop activa 1006 y nosotros mandamos X10 (ESC [ M + 3 bytes),
    -- htop no entiende el formato y parsea la secuencia como
    -- teclas sueltas -> efectos raros (colapsar header, taggeos
    -- aleatorios, toggles de layout).
    -- find con plain=true: buscar el string literal, sin patrones
    -- Lua. El `?` es quantifier en Lua patterns, sin esto la
    -- deteccion nunca matchea y siempre mandamos X10, que htop
    -- interpreta como basura (borra lineas, manda caracteres
    -- como texto, dispara teclas sueltas como M = toggle meters).
    if bytes:find("\27[?1006h", 1, true) then
        self._sgr_mouse = true
    end
    if bytes:find("\27[?1006l", 1, true) then
        self._sgr_mouse = false
    end
    if bytes:find("\27[?1005h", 1, true)
       or bytes:find("\27[?1015h", 1, true) then
        self._sgr_mouse = true
    end
    -- Debug: ver que pide htop al activar mouse.
    if os.getenv("LANET_FEED_LOG") == "1"
       and bytes:find("\27[?", 1, true) then
        local t = require("lib.timer").now_ms()
        local esc = bytes:gsub("[%c]", function(c)
            return string.format("\\x%02x", c:byte())
        end)
        io.stderr:write(string.format("[feed %d] %s\n", t, esc))
    end
    -- CRITICO: vterm_input_write puede disparar decenas de miles
    -- de callbacks FFI (sb_pushline por cada linea que sale del
    -- viewport). Si el GC de LuaJIT corre en medio del trampolin
    -- FFI, lo invalida y el proceso muere con "bad callback".
    --
    -- Con buffers grandes (por ejemplo `seq 1 500000`, ~3 MB),
    -- el GC corre seguido porque cells_to_utf8 y text:gsub
    -- allocan strings temporales por linea. Deshabilitar el GC
    -- durante el write elimina la clase entera de crash. Se
    -- reactiva al volver: el GC no acumula basura mas alla de lo
    -- que generen los propios callbacks, y el buffer se drena
    -- rapido.
    collectgarbage("stop")
    lib.vterm_input_write(self.vt, bytes, #bytes)
    collectgarbage("restart")
    lib.vterm_screen_flush_damage(self.screen)
end

function VTermHandle:cell(row, col)
    ensure_scratch(self)
    local pos = self._pos
    local cell = self._cell
    pos.row = row
    pos.col = col
    if lib.vterm_screen_get_cell(self.screen, pos, cell) == 0 then
        return nil
    end

    local bits = cell.attrs.bits
    if cell.chars[0] == 0 then
        -- Celda vacia. Devolvemos tabla minima; el render tiene
        -- una ruta rapida para utf8 == "".
        return {
            utf8 = "", width = 0,
            fg = nil, bg = nil,
            bold = false, italic = false,
            underline = false, strike = false, conceal = false,
            reverse = false,
        }
    end

    -- Concatenar codepoints hasta el terminador 0.
    local parts = {}
    for i = 0, 5 do
        local cp = cell.chars[i]
        if cp == 0 then break end
        parts[#parts + 1] = utf8_encode(cp)
    end

    -- Colores via cache. color_to_rgb ya devuelve {r,g,b}; lo
    -- pasamos por cached_color para dedupe.
    local fg = color_to_rgb(self.screen, cell.fg)
    local bg = color_to_rgb(self.screen, cell.bg)
    if fg then fg = cached_color(fg[1], fg[2], fg[3]) end
    if bg then bg = cached_color(bg[1], bg[2], bg[3]) end

    -- Tabla con campos planos (sin sub-tabla attrs). El render lee
    -- directo cell.bold, cell.underline, etc. Menos allocaciones.
    return {
        utf8      = table.concat(parts),
        width     = tonumber(cell.width),
        fg        = fg,
        bg        = bg,
        bold      = bit.band(bits, BOLD) ~= 0,
        underline = bit.band(bits, UNDERLINE) ~= 0,
        italic    = bit.band(bits, ITALIC) ~= 0,
        blink     = bit.band(bits, BLINK) ~= 0,
        reverse   = bit.band(bits, REVERSE) ~= 0,
        conceal   = bit.band(bits, CONCEAL) ~= 0,
        strike    = bit.band(bits, STRIKE) ~= 0,
        font      = bit.band(bit.rshift(bits, 8), 0x0F),
    }
end

function VTermHandle:cursor()
    local pos = ffi.new("VTermPos")
    lib.vterm_state_get_cursorpos(self.state, pos)
    return { row = pos.row, col = pos.col }
end

function VTermHandle:resize(cols, rows)
    if cols == self.cols and rows == self.rows then return end
    self.cols = cols
    self.rows = rows
    lib.vterm_set_size(self.vt, rows, cols)
end

-- Devuelve bytes que el shell espera para una tecla. keycode es
-- VTERM_KEY_* (ver cdef/vterm.lua). mods es la mascara VTERM_MOD_*.
function VTermHandle:key(keycode, mods)
    lib.vterm_keyboard_key(self.vt, keycode, mods or 0)
    local buf = ffi.new("char[64]")
    local n = lib.vterm_output_read(self.vt, buf, 64)
    if n == 0 then return "" end
    return ffi.string(buf, n)
end

function VTermHandle:unichar(cp, mods)
    lib.vterm_keyboard_unichar(self.vt, cp, mods or 0)
    local buf = ffi.new("char[64]")
    local n = lib.vterm_output_read(self.vt, buf, 64)
    if n == 0 then return "" end
    return ffi.string(buf, n)
end

function VTermHandle:free()
    if self.vt then
        _handlers[self._id] = nil
        lib.vterm_free(self.vt)
        self.vt = nil
        self.screen = nil
        self.state = nil
    end
end

return M
