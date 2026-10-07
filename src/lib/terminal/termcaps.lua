-- termcaps.lua: consultas al terminfo via tput.
--
-- El unico dato que necesitamos es 'kmous' (mouse event terminfo
-- capability). Define el FORMATO que la app espera para las
-- respuestas del mouse:
--   "\e[M"  -> X10 (formato viejo, 3 bytes)
--   "\e[<"  -> SGR (formato moderno, 1006, decimales)
--
-- ncurses lee kmous UNA VEZ al inicializar y parsea todas las
-- respuestas con ese formato. htop usa ncurses, asi que el
-- terminfo manda. Sin esto, mandamos X10 cuando ncurses espera
-- SGR y los bytes se interpretan como teclas sueltas (M = toggle
-- meters en htop, digitos = sort).
--
-- Cacheado: tput cuesta ~10 ms, se llama una vez por proceso.

local M = {}

local _cache = nil

function M.mouse_encoding()
    if _cache then return _cache end
    local term = os.getenv("TERM") or ""
    if term == "" then
        _cache = "x10"
        return _cache
    end
    local p = io.popen("tput kmous 2>/dev/null")
    if not p then
        _cache = "x10"
        return _cache
    end
    local out = p:read("*a") or ""
    p:close()
    -- tput puede devolver el string con un newline final. Buscamos
    -- el prefijo ESC [ < para SGR.
    if out:find("\27[<", 1, true) then
        _cache = "sgr"
    else
        _cache = "x10"
    end
    return _cache
end

return M
