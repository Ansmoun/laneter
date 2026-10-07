-- menubar: dos modos de presentacion.
--
--   compact = false: fila horizontal de botones.
--   compact = true: un solo boton hamburguesa (☰) que despliega
--     los menus agrupados, con submenus para cada uno.
--
-- Adaptado de lane-files/tab/menubar.lua. Sin cambios de logica;
-- solo los require apuntan a LaneTK via LUA_PATH.

local Area  = require("lib.area")
local cairo = require("lib.cairo")
local pango = require("lib.pango")
local G     = require("lib.helpers.graphics")
local timer = require("lib.timer")

local M = {}

local FONT     = "DejaVu Sans 10"
local PAD_X    = 10
local BAR_H    = 26

-- ── Item del menubar (modo extendido) ──────────────────────
local MenuItem = setmetatable({}, { __index = Area })
MenuItem.__index = MenuItem

function MenuItem.new(theme, label, on_activate)
    local self = setmetatable(Area.new({}), MenuItem)
    self._hover_visual = true
    self.label = label
    self.theme = theme
    self.on_activate = on_activate
    self.is_open = false
    local tw = select(1, pango.measure(label, FONT))
    self.tw = tw
    self.min_w, self.max_w = tw + PAD_X * 2, tw + PAD_X * 2
    self.min_h, self.max_h = BAR_H, BAR_H
    return self
end

function MenuItem:set_open(v)
    v = v and true or false
    if self.is_open == v then return end
    self.is_open = v
    self:damage()
end

function MenuItem:draw(cr)
    local x, y = self.x0, self.y0
    local w, h = self:getWidth(), self:getHeight()
    local T = self.theme

    if self.is_open then
        local r, g, b = G.hex_to_rgba(T.accent or "#8ec07c")
        cairo.set_rgba(cr, r, g, b, 0.30)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
    elseif self.hover then
        local r, g, b = G.hex_to_rgba(T.bg_focus or "#3c3836")
        cairo.set_rgba(cr, r, g, b, 0.55)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
    end

    local fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
    local _, lh = pango.measure(self.label, FONT)
    pango.draw_text(cr, x + PAD_X, y + (h - lh) / 2,
        self.label, FONT,
        { r = fg[1], g = fg[2], b = fg[3] })
end

function MenuItem:on_mouse_press(mx, my, button)
    if button == 1 and self.on_activate then
        self.on_activate(self)
    end
end

-- ── Boton hamburguesa ───────────────────────────────────────
local HamburgerButton = setmetatable({}, { __index = Area })
HamburgerButton.__index = HamburgerButton

function HamburgerButton.new(theme, on_activate)
    local self = setmetatable(Area.new({}), HamburgerButton)
    self._hover_visual = true
    self.theme = theme
    self.on_activate = on_activate
    self.is_open = false
    self.min_w, self.max_w = 34, 34
    self.min_h, self.max_h = BAR_H, BAR_H
    return self
end

function HamburgerButton:set_open(v)
    v = v and true or false
    if self.is_open == v then return end
    self.is_open = v
    self:damage()
end

function HamburgerButton:draw(cr)
    local x, y = self.x0, self.y0
    local w, h = self:getWidth(), self:getHeight()
    local T = self.theme

    if self.is_open then
        local r, g, b = G.hex_to_rgba(T.accent or "#8ec07c")
        cairo.set_rgba(cr, r, g, b, 0.30)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
    elseif self.hover then
        local r, g, b = G.hex_to_rgba(T.bg_focus or "#3c3836")
        cairo.set_rgba(cr, r, g, b, 0.55)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
    end

    local fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
    cairo.set_rgb(cr, fg[1], fg[2], fg[3])
    cairo.set_line_width(cr, 1.6)
    local cx = x + w / 2
    local cy = y + h / 2
    local d = 7
    local gap = 4
    cairo.move_to(cr, cx - d, cy - gap)
    cairo.line_to(cr, cx + d, cy - gap)
    cairo.move_to(cr, cx - d, cy)
    cairo.line_to(cr, cx + d, cy)
    cairo.move_to(cr, cx - d, cy + gap)
    cairo.line_to(cr, cx + d, cy + gap)
    cairo.stroke(cr)
end

function HamburgerButton:on_mouse_press(mx, my, button)
    if button == 1 and self.on_activate then
        self.on_activate(self)
    end
