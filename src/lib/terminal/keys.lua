-- keys.lua: traduce eventos de teclado de LaneTK a VTermKey + mods.
--
-- LaneTK entrega `key` como { name, pressed, mods = {shift,alt,ctrl,super} }.
-- name es un string ya resuelto por xkb (xkb_keysym_get_name).
--
-- Mapea:
--   - Nombres especiales (Return, BackSpace, Up, F1, ...) a VTermKey.
--   - Caracteres imprimibles (1 char UTF-8) a codepoint (unichar).
--   - Nombres simbolicos (plus, comma, ...) a codepoint.
--   - Nada reconocido: nil.
--
-- API:
--   M.translate(key) -> { type = "key", code = N, mods = M }
--                     | { type = "unichar", cp = C, mods = M }
--                     | nil

local M = {}

-- VTermKey segun cdef/vterm.lua.
local VK = {
    NONE      = 0,
    ENTER     = 1,
    TAB       = 2,
    BACKSPACE = 3,
    ESCAPE    = 4,
    UP        = 5,
    DOWN      = 6,
    LEFT      = 7,
    RIGHT     = 8,
    INS       = 9,
    DEL       = 10,
    HOME      = 11,
    END       = 12,
    PAGEUP    = 13,
    PAGEDOWN  = 14,
    FUNC_0    = 256,
}

local SPECIAL = {
    Return     = VK.ENTER,
    KP_Enter   = VK.ENTER,
    Tab        = VK.TAB,
    ISO_Left_Tab = VK.TAB,
    BackSpace  = VK.BACKSPACE,
    Escape     = VK.ESCAPE,
    Up         = VK.UP,
    Down       = VK.DOWN,
    Left       = VK.LEFT,
    Right      = VK.RIGHT,
    Insert     = VK.INS,
    Delete     = VK.DEL,
    Home       = VK.HOME,
    End        = VK.END,
    Prior      = VK.PAGEUP,
    Next       = VK.PAGEDOWN,
    Page_Up    = VK.PAGEUP,
    Page_Down  = VK.PAGEDOWN,
}

-- Nombres simbolicos xkb -> codepoint. Solo los mas comunes.
-- Los que no esten aca se ignoran (F2 los agrega).
local SYMBOL_CP = {
    space         = 0x20,
    exclam        = 0x21,
    quotedbl      = 0x22,
    numbersign    = 0x23,
    dollar        = 0x24,
    percent       = 0x25,
    ampersand     = 0x26,
    apostrophe    = 0x27,
    parenleft     = 0x28,
    parenright    = 0x29,
    asterisk      = 0x2A,
    plus          = 0x2B,
    comma         = 0x2C,
    minus         = 0x2D,
    period        = 0x2E,
    slash         = 0x2F,
    colon         = 0x3A,
    semicolon     = 0x3B,
    less          = 0x3C,
    equal         = 0x3D,
    greater       = 0x3E,
    question      = 0x3F,
    at            = 0x40,
    bracketleft   = 0x5B,
    backslash     = 0x5C,
    bracketright  = 0x5D,
    asciicircum   = 0x5E,
    underscore    = 0x5F,
    grave         = 0x60,
    braceleft     = 0x7B,
    bar           = 0x7C,
    braceright    = 0x7D,
    asciitilde    = 0x7E,
}

-- Decodifica un string UTF-8 a un codepoint. nil si no es un solo
-- codepoint valido.
local function utf8_codepoint(s)
    if #s == 0 then return nil end
    local b1 = s:byte(1)
    if b1 < 0x80 then
        if #s == 1 then return b1 end
        return nil
    end
    -- Continuation bytes.
    if b1 < 0xC0 then return nil end
    local n, mask, cp
    if b1 < 0xE0 then
        n, mask, cp = 2, 0x1F, b1 - 0xC0
    elseif b1 < 0xF0 then
        n, mask, cp = 3, 0x0F, b1 - 0xE0
    else
        n, mask, cp = 4, 0x07, b1 - 0xF0
    end
    if #s ~= n then return nil end
    for i = 2, n do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then return nil end
        cp = cp * 0x40 + (b - 0x80)
    end
    return cp
end

local function mods_of(key)
    local m = 0
    local k = key.mods or {}
    if k.shift then m = m + 1 end
    if k.alt   then m = m + 2 end
    if k.ctrl  then m = m + 4 end
    -- super no es VTERM_MOD_*. libvterm solo reconoce shift/alt/ctrl.
    return m
end

function M.translate(key)
    if type(key) ~= "table" or not key.name then return nil end
    local mods = mods_of(key)

    -- 1. Nombres especiales.
    local sp = SPECIAL[key.name]
    if sp then
        return { type = "key", code = sp, mods = mods }
    end

    -- 2. F1..F12.
    local fnum = key.name:match("^F(%d+)$")
    if fnum then
        local n = tonumber(fnum)
        if n and n >= 1 and n <= 24 then
            return { type = "key", code = VK.FUNC_0 + n, mods = mods }
        end
    end

    -- 3. Un solo caracter: UTF-8 -> codepoint.
    local cp = utf8_codepoint(key.name)
    if cp then
        return { type = "unichar", cp = cp, mods = mods }
    end

    -- 4. Nombres simbolicos.
    local sym_cp = SYMBOL_CP[key.name]
    if sym_cp then
        return { type = "unichar", cp = sym_cp, mods = mods }
    end

    return nil
end

M.VK = VK

return M
