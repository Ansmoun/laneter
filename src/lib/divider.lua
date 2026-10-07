-- divider: linea separadora horizontal o vertical de 1px.

local Area  = require("lib.area")
local cairo = require("lib.cairo")

local M = {}

local Divider = setmetatable({}, { __index = Area })
Divider.__index = Divider

function Divider.new(theme)
    local self = setmetatable(Area.new({}), Divider)
    self.orientation = "horizontal"
    self.color = theme.separator_rgb or { 0.2, 0.2, 0.2 }
    self.min_h, self.max_h = 1, 1
    return self
end

function Divider.new_vertical(theme)
    local self = setmetatable(Area.new({}), Divider)
    self.orientation = "vertical"
    self.color = theme.separator_rgb or { 0.2, 0.2, 0.2 }
    self.min_w, self.max_w = 1, 1
    return self
end

function Divider:draw(cr)
    local c = self.color
    cairo.set_rgb(cr, c[1], c[2], c[3])
    if self.orientation == "vertical" then
        cairo.rectangle(cr, self.x0, self.y0, 1, self:getHeight())
    else
        cairo.rectangle(cr, self.x0, self.y0, self:getWidth(), 1)
    end
    cairo.fill(cr)
end

M.new = Divider.new
M.new_vertical = Divider.new_vertical

return M
