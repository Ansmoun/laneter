-- render.lua: dibuja una grilla de celdas de libvterm con cairo+pango.
--
-- Estrategia F1 (naive): celda por celda, fondo opcional + texto.
-- pango cachea internamente los PangoLayouts por (texto, font),
-- asi que la mayoria de los draw_text son rapidos.
--
-- Optimizacion futura (F4): agrupar runs horizontales con el mismo
-- fondo en un solo rectangle; cachear surfaces por celda.
--
-- API:
--   M.new(font) -> renderer
--   renderer:cell_size()      -> w, h
--   renderer:draw(cr, term, x0, y0, cols, rows, cursor, default_fg, default_bg)

local cairo = require("lib.cairo")
local pango = require("lib.pango")

local M = {}

local Renderer = {}
Renderer.__index = Renderer

function M.new(font)
    font = font or "DejaVu Sans Mono 11"
    local w, h = pango.measure("M", font)
    local self = setmetatable({
        font = font,
        cell_w = math.floor(w + 0.5),
        cell_h = math.floor(h + 0.5),
    }, Renderer)
    return self
end

function Renderer:cell_size()
    return self.cell_w, self.cell_h
end

-- Convierte un color de vterm ({r,g,b} 0-255) a float 0-1.
local function to_float(c)
    return c[1] / 255, c[2] / 255, c[3] / 255
end

-- Aplica swap fg/bg si la celda tiene el atributo reverse.
local function effective_colors(cell, default_fg, default_bg)
    local fg = cell.fg or default_fg
    local bg = cell.bg or default_bg
    if cell.attrs.reverse then
        fg, bg = bg, fg
    end
    return fg, bg
end

function Renderer:draw(cr, term, x0, y0, cols, rows, cursor,
                      default_fg, default_bg)
    local cw, ch = self.cell_w, self.cell_h
    local font = self.font

    -- Paso 1: fondos. Celda por celda (F1). F4: agrupar runs.
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local cell = term:cell(row, col)
            if cell then
                local _, bg = effective_colors(cell, default_fg, default_bg)
                if bg then
                    local r, g, b = to_float(bg)
                    cairo.set_rgb(cr, r, g, b)
                    cairo.rectangle(cr, x0 + col * cw,
                        y0 + row * ch, cw, ch)
                    cairo.fill(cr)
                end
            end
        end
    end

    -- Paso 2: textos.
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local cell = term:cell(row, col)
            if cell and cell.utf8 ~= "" and not cell.attrs.conceal then
                local fg = effective_colors(cell, default_fg, default_bg)
                local r, g, b = to_float(fg)
                pango.draw_text(cr,
                    x0 + col * cw,
                    y0 + row * ch,
                    cell.utf8, font,
                    { r = r, g = g, b = b })
            end
        end
    end

    -- Paso 3: cursor. Rectangulo semi-transparente encima del
    -- caracter (para no ocultarlo del todo).
    if cursor and cursor.visible ~= false then
        cairo.set_rgba(cr, 0.9, 0.9, 0.9, 0.35)
        cairo.rectangle(cr,
            x0 + cursor.col * cw,
            y0 + cursor.row * ch,
            cw, ch)
        cairo.fill(cr)
    end
end

return M
