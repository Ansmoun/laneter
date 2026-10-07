-- tabs_bar: barra horizontal de pestañas con scroll.
-- Adaptado de lane-files/tab/tabs_bar.lua.
--
-- Cada pestaña es un botón con nombre. El activo se marca con
-- línea inferior de acento. Botón "×" para cerrar (visible en
-- hover). Botón "+" fijo al extremo derecho.
--
-- Cuando las tabs no caben en el ancho disponible, la barra
-- scrollea horizontalmente (rueda del mouse). Al cambiar la tab
-- activa, el offset se ajusta para mostrar la activa.

local Area  = require("lib.area")
local cairo = require("lib.cairo")
local pango = require("lib.pango")
local G     = require("lib.helpers.graphics")

local M = {}

local BAR_H      = 26
local PAD_X      = 10
local GAP        = 2
local CLOSE_SIZE = 14
local NEW_BTN_W  = 30
local WHEEL_STEP = 80

-- ── TabButton ───────────────────────────────────────────────
local TabButton = setmetatable({}, { __index = Area })
TabButton.__index = TabButton

function TabButton.new(theme, id, name, on_select, on_close, parent_bar)
    local self = setmetatable(Area.new({}), TabButton)
    self._hover_visual = true
    self.id = id
    self.name = name
    self.theme = theme
    self.on_select = on_select
    self.on_close = on_close
    self.parent_bar = parent_bar
    self.is_active = false
    self.close_hover = false
    self:_recalc_width()
    self.min_h, self.max_h = BAR_H, BAR_H
    return self
end

local MAX_NAME_CHARS = 22

function TabButton:_recalc_width()
    local name = self.name or ""
    if #name > MAX_NAME_CHARS then
        name = name:sub(1, MAX_NAME_CHARS - 1) .. "\u{2026}"
    end
    self._display_name = name
    local tw = select(1, pango.measure(name, "DejaVu Sans 10"))
    self.tw = tw
    local w = PAD_X + tw + 8 + CLOSE_SIZE + PAD_X
    self.min_w, self.max_w = w, w
end

function TabButton:set_name(name)
    if self.name == name then return end
    self.name = name
    self:_recalc_width()
    self:damage()
end

function TabButton:set_active(v)
    v = v and true or false
    if self.is_active == v then return end
    self.is_active = v
    self:damage()
end

function TabButton:_close_hit(mx)
    local w = self:getWidth()
    local cx = w - PAD_X - CLOSE_SIZE
    return mx >= cx
end

function TabButton:on_mouse_move(mx, my)
    local ch = self:_close_hit(mx)
    if ch ~= self.close_hover then
        self.close_hover = ch
        self:damage()
    end
end

function TabButton:draw(cr)
    local x, y = self.x0, self.y0
    local w, h = self:getWidth(), self:getHeight()
    local T = self.theme

    if self.is_active then
        local r, g, b = G.hex_to_rgba(T.bg_card or "#282828")
        cairo.set_rgb(cr, r, g, b)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
        local ar, ag, ab = G.hex_to_rgba(T.accent or "#8ec07c")
        cairo.set_rgb(cr, ar, ag, ab)
        cairo.rectangle(cr, x, y + h - 2, w, 2)
        cairo.fill(cr)
    elseif self.hover then
        local r, g, b = G.hex_to_rgba(T.bg_focus or "#3c3836")
        cairo.set_rgba(cr, r, g, b, 0.55)
        cairo.rectangle(cr, x, y, w, h)
        cairo.fill(cr)
    end

    local fg
    if self.is_active then
        fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
    else
        fg = T.muted_rgb or { 0.5, 0.5, 0.5 }
    end
    local dn = self._display_name or self.name or ""
    local _, lh = pango.measure(dn, "DejaVu Sans 10")
    pango.draw_text(cr, x + PAD_X, y + (h - lh) / 2,
        dn, "DejaVu Sans 10",
        { r = fg[1], g = fg[2], b = fg[3] })

    if self.hover or self.is_active then
        local cx = x + w - PAD_X - CLOSE_SIZE / 2
        local cy = y + h / 2
        local r2 = CLOSE_SIZE / 2
        if self.close_hover then
            local hr, hg, hb = G.hex_to_rgba(T.urgent or "#cc241d")
            cairo.set_rgba(cr, hr, hg, hb, 0.3)
            cairo.new_sub_path(cr)
            cairo.arc(cr, cx, cy, r2, 0, 2 * math.pi)
            cairo.fill(cr)
        end
        local cc
        if self.close_hover then
            cc = T.fg_rgb or { 1, 1, 1 }
        else
            cc = T.muted_rgb or { 0.5, 0.5, 0.5 }
        end
        cairo.set_rgb(cr, cc[1], cc[2], cc[3])
        cairo.set_line_width(cr, 1.4)
        local d = r2 * 0.45
        cairo.move_to(cr, cx - d, cy - d)
        cairo.line_to(cr, cx + d, cy + d)
        cairo.stroke(cr)
        cairo.new_sub_path(cr)
        cairo.move_to(cr, cx + d, cy - d)
        cairo.line_to(cr, cx - d, cy + d)
        cairo.stroke(cr)
    end