end

-- ── Menubar ─────────────────────────────────────────────────
local Menubar = setmetatable({}, { __index = Area })
Menubar.__index = Menubar

function Menubar.new(theme, menus, open_menu, close_menus, opts)
    opts = opts or {}
    local self = setmetatable(Area.new({}), Menubar)
    self.theme = theme
    self.menus = menus
    self.open_menu_cb = open_menu
    self.close_menus_cb = close_menus
    self.compact = opts.compact and true or false
    self.items = {}
    self.current_open = nil
    self._last_close_at = nil
    self.min_h, self.max_h = BAR_H, BAR_H
    self.min_w, self.max_w = 0, 10000

    if self.compact then
        self.hamburger = HamburgerButton.new(theme, function(anchor)
            self:_activate_compact(anchor)
        end)
        self.min_w = self.hamburger.min_w
        self.max_w = self.hamburger.min_w
    else
        for _, menu in ipairs(menus) do
            local item = MenuItem.new(theme, menu.label, function(anchor)
                self:_activate(menu, anchor)
            end)
            item.menu_spec = menu
            self.items[#self.items + 1] = item
        end
    end
    return self
end

function Menubar:_build_tree()
    local out = {}
    for _, menu in ipairs(self.menus) do
        local subitems = menu.build and menu.build() or {}
        out[#out + 1] = {
            label = menu.label,
            submenu = subitems,
        }
    end
    return out
end

function Menubar:_activate(menu, anchor)
    if self.current_open and self.current_open ~= anchor then
        self.current_open:set_open(false)
    end
    if self.close_menus_cb then self.close_menus_cb() end
    local items = menu.build and menu.build() or {}
    self.current_open = anchor
    anchor:set_open(true)
    if self.open_menu_cb then
        self.open_menu_cb(anchor, items, function()
            anchor:set_open(false)
            if self.current_open == anchor then
                self.current_open = nil
            end
        end)
    end
end

function Menubar:_activate_compact(anchor)
    local now = timer.now_ms()
    if self._last_close_at
       and (now - self._last_close_at) < 300 then
        return
    end

    if self.close_menus_cb then self.close_menus_cb() end
    local items = self:_build_tree()
    self.current_open = anchor
    anchor:set_open(true)
    if self.open_menu_cb then
        self.open_menu_cb(anchor, items, function()
            anchor:set_open(false)
            self._last_close_at = timer.now_ms()
            if self.current_open == anchor then
                self.current_open = nil
            end
        end)
    end
end

function Menubar:close_all()
    if self.current_open then
        self.current_open:set_open(false)
        self.current_open = nil
    end
end

function Menubar:set_window(win)
    self.window = win
    if self.compact then
        self.hamburger.window = win
    else
        for _, it in ipairs(self.items) do it.window = win end
    end
end

function Menubar:askMinMax(minw, minh, maxw, maxh)
    if self.compact then
        local w = self.hamburger.min_w
        return minw + w, minh + BAR_H, maxw + w, maxh + BAR_H
    end
    local total_w = 0
    for _, it in ipairs(self.items) do
        total_w = total_w + it.min_w
    end
    return minw + total_w, minh + BAR_H, maxw + total_w, maxh + BAR_H
end

function Menubar:layout(x0, y0, x1, y1)
    Area.layout(self, x0, y0, x1, y1)
    if self.compact then
        self.hamburger:layout(x0, y0, x0 + self.hamburger.min_w, y0 + BAR_H)
        return
    end
    local x = x0
    for _, it in ipairs(self.items) do
        it:layout(x, y0, x + it.min_w, y0 + BAR_H)
        x = x + it.min_w
    end
end

function Menubar:draw(cr)
    if self.compact then
        self.hamburger:draw(cr)
        return
    end
    for _, it in ipairs(self.items) do
        it:draw(cr)
    end
end

function Menubar:getByXY(x, y)
    if x < self.x0 or x >= self.x1 or y < self.y0 or y >= self.y1 then
        return nil
    end
    if self.compact then
        return self.hamburger:getByXY(x, y) or self
    end
    for _, it in ipairs(self.items) do
        local hit = it:getByXY(x, y)
        if hit then return hit end
    end
    return self
end

M.new = function(theme, menus, open_menu, close_menus, opts)
    return Menubar.new(theme, menus, open_menu, close_menus, opts)
end

return M
