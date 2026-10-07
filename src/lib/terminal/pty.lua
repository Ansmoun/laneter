-- pty.lua: abre un PTY con forkpty y ejecuta un shell.
--
-- IMPORTANTE: forkpty() forkea el proceso ENTERO, incluyendo la
-- conexion X, los fd de cairo/pango, etc. En el hijo hay que
-- cerrar todo fd >= 3 antes de execvp, si no el shell hereda el
-- socket X y otros recursos, con efectos colaterales raros
-- (por ejemplo, el socket queda abierto hasta que el shell muere).
--
-- API:
--   M.spawn(shell, cols, rows) -> { fd, pid, cols, rows } | nil, err
--   M.read(fd, max_bytes)      -> string | nil (nil = EOF)
--   M.write(fd, str)           -> bytes | nil, err
--   M.resize(fd, cols, rows)   -> true | false
--   M.is_alive(pid)            -> bool
--   M.kill(pid)                -> void
--   M.close(fd)                -> void

local ffi  = require("bindings.cdef.pty")
local libc = ffi.load("c")

local M = {}

-- Cierra todo fd >= min_fd en el proceso actual. Usa readdir
-- sobre /proc/self/fd para listarlos. Debe llamarse en el hijo
-- tras forkpty.
local function close_fds_from(min_fd)
    local dirp = libc.opendir("/proc/self/fd")
    if dirp == nil then
        -- Fallback: barrido ciego hasta 256.
        for i = min_fd, 256 do pcall(libc.close, i) end
        return
    end
    -- Lista de fds a cerrar (no cerrar el DIR* mientras iteramos).
    local fds = {}
    while true do
        local ent = libc.readdir(dirp)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        local n = tonumber(name)
        if n and n >= min_fd then
            fds[#fds + 1] = n
        end
    end
    libc.closedir(dirp)
    for _, n in ipairs(fds) do
        pcall(libc.close, n)
    end
end

-- Construye un argv C array terminado en NULL. Las strings deben
-- seguir vivas mientras execvp las use (el caller las retiene).
local function make_argv(strs)
    local argv = ffi.new("char *[?]", #strs + 1)
    for i, s in ipairs(strs) do
        argv[i - 1] = ffi.cast("char *", s)
    end
    argv[#strs] = nil
    return argv
end

function M.spawn(shell, cols, rows)
    cols  = cols  or 80
    rows  = rows  or 24
    shell = shell or os.getenv("SHELL") or "/bin/sh"

    local master_p = ffi.new("int[1]")
    local ws = ffi.new("struct winsize")
    ws.ws_row = rows
    ws.ws_col = cols

    local pid = libc.forkpty(master_p, nil, nil, ws)

    if pid == 0 then
        -- Hijo. Cerrar fds >= 3 (0/1/2 ya son el slave del PTY).
        close_fds_from(3)

        -- argv[0] = "-basename" para forzar modo login shell.
        -- Eso hace que sh lea /etc/profile y ~/.profile.
        local base  = shell:match("[^/]+$") or shell
        local login = "-" .. base
        local argv  = make_argv({ login })
        libc.execvp(shell, argv)

        -- execvp fallo: salir con 127.
        os.exit(127)
    end

    if pid < 0 then
        return nil, "forkpty fallo"
    end

    local fd = master_p[0]

    -- Reaplicar winsize por las dudas (forkpty ya lo hizo, pero
    -- algunos shells lo pisan al primer SIGWINCH).
    libc.ioctl(fd, 0x5414, ws)  -- TIOCSWINSZ

    -- Modo no bloqueante en el master. Sin esto, read() bloquea
    -- cuando el shell no tiene nada que decir. El loop del server
    -- queda pegado dentro del callback del fd, no procesa XCB ni
    -- teclas ni redibuja, y la ventana se ve inerte hasta que un
    -- SIGINT interrumpe el read.
    local flags = libc.fcntl(fd, 3, 0)  -- F_GETFL
    if flags < 0 then
        return nil, "fcntl(F_GETFL) fallo"
    end
    if libc.fcntl(fd, 4, bit.bor(flags, 0x800)) < 0 then  -- F_SETFL, O_NONBLOCK
        return nil, "fcntl(F_SETFL, O_NONBLOCK) fallo"
    end

    -- Verificacion defensiva. Si O_NONBLOCK no quedo aplicado, es
    -- un bug grave: lo hacemos explicito en el log.
    local verify = libc.fcntl(fd, 3, 0)
    if bit.band(verify, 0x800) == 0 then
        io.stderr:write(string.format(
            "[pty WARN] O_NONBLOCK no aplicado en fd=%d (flags=0x%x)\n",
            fd, verify))
    end

    return { fd = fd, pid = pid, cols = cols, rows = rows }
end

function M.read(fd, max_bytes)
    max_bytes = max_bytes or 4096
    local buf = ffi.new("char[?]", max_bytes)
    local n = libc.read(fd, buf, max_bytes)
    if n < 0 then
        local errno = ffi.errno()
        -- EAGAIN/EWOULDBLOCK: sin datos ahora, no es error.
        if errno == 11 or errno == 35 then return "" end
        -- Error real: devolvemos nil para que el caller cierre.
        return nil, "read errno=" .. errno
    end
    if n == 0 then
        return nil
    end
    return ffi.string(buf, n)
end

function M.write(fd, str)
    local n = libc.write(fd, str, #str)
    if n < 0 then return nil, "write fallo" end
    return tonumber(n)
end

function M.resize(fd, cols, rows)
    local ws = ffi.new("struct winsize")
    ws.ws_row = rows
    ws.ws_col = cols
    return libc.ioctl(fd, 0x5414, ws) == 0
end

function M.is_alive(pid)
    local status = ffi.new("int[1]")
    local r = libc.waitpid(pid, status, 1)  -- WNOHANG
    return r == 0
end

function M.kill(pid)
    libc.kill(pid, 1)  -- SIGHUP
end

function M.close(fd)
    if fd and fd >= 0 then
        pcall(libc.close, fd)
    end
end

return M