end

function TabButton:on_mouse_press(mx, my, button)
    if button ~= 1 then return end
    if self:_close_hit(mx) then
        if self.on_close then self.on_close(self.id) end
    else
        if self.on_select then self.on_select(self.id) end
    end
end

function TabButton:on_wheel(direction)
    if self.parent_bar then
        self.parent_bar:on_wheel(direction)
    end
end

-- ── TabsBar ─────────────────────────────────────────────────
local TabsBar = setmetatable({}, { __index = Area })
TabsBar.__index = TabsBar

function TabsBar.new(theme, callbacks)
    local self = setmetatable(Area.new({}), TabsBar)
    self.theme = theme
    self.callbacks = callbacks or {}
    self.tabs = {}
    self.by_id = {}
    self.active_id = nil
    self.min_h, self.max_h = BAR_H, BAR_H
    self.min_w, self.max_w = 60, 10000
    self._new_btn_hover = false
    self._scroll_x   = 0
    self._content_w  = 0
    self._visible_w  = 0
    self._scroll_max = 0
    return self
end

function TabsBar:set_tabs(list, active_id)
    local cbs = self.callbacks
    local new_by_id = {}
    local new_tabs = {}

    for _, t in ipairs(list) do
        local btn = self.by_id[t.id]
        if btn then
            btn:set_name(t.name)
        else
            btn = TabButton.new(self.theme, t.id, t.name,
                cbs.on_select, cbs.on_close, self)
            btn.window = self.window
        end
        btn:set_active(t.id == active_id)
        new_tabs[#new_tabs + 1] = btn
        new_by_id[t.id] = btn
    end

    self.tabs = new_tabs
    self.by_id = new_by_id
    self.active_id = active_id

    self:_recalc_content()
    self:_ensure_active_visible()

    self:invalidate_layout()
    self:damage()
end

function TabsBar:_recalc_content()
    local total = 0
    for i, btn in ipairs(self.tabs) do
        total = total + btn.min_w
        if i < #self.tabs then total = total + GAP end
    end
    self._content_w = total
end

function TabsBar:_clamp_scroll()
    local visible = self:getWidth() - NEW_BTN_W
    if visible < 0 then visible = 0 end
    self._visible_w = visible
    local max = self._content_w - visible
    if max < 0 then max = 0 end
    self._scroll_max = max
    if self._scroll_x > max then self._scroll_x = max end
    if self._scroll_x < 0 then self._scroll_x = 0 end
end

function TabsBar:_ensure_active_visible()
    if not self.active_id then return end
    local idx
    for i, btn in ipairs(self.tabs) do
        if btn.id == self.active_id then idx = i; break end
    end
    if not idx then return end

    local x = 0
    for i = 1, idx - 1 do
        x = x + self.tabs[i].min_w + GAP
    end
    local w = self.tabs[idx].min_w

    local sx = self._scroll_x
    local vw = self._visible_w
    if x < sx then
        self._scroll_x = x - 4
    elseif x + w > sx + vw then
        self._scroll_x = x + w - vw + 4
    end
    self:_clamp_scroll()
end

function TabsBar:_hit_new(mx)
    local bx = self._new_btn_x
    if not bx then return false end
    return mx >= bx and mx < bx + NEW_BTN_W
end

function TabsBar:askMinMax(minw, minh, maxw, maxh)
    return minw + self.min_w, minh + BAR_H,
           maxw + 10000, maxh + BAR_H
end

function TabsBar:set_window(win)
    self.window = win
    for _, btn in ipairs(self.tabs) do
        btn.window = win
    end
end

function TabsBar:layout(x0, y0, x1, y1)
    Area.layout(self, x0, y0, x1, y1)

    self:_recalc_content()
    self:_clamp_scroll()
    self:_ensure_active_visible()

    local x = x0 - self._scroll_x
    for _, btn in ipairs(self.tabs) do
        btn:layout(x, y0, x + btn.min_w, y0 + BAR_H)
        x = x + btn.min_w + GAP
    end

    self._new_btn_x = self:getWidth() - NEW_BTN_W
end

function TabsBar:draw(cr)
    local T = self.theme
    local bg = T.bg_rgb or { 0.1, 0.1, 0.1 }
    cairo.set_rgb(cr, bg[1], bg[2], bg[3])
    cairo.rectangle(cr, self.x0, self.y0,
        self:getWidth(), self:getHeight())
    cairo.fill(cr)

    local vis_w = self:getWidth() - NEW_BTN_W
    if vis_w < 0 then vis_w = 0 end
    cairo.save(cr)
    cairo.rectangle(cr, self.x0, self.y0, vis_w, self:getHeight())
    cairo.clip(cr)
    for _, btn in ipairs(self.tabs) do
        btn:draw(cr)
    end
    cairo.restore(cr)

    local bx = self.x0 + self._new_btn_x
    local by = self.y0
    cairo.set_rgb(cr, bg[1], bg[2], bg[3])
    cairo.rectangle(cr, bx, by, NEW_BTN_W, BAR_H)
    cairo.fill(cr)

    if self._new_btn_hover then
        local r, g, b = G.hex_to_rgba(T.bg_focus or "#3c3836")
        cairo.set_rgba(cr, r, g, b, 0.55)
        cairo.rectangle(cr, bx, by, NEW_BTN_W, BAR_H)
        cairo.fill(cr)
    end
    local cc = T.fg_rgb or { 0.9, 0.9, 0.9 }
    cairo.set_rgb(cr, cc[1], cc[2], cc[3])
    cairo.set_line_width(cr, 1.6)
    local cx = bx + NEW_BTN_W / 2
    local cy = by + BAR_H / 2
    local d = 5
    cairo.move_to(cr, cx - d, cy)
    cairo.line_to(cr, cx + d, cy)
    cairo.move_to(cr, cx, cy - d)
    cairo.line_to(cr, cx, cy + d)
    cairo.stroke(cr)
end

function TabsBar:getByXY(x, y)
    if x < self.x0 or x >= self.x1 or y < self.y0 or y >= self.y1 then
        return nil
    end
    if self:_hit_new(x - self.x0) then
        return self
    end
    for _, btn in ipairs(self.tabs) do
        local hit = btn:getByXY(x, y)
        if hit then return hit end
    end
    return self
end

function TabsBar:on_mouse_move(mx, my)
    local nh = self:_hit_new(mx)
    if nh ~= self._new_btn_hover then
        self._new_btn_hover = nh
        self:damage()
    end
end

function TabsBar:set_hover(v)
    Area.set_hover(self, v)
    if not v and self._new_btn_hover then
        self._new_btn_hover = false
        self:damage()
    end
end

function TabsBar:on_mouse_press(mx, my, button)
    if button ~= 1 then return end
    if self:_hit_new(mx) then
        if self.callbacks.on_new then self.callbacks.on_new() end
    end
end

function TabsBar:on_wheel(direction)
    if self._scroll_max <= 0 then return end
    local delta = (direction == 4) and -WHEEL_STEP or WHEEL_STEP
    self._scroll_x = self._scroll_x + delta
    self:_clamp_scroll()
    self:invalidate_layout()
    self:damage()
end

M.new = function(theme, callbacks)
    return TabsBar.new(theme, callbacks)
end

return M
