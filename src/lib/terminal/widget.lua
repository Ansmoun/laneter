-- widget.lua: widget Area que integra PTY + vterm + render.

local Area   = require("lib.area")
local cairo  = require("lib.cairo")
local log    = require("lib.log")
local pty    = require("lib.terminal.pty")
local vterm  = require("lib.terminal.vterm")
local render = require("lib.terminal.render")
local keys   = require("lib.terminal.keys")

local M = {}

local Terminal = setmetatable({}, { __index = Area })
Terminal.__index = Terminal

local DEFAULT_FG = { 220, 220, 220 }
local DEFAULT_BG = { 20, 20, 24 }

local function fill_bg(cr, x, y, w, h, bg)
    cairo.set_rgb(cr, bg[1] / 255, bg[2] / 255, bg[3] / 255)
    cairo.rectangle(cr, x, y, w, h)
    cairo.fill(cr)
end

function M.new(opts)
    opts = opts or {}
    local self = setmetatable(Area.new({}), Terminal)

    self.opts = opts
    self.shell = opts.shell or os.getenv("SHELL") or "/bin/sh"
    self.renderer = render.new(opts.font)
    self.cols = 80
    self.rows = 24

    self.term = vterm.new(self.cols, self.rows)
    assert(self.term, "vterm.new fallo")

    local h, err = pty.spawn(self.shell, self.cols, self.rows)
    assert(h, err or "pty.spawn fallo")
    self.pty = h
    log.info("terminal", "PTY abierto: pid=%d fd=%d", h.pid, h.fd)

    local T = opts.theme or {}
    self.default_fg = T.fg_rgb
        and { T.fg_rgb[1]*255, T.fg_rgb[2]*255, T.fg_rgb[3]*255 }
        or DEFAULT_FG
    self.default_bg = T.bg_rgb
        and { T.bg_rgb[1]*255, T.bg_rgb[2]*255, T.bg_rgb[3]*255 }
        or DEFAULT_BG

    self.min_w, self.max_w = 100, 10000
    self.min_h, self.max_h = 50, 10000
    return self
end

function Terminal:set_window(win)
    if Area.set_window then
        Area.set_window(self, win)
    end
    self.window = win
    self.server = win.server
    log.info("terminal", "set_window llamado. server=%s fd=%d",
        tostring(win.server ~= nil), self.pty.fd)
    win.server:add_fd(self.pty.fd, function() self:_on_pty_readable() end)
end

function Terminal:_on_pty_readable()
    local n_total = 0
    while true do
        local chunk = pty.read(self.pty.fd, 4096)
        if chunk == nil then
            log.info("terminal", "PTY EOF")
            if self.window then self.window:close("shell exit") end
            return
        end
        if chunk == "" then break end
        n_total = n_total + #chunk
        self.term:feed(chunk)
    end
    if n_total > 0 then
        log.info("terminal", "pty leyo %d bytes", n_total)
    end
    self:damage()
    if self.window then self.window:damage_all() end
end

function Terminal:askMinMax(minw, minh, maxw, maxh)
    return minw + self.min_w, minh + self.min_h,
           maxw + 10000, maxh + 10000
end

function Terminal:layout(x0, y0, x1, y1)
    Area.layout(self, x0, y0, x1, y1)
    local avail_w = x1 - x0
    local avail_h = y1 - y0
    local cw, ch = self.renderer:cell_size()
    local new_cols = math.floor(avail_w / cw)
    local new_rows = math.floor(avail_h / ch)
    if new_cols < 1 then new_cols = 1 end
    if new_rows < 1 then new_rows = 1 end
    log.info("terminal", "layout %dx%d, cw=%d ch=%d, cols=%d rows=%d",
        avail_w, avail_h, cw, ch, new_cols, new_rows)
    if new_cols ~= self.cols or new_rows ~= self.rows then
        self.cols = new_cols
        self.rows = new_rows
        self.term:resize(new_cols, new_rows)
        pty.resize(self.pty.fd, new_cols, new_rows)
        self:damage()
    end
end

function Terminal:draw(cr)
    fill_bg(cr, self.x0, self.y0, self:getWidth(), self:getHeight(),
        self.default_bg)

    local cursor = self.term:cursor()
    local cursor_vis = {
        row = cursor.row, col = cursor.col,
        visible = true,
    }

    self.renderer:draw(cr, self.term,
        self.x0, self.y0, self.cols, self.rows,
        cursor_vis,
        self.default_fg, self.default_bg)
end

function Terminal:on_key(key)
    if not key or not key.pressed then return false end
    local tr = keys.translate(key)
    if not tr then return false end
    local bytes
    if tr.type == "key" then
        bytes = self.term:key(tr.code, tr.mods)
    else
        bytes = self.term:unichar(tr.cp, tr.mods)
    end
    if bytes and #bytes > 0 then
        log.info("terminal", "key '%s' -> %d bytes",
            tostring(key.name), #bytes)
        pty.write(self.pty.fd, bytes)
    end
    return true
end

function Terminal:destroy()
    if self.pty then
        pty.kill(self.pty.pid)
        pty.close(self.pty.fd)
        self.pty = nil
    end
    if self.term then
        self.term:free()
        self.term = nil
    end
end

return M
