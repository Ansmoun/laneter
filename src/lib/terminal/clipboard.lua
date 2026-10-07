-- clipboard.lua: wrappers de xclip para CLIPBOARD y PRIMARY.
--
-- En X11 hay dos selecciones relevantes:
--   CLIPBOARD: Ctrl+C/Ctrl+V clasico.
--   PRIMARY:   seleccion automatica con el mouse. Se pega con
--              boton del medio. Vive en xterm/alacritty por
--              convencion.
--
-- Escribir: xclip se queda como daemon sirviendo el contenido
-- hasta que otro cliente lo pise. Lo lanzamos en background con
-- & para no bloquear el server. -loops 1 hace que se salga
-- despues del primer request (evita zombies si nadie pega).

local M = {}

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.copy_to(selection, text)
    if not text or text == "" then return end
    selection = selection or "clipboard"
    local cmd = string.format(
        "printf '%%s' %s | xclip -selection %s -loops 1 " ..
        ">/dev/null 2>&1 &",
        shq(text), selection)
    os.execute(cmd)
end

function M.paste_from(selection)
    selection = selection or "clipboard"
    local f = io.popen(
        "xclip -selection " .. selection .. " -o 2>/dev/null")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    if not text or text == "" then return nil end
    return text
end

return M
