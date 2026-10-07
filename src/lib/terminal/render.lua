-- render.lua: dibuja una grilla de celdas de libvterm con cairo+pango.
--
-- Estrategia F1 (naive): celda por celda, fondo opcional + texto.
-- pango cachea internamente los PangoLayouts por (texto, font), asi
-- que la mayoria de los draw_text son rapidos. F4 va a agrupar
-- runs horizontales de fondos iguales y cachear surfaces.
--
-- Attrs soportados:
--   bold, italic -> variante de fuente (DejaVu Sans Mono Bold Italic)
--   underline, strike -> lineas con cairo
--   reverse, conceal -> colores invertidos u ocultar texto
--
-- API:
--   M.new(font) -> renderer
--   renderer:cell_size()      -> w, h
--   renderer:draw(cr, term, x0, y0, cols, rows, cursor, default_fg, default_bg, is_selected)
--
-- is_selected es opcional: funcion (row, col) -> bool. Si esta,
-- las celdas seleccionadas se pintan con un fondo azulado semi-
-- transparente despues del texto.

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
        _font_cache = {},
    }, Renderer)
    return self
end

function Renderer:cell_size()
    return self.cell_w, self.cell_h
end

-- Construye el nombre de fuente pango agregando Bold/Italic segun
-- attrs. Cachea por combinacion (b/i). El font base tiene el formato
-- "<family> <size>"; insertamos las variantes entre ambos.
--
--   "DejaVu Sans Mono 11" + bold   -> "DejaVu Sans Mono Bold 11"
--   "DejaVu Sans Mono 11" + italic -> "DejaVu Sans Mono Italic 11"
--   "DejaVu Sans Mono 11" + ambos  -> "DejaVu Sans Mono Bold Italic 11"
function Renderer:_font_for(attrs)
    if not attrs.bold and not attrs.italic then
        return self.font
    end
    local key = (attrs.bold and "b" or "") .. (attrs.italic and "i" or "")
    local cached = self._font_cache[key]
    if cached then return cached end

    local family, size = self.font:match("^(.+)%s+(%d+)$")
    local result = self.font
    if family then
        local parts = { family }
        if attrs.bold then parts[#parts + 1] = "Bold" end
        if attrs.italic then parts[#parts + 1] = "Italic" end
        parts[#parts + 1] = size
        result = table.concat(parts, " ")
    end
    self._font_cache[key] = result
    return result
end

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
                      default_fg, default_bg, is_selected)
    local cw, ch = self.cell_w, self.cell_h

    -- Paso 1: fondos.
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

    -- Paso 2: textos + decoraciones (underline, strike).
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local cell = term:cell(row, col)
            if cell and cell.utf8 ~= "" and not cell.attrs.conceal then
                local fg = effective_colors(cell, default_fg, default_bg)
                local r, g, b = to_float(fg)
                local font = self:_font_for(cell.attrs)
                pango.draw_text(cr,
                    x0 + col * cw,
                    y0 + row * ch,
                    cell.utf8, font,
                    { r = r, g = g, b = b })

                if cell.attrs.underline then
                    cairo.set_rgb(cr, r, g, b)
                    cairo.set_line_width(cr, 1)
                    local ly = y0 + row * ch + ch - 1.5
                    cairo.move_to(cr, x0 + col * cw, ly)
                    cairo.line_to(cr, x0 + col * cw + cw, ly)
                    cairo.stroke(cr)
                end

                if cell.attrs.strike then
                    cairo.set_rgb(cr, r, g, b)
                    cairo.set_line_width(cr, 1)
                    local ly = y0 + row * ch + ch / 2
                    cairo.move_to(cr, x0 + col * cw, ly)
                    cairo.line_to(cr, x0 + col * cw + cw, ly)
                    cairo.stroke(cr)
                end
            end
        end
    end

    -- Paso 3: highlight de seleccion (encima del texto).
    if is_selected then
        cairo.set_rgba(cr, 0.45, 0.55, 0.85, 0.40)
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                if is_selected(row, col) then
                    cairo.rectangle(cr,
                        x0 + col * cw, y0 + row * ch, cw, ch)
                    cairo.fill(cr)
                end
            end
        end
    end

    -- Paso 4: cursor. Bloque semi-transparente encima del caracter.
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
