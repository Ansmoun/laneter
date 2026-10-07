-- keybindings.lua: registro y matching de atajos de teclado.
--
-- Formato de combo: "ctrl+shift+c" (minusculas, `+` como
-- separador). Modificadores en orden fijo ctrl, shift, alt,
-- super. La tecla final usa el nombre xkb (c, plus, Prior,
-- Return, F5, Tab, ...).
--
-- Precedencia:
--   1. config.keybindings (si el usuario los edito)
--   2. defaults hardcoded (M.ACTIONS[].default)
--   3. local_overrides.lua (hook personal, en .gitignore)
--
-- Uso desde un widget:
--   local kb = require("lib.keybindings")
--   local b  = kb.effective()
--   if kb.match(key, b.copy) then ... end

local M = {}

-- Catalogo de acciones. Cada una tiene id estable (clave en la
-- config), label (para la UI), section (para agrupar) y default.
M.ACTIONS = {
    -- Terminal
    { id = "copy",            section = "terminal",
      label = "Copiar selección",       default = "ctrl+shift+c" },
    { id = "paste",           section = "terminal",
      label = "Pegar",                   default = "ctrl+shift+v" },
    { id = "scrollback_up",   section = "terminal",
      label = "Scrollback arriba",       default = "shift+Prior" },
    { id = "scrollback_down", section = "terminal",
      label = "Scrollback abajo",        default = "shift+Next" },
    { id = "scrollback_top",  section = "terminal",
      label = "Ir al inicio del buffer", default = "ctrl+Home" },
    { id = "scrollback_bot",  section = "terminal",
      label = "Ir al presente",          default = "ctrl+End" },
    { id = "font_bigger",     section = "terminal",
      label = "Fuente más grande",       default = "ctrl+plus" },
    { id = "font_smaller",    section = "terminal",
      label = "Fuente más chica",        default = "ctrl+minus" },
    { id = "font_reset",      section = "terminal",
      label = "Fuente por defecto",      default = "ctrl+0" },

    -- Pestañas
    { id = "new_tab",         section = "tabs",
      label = "Nueva pestaña",           default = "ctrl+t" },
    { id = "close_tab",       section = "tabs",
      label = "Cerrar pestaña",          default = "ctrl+w" },
    { id = "next_tab",        section = "tabs",
      label = "Siguiente pestaña",       default = "ctrl+Tab" },
    { id = "prev_tab",        section = "tabs",
      label = "Anterior pestaña",        default = "ctrl+shift+Tab" },
}

M.BY_ID = {}
for _, a in ipairs(M.ACTIONS) do M.BY_ID[a.id] = a end

-- Sinonimos de nombres xkb. En un teclado latam, "Ctrl+plus"
-- puede llegar como "equal", "asterisk" o "KP_Add" segun la
-- tecla fisica y el modificador. Aceptamos todos.
M.SYNONYMS = {
    plus   = { "plus", "equal", "asterisk", "KP_Add" },
    minus  = { "minus", "underscore", "KP_Subtract" },
    Prior  = { "Prior", "Page_Up" },
    Next   = { "Next", "Page_Down" },
    ["0"]  = { "0", "KP_0", "parenright" },
}

local function expand_key(name)
    local syn = M.SYNONYMS[name]
    if not syn then return { [name] = true } end
    local set = { [name] = true }
    for _, s in ipairs(syn) do set[s] = true end
    return set
end

-- Devuelve la tabla de defaults: { action_id = combo }
function M.defaults()
    local out = {}
    for _, a in ipairs(M.ACTIONS) do out[a.id] = a.default end
    return out
end

-- Bindings efectivos: defaults pisados por config. Se re-lee en
-- cada llamada (config.load esta cacheado internamente, es barato).
function M.effective()
    local config = require("lib.config")
    local cfg = config.get("keybindings") or {}
    local out = {}
    for _, a in ipairs(M.ACTIONS) do
        local v = cfg[a.id]
        if v == nil or v == "" then v = a.default end
        out[a.id] = v
    end
    return out
end

-- Convierte "ctrl+shift+c" en { key = "c", mods = {...} }.
-- Devuelve nil si el string es invalido o vacio.
function M.parse(combo)
    if not combo or combo == "" then return nil end
    local parts = {}
    for p in combo:gmatch("[^+]+") do
        parts[#parts + 1] = p
    end
    if #parts == 0 then return nil end
    local key_name = parts[#parts]
    local mods = { ctrl = false, shift = false, alt = false, super = false }
    for i = 1, #parts - 1 do
        local m = parts[i]:lower()
        if mods[m] ~= nil then mods[m] = true end
    end
    return { key = key_name, mods = mods }
end

-- Devuelve true si el evento de LaneTK corresponde al combo.
-- Compara mods exactos (si el combo no pide shift, un key con
-- shift no matchea). Los nombres de tecla se expanden con
-- M.SYNONYMS en ambos lados.
function M.match(key_event, combo)
    local parsed = M.parse(combo)
    if not parsed then return false end
    if not key_event or not key_event.name then return false end
    local expanded = expand_key(parsed.key)
    if not expanded[key_event.name] then return false end
    local m = key_event.mods or {}
    local function b(v) return v and true or false end
    if b(m.ctrl)  ~= parsed.mods.ctrl  then return false end
    if b(m.shift) ~= parsed.mods.shift then return false end
    if b(m.alt)   ~= parsed.mods.alt   then return false end
    if b(m.super) ~= parsed.mods.super then return false end
    return true
end

-- Construye un combo string desde un evento de LaneTK. Devuelve
-- nil si el evento es solo un modificador (Control_L, Shift_R,
-- etc), porque esos no forman un combo.
function M.combo_from_event(key_event)
    if not key_event or not key_event.name then return nil end
    local n = key_event.name
    if n:match("^Control_") or n:match("^Shift_")
       or n:match("^Alt_") or n:match("^Super_")
       or n:match("^Meta_") or n:match("^Hyper_")
       or n:match("^Caps_Lock") or n:match("^Num_Lock") then
        return nil
    end
    local m = key_event.mods or {}
    local parts = {}
    if m.ctrl  then parts[#parts + 1] = "ctrl"  end
    if m.shift then parts[#parts + 1] = "shift" end
    if m.alt   then parts[#parts + 1] = "alt"   end
    if m.super then parts[#parts + 1] = "super" end
    parts[#parts + 1] = n
    return table.concat(parts, "+")
end

-- Devuelve el listado de acciones por seccion, en orden de
-- declaracion. Util para construir la UI de preferencias.
function M.by_section(section)
    local out = {}
    for _, a in ipairs(M.ACTIONS) do
        if a.section == section then out[#out + 1] = a end
    end
    return out
end

return M
