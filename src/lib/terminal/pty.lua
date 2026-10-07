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

-- Marca todos los fds >= min_fd con FD_CLOEXEC, EXCEPTO los que
-- estan en except (usualmente el master del PTY, que no queremos
-- cerrar en el execvp... aunque en realidad forkpty lo cierra en
-- el hijo de todas formas).
--
-- Corre en el PADRE antes del fork. La ventaja: el hijo no tiene
-- que tocar Lua ni el heap. El kernel se encarga de cerrar los
-- fds con CLOEXEC al ejecutar el execvp.
--
-- Por que hacemos esto: forkpty + LuaJIT es peligroso. Si el GC
-- del padre estaba corriendo en el momento del fork, el hijo
-- arranca con heap corrupto. Cualquier uso de FFI o Lua en el
-- hijo (como listar /proc/self/fd para cerrar) puede reventar.
-- Con FD_CLOEXEC el hijo hace solo execvp y listo.
local FD_CLOEXEC = 1
local F_GETFD = 1
local F_SETFD = 2

local function mark_fds_cloexec(min_fd, except)
    local dirp = libc.opendir("/proc/self/fd")
    if dirp == nil then return end
    local fds = {}
    while true do
        local ent = libc.readdir(dirp)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        local n = tonumber(name)
        if n and n >= min_fd and not (except and except[n]) then
            fds[#fds + 1] = n
        end
    end
    libc.closedir(dirp)
    for _, n in ipairs(fds) do
        local flags = libc.fcntl(n, F_GETFD, 0)
        if flags >= 0 then
            libc.fcntl(n, F_SETFD, bit.bor(flags, FD_CLOEXEC))
        end
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

    -- Marcar TODOS los fds abiertos (excepto stdin/out/err) con
    -- FD_CLOEXEC. El execvp del hijo los cierra automaticamente.
    -- El socket de X, signalfd, etc, no pasan al shell.
    --
    -- Esto reemplaza el close_fds_from que corria en el hijo. La
    -- diferencia clave: el hijo ya no toca Lua.
    mark_fds_cloexec(3)

    local master_p = ffi.new("int[1]")
    local ws = ffi.new("struct winsize")
    ws.ws_row = rows
    ws.ws_col = cols

    local pid = libc.forkpty(master_p, nil, nil, ws)

    if pid == 0 then
        -- Hijo. NO tocar Lua mas alla de esto (excepto el execvp).
        -- El heap Lua puede estar corrupto si el GC estaba
        -- corriendo en el padre durante el fork.
        --
        -- argv[0] = "-basename" para forzar modo login shell.
        -- Eso hace que sh lea /etc/profile y ~/.profile.
        local base  = shell:match("[^/]+$") or shell
        local login = "-" .. base
        local argv  = make_argv({ login })
        libc.execvp(shell, argv)

        -- execvp fallo. Usar _exit (syscall directa) para saltarse
        -- finalizers de LuaJIT en el hijo.
        ffi.C._exit(127)
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
