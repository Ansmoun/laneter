-- cdef para PTY via forkpty. En Linux (glibc) forkpty vive en
-- libutil. Solo declaramos lo que usamos.
--
-- En el hijo de forkpty heredamos todos los fd >= 3 del padre.
-- Hay que cerrarlos antes de execvp para no arrastrar el socket
-- X, cairo, etc. Ver lib/terminal/pty.lua.

local ffi = require("ffi")

ffi.cdef[[
typedef int pid_t;

pid_t forkpty(int *amaster, char *name, void *termp, struct winsize *winp);

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

int ioctl(int fd, unsigned long request, ...);
/* fcntl NO-variadico a proposito. Si se declara variadico, LuaJIT
   pasa los numeros Lua como double, y fcntl lee el 3er argumento
   como int de un registro distinto -> O_NONBLOCK nunca se aplica.
   Sintoma: read() bloquea el server. Ver pty.lua. */
int fcntl(int fd, int cmd, int arg);

pid_t waitpid(pid_t pid, int *status, int options);
int   kill(pid_t pid, int sig);
int   close(int fd);
long  read(int fd, void *buf, unsigned long count);
long  write(int fd, const void *buf, unsigned long count);
int   execvp(const char *file, char *const argv[]);

/* Dirent para iterar /proc/self/fd en el hijo. Linux x86_64. */
typedef struct __dirstream DIR;
struct dirent {
    uint64_t       d_ino;
    int64_t        d_off;
    unsigned short d_reclen;
    unsigned char  d_type;
    char           d_name[256];
};
DIR           *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int            closedir(DIR *dirp);

enum {
    TIOCSWINSZ  = 0x5414,
    TIOCGWINSZ  = 0x5413,
    WNOHANG     = 1,
    SIGHUP      = 1,
    SIGTERM     = 15,
    SIGKILL     = 9,
    F_GETFL     = 3,
    F_SETFL     = 4,
    O_NONBLOCK  = 0x800
};
]]

return ffi
