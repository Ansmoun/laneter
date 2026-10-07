-- cdef para libvterm 0.3.3 (libvterm.so.0).
-- Emulador VT220/xterm/ECMA-48. Usado por Neovim.
--
-- Layout de structs calcado de /usr/include/vterm.h v0.3.3.
-- VTermScreenCellAttrs son bitfields de C: en x86_64 Linux quedan
-- empaquetados en un solo unsigned int. Los exponemos como bits
-- crudos y ofrecemos las mascaras desde Lua.

local ffi = require("ffi")

ffi.cdef[[
typedef struct VTerm       VTerm;
typedef struct VTermState  VTermState;
typedef struct VTermScreen VTermScreen;

typedef struct {
    int row;
    int col;
} VTermPos;

typedef struct {
    int start_row;
    int end_row;
    int start_col;
    int end_col;
} VTermRect;

/* Tagged union. type & 0x01 = 0 -> RGB, = 1 -> indexed.
   0x02 = default_fg, 0x04 = default_bg. */
typedef union {
    uint8_t type;
    struct {
        uint8_t type;
        uint8_t red, green, blue;
    } rgb;
    struct {
        uint8_t type;
        uint8_t idx;
    } indexed;
} VTermColor;

/* Bitfields empaquetados en un unsigned int. Bits (LSB first):
   0 bold, 1-2 underline, 3 italic, 4 blink, 5 reverse, 6 conceal,
   7 strike, 8-11 font, 12 dwl, 13-14 dhl, 15 small, 16-17 baseline. */
typedef struct {
    unsigned int bits;
} VTermScreenCellAttrs;

typedef struct {
    uint32_t            chars[6];
    char                width;
    VTermScreenCellAttrs attrs;
    VTermColor          fg;
    VTermColor          bg;
} VTermScreenCell;

typedef struct {
    int (*damage)(VTermRect rect, void *user);
    int (*moverect)(VTermRect dest, VTermRect src, void *user);
    int (*movecursor)(VTermPos pos, VTermPos oldpos, int visible, void *user);
    int (*settermprop)(int prop, void *val, void *user);
    int (*bell)(void *user);
    int (*resize)(int rows, int cols, void *user);
    int (*sb_pushline)(int cols, const VTermScreenCell *cells, void *user);
    int (*sb_popline)(int cols, VTermScreenCell *cells, void *user);
    int (*sb_clear)(void *user);
} VTermScreenCallbacks;

enum {
    VTERM_COLOR_RGB          = 0x00,
    VTERM_COLOR_INDEXED      = 0x01,
    VTERM_COLOR_TYPE_MASK    = 0x01,
    VTERM_COLOR_DEFAULT_FG   = 0x02,
    VTERM_COLOR_DEFAULT_BG   = 0x04,
    VTERM_COLOR_DEFAULT_MASK = 0x06
};

enum {
    VTERM_DAMAGE_CELL   = 0,
    VTERM_DAMAGE_ROW    = 1,
    VTERM_DAMAGE_SCREEN = 2,
    VTERM_DAMAGE_SCROLL = 3
};

enum {
    VTERM_KEY_NONE = 0,
    VTERM_KEY_ENTER,
    VTERM_KEY_TAB,
    VTERM_KEY_BACKSPACE,
    VTERM_KEY_ESCAPE,
    VTERM_KEY_UP,
    VTERM_KEY_DOWN,
    VTERM_KEY_LEFT,
    VTERM_KEY_RIGHT,
    VTERM_KEY_INS,
    VTERM_KEY_DEL,
    VTERM_KEY_HOME,
    VTERM_KEY_END,
    VTERM_KEY_PAGEUP,
    VTERM_KEY_PAGEDOWN,
    VTERM_KEY_FUNCTION_0 = 256
};

enum {
    VTERM_MOD_NONE  = 0x00,
    VTERM_MOD_SHIFT = 0x01,
    VTERM_MOD_ALT   = 0x02,
    VTERM_MOD_CTRL  = 0x04,
    VTERM_ALL_MODS_MASK = 0x07
};

VTerm      *vterm_new(int rows, int cols);
void        vterm_free(VTerm *vt);
void        vterm_set_size(VTerm *vt, int rows, int cols);
void        vterm_get_size(const VTerm *vt, int *rowsp, int *colsp);
void        vterm_set_utf8(VTerm *vt, int is_utf8);
size_t      vterm_input_write(VTerm *vt, const char *bytes, size_t len);

void        vterm_keyboard_key(VTerm *vt, int key, int mod);
void        vterm_keyboard_unichar(VTerm *vt, uint32_t c, int mod);

void        vterm_output_set_callback(VTerm *vt,
                void (*func)(const char *s, size_t len, void *user),
                void *user);
size_t      vterm_output_read(VTerm *vt, char *buffer, size_t len);

VTermState  *vterm_obtain_state(VTerm *vt);
VTermScreen *vterm_obtain_screen(VTerm *vt);

void        vterm_state_get_cursorpos(const VTermState *state,
                VTermPos *cursorpos);
void        vterm_state_set_default_colors(VTermState *state,
                const VTermColor *fg, const VTermColor *bg);
void        vterm_state_set_palette_color(VTermState *state, int index,
                const VTermColor *col);
void        vterm_state_convert_color_to_rgb(const VTermState *state,
                VTermColor *col);
void        vterm_state_reset(VTermState *state, int hard);
void        vterm_state_focus_in(VTermState *state);
void        vterm_state_focus_out(VTermState *state);

void        vterm_screen_set_callbacks(VTermScreen *screen,
                const VTermScreenCallbacks *callbacks, void *user);
void        vterm_screen_enable_altscreen(VTermScreen *screen, int altscreen);
void        vterm_screen_enable_reflow(VTermScreen *screen, int reflow);
void        vterm_screen_set_damage_merge(VTermScreen *screen, int size);
void        vterm_screen_reset(VTermScreen *screen, int hard);
int         vterm_screen_get_cell(const VTermScreen *screen, VTermPos pos,
                VTermScreenCell *cell);
int         vterm_screen_is_eol(const VTermScreen *screen, VTermPos pos);
size_t      vterm_screen_get_text(const VTermScreen *screen, char *str,
                size_t len, const VTermRect rect);
void        vterm_screen_set_default_colors(VTermScreen *screen,
                const VTermColor *fg, const VTermColor *bg);
void        vterm_screen_convert_color_to_rgb(const VTermScreen *screen,
                VTermColor *col);
void        vterm_screen_flush_damage(VTermScreen *screen);
]]

return ffi
