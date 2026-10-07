-- config.lua: persistencia de preferencias de laneter.
-- Archivo: ~/.config/laneter/config.lua
-- Formato:
--   return {
--       font_family = "DejaVu Sans Mono",
--       font_size = 11,
--       shell = "/bin/bash",
--       scrollback_lines = 2000,
--       cursor_blink = true,
--   }
--
-- Se cachea en memoria. Use save() para persistir.

local M = {}

local HOME = os.getenv("HOME") or "/"
local DIR  = HOME .. "/.config/laneter"
local PATH = DIR .. "/config.lua"

-- Defaults. Se usan si la clave no esta en el archivo.
M.DEFAULTS = {
    font_family      = "DejaVu Sans Mono",
    font_size        = 11,
    shell            = nil,     -- nil = usar $SHELL
    scrollback_lines = 2000,
    cursor_blink     = true,
    -- Apariencia. color_mode = "theme" usa los colores del tema de
    -- LANE (fg/bg). = "custom" usa los hex de abajo.
    color_mode       = "theme",
    text_color       = "#e0e0e0",
    bg_color         = "#141418",
    cursor_color     = "#e0e0e0",
    -- Atajos. Se guardan como tabla anidada {accion = "combo"}.
    -- keybindings.effective() mezcla esto con los defaults.
    keybindings      = nil,
}

local _cache = nil

function M.load()
    if _cache then return _cache end
    local chunk = loadfile(PATH)
    if not chunk then
        _cache = {}
        return _cache
    end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= "table" then
        _cache = {}
        return _cache
    end
    _cache = t
    return _cache
end

function M.get(key, default)
    local t = M.load()
    local v = t[key]
    if v == nil then
        if default ~= nil then return default end
        return M.DEFAULTS[key]
    end
    return v
end

function M.set(key, value)
    local t = M.load()
    t[key] = value
end

function M.save()
    local t = M.load()
    os.execute("mkdir -p '" .. DIR:gsub("'", "'\\''") .. "'")
    local f = io.open(PATH, "w")
    if not f then return false end
    f:write("-- Generado automaticamente por laneter.\n")
    f:write("return {\n")
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        if v ~= nil then
            if type(v) == "table" then
                -- Sub-tabla (por ejemplo keybindings). Solo se
                -- serializan valores escalares string/number/bool.
                f:write(string.format("    %s = {\n", k))
                local subkeys = {}
                for sk in pairs(v) do subkeys[#subkeys + 1] = sk end
                table.sort(subkeys)
                for _, sk in ipairs(subkeys) do
                    local sv = v[sk]
                    if type(sv) == "string" then
                        f:write(string.format(
                            "        %s = %q,\n", sk, sv))
                    elseif type(sv) == "number" then
                        f:write(string.format(
                            "        %s = %s,\n", sk, tostring(sv)))
                    elseif type(sv) == "boolean" then
                        f:write(string.format(
                            "        %s = %s,\n", sk, tostring(sv)))
                    end
                end
                f:write("    },\n")
            elseif type(v) == "number" then
                f:write(string.format("    %s = %s,\n", k, tostring(v)))
            elseif type(v) == "boolean" then
                f:write(string.format("    %s = %s,\n", k, tostring(v)))
            else
                f:write(string.format("    %s = %q,\n", k, tostring(v)))
            end
        end
    end
    f:write("}\n")
    f:close()
    return true
end

function M.path()
    return PATH
end

return M
