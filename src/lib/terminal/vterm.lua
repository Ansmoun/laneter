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
_cb_keepalive.pushline = function(cols, cells, user)
    local id = tonumber(ffi.cast("intptr_t", user))
    local h = _handlers[id]
    if h and h.on_pushline then
        local text = cells_to_utf8(cells, cols)
        -- libvterm rellena las celdas no escritas de la fila con
        -- espacios. Los quitamos del final: son padding, no
        -- contenido. Espacios iniciales (indentacion) se respetan.
        text = text:gsub("%s+$", "")
        h.on_pushline(text, cols)
    end
    return 0
end

_cb_keepalive.popline = function(cols, cells, user)
    -- No soportamos pop todavia (no re-scrolleamos lineas devuelta
    -- al viewport). Devolver 0 indica a libvterm que no tomamos
    -- la linea.
    return 0
end

_cb_keepalive.clear = function(user)
    local id = tonumber(ffi.cast("intptr_t", user))
    local h = _handlers[id]
    if h and h.on_clear then h.on_clear() end
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
    _next_id = _next_id + 1
    local my_id = _next_id
    lib.vterm_screen_set_callbacks(screen, cbs,
        ffi.cast("void*", my_id))
    -- Damage merge fino (por celda). No usamos damages aun, pero
    -- dejarlo fino es lo mas util para F2+.
    lib.vterm_screen_set_damage_merge(screen, 0)

    local state = lib.vterm_obtain_state(vt)

    -- Reset inicial para aplicar la configuracion.
    lib.vterm_state_reset(state, 1)
    lib.vterm_screen_reset(screen, 1)

    local self = setmetatable({
        vt = vt, screen = screen, state = state,
        cols = cols, rows = rows,
        _id = my_id,
        -- IMPORTANTE: mantener viva la struct de callbacks. libvterm
        -- guarda el puntero internamente, pero LuaJIT no ve la
        -- referencia desde su lado; sin esta linea, el GC la libera
        -- y el proximo callback lee memoria invalida (segfault).
        _cbs = cbs,
    }, VTermHandle)
    _handlers[my_id] = self
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
    self.on_pushline = handler.on_pushline
    self.on_popline  = handler.on_popline
    self.on_clear    = handler.on_clear
end

function VTermHandle:feed(bytes)
    if type(bytes) ~= "string" or #bytes == 0 then return end
    lib.vterm_input_write(self.vt, bytes, #bytes)
    lib.vterm_screen_flush_damage(self.screen)
end

function VTermHandle:cell(row, col)
    local pos = ffi.new("VTermPos")
    pos.row = row
    pos.col = col
    local cell = ffi.new("VTermScreenCell")
    if lib.vterm_screen_get_cell(self.screen, pos, cell) == 0 then
        return nil
    end
    if cell.chars[0] == 0 then
        -- Celda vacia.
        return {
            utf8 = "", width = 0,
            fg = nil, bg = nil,
            attrs = { bold=false, underline=false, italic=false,
                      blink=false, reverse=false, conceal=false,
                      strike=false, font=0 },
        }
    end

    -- Concatenar codepoints hasta el terminador 0.
    local parts = {}
    for i = 0, 5 do
        local cp = cell.chars[i]
        if cp == 0 then break end
        parts[#parts + 1] = utf8_encode(cp)
    end

    local bits = cell.attrs.bits
    return {
        utf8  = table.concat(parts),
        width = tonumber(cell.width),
        fg    = color_to_rgb(self.screen, cell.fg),
        bg    = color_to_rgb(self.screen, cell.bg),
        attrs = {
            bold      = bit.band(bits, BOLD) ~= 0,
            underline = bit.band(bits, UNDERLINE) ~= 0,
            italic    = bit.band(bits, ITALIC) ~= 0,
            blink     = bit.band(bits, BLINK) ~= 0,
            reverse   = bit.band(bits, REVERSE) ~= 0,
            conceal   = bit.band(bits, CONCEAL) ~= 0,
            strike    = bit.band(bits, STRIKE) ~= 0,
            font      = bit.band(bit.rshift(bits, 8), 0x0F),
        },
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
