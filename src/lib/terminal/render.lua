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
--   renderer:draw(cr, term, x0, y0, cols, rows, cursor, default_fg, default_bg,
--                 is_selected, row_layout)
--
-- is_selected es opcional: funcion (row, col) -> bool. Si esta,
-- las celdas seleccionadas se pintan con fondo azul semi-transp.
--
-- row_layout es opcional. Si es nil, todas las filas vienen del
-- vterm (comportamiento por defecto). Si es una lista de 'rows'
-- elementos, cada uno especifica la fuente de esa fila:
--   { source = "vterm", row = N }        fila N del vterm
--   { source = "scrollback", text = "" } linea de texto plano del
--                                        scrollback (fg/bg default)
-- Esto permite mostrar scrollback arriba y grilla viva abajo.

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

-- Devuelve la fila del vterm para la fila visual 'vy' segun el
-- layout, o nil si esa fila es del scrollback.
local function vterm_row_of(layout, vy)
    if not layout then return vy end
    local e = layout[vy + 1]
    if e and e.source == "vterm" then return e.row end
    return nil
end

local function scrollback_text_of(layout, vy)
    if not layout then return nil end
    local e = layout[vy + 1]
    if e and e.source == "scrollback" then return e.text or "" end
    return nil
end

function Renderer:draw(cr, term, x0, y0, cols, rows, cursor,
                      default_fg, default_bg, is_selected, layout)
    local cw, ch = self.cell_w, self.cell_h

    -- Paso 1: fondos. Para filas del vterm pintamos bg de cada
    -- celda. Para filas del scrollback, un unico fondo default.
    for vy = 0, rows - 1 do
        local vrow = vterm_row_of(layout, vy)
        if vrow then
            for col = 0, cols - 1 do
                local cell = term:cell(vrow, col)
                if cell then
                    local _, bg = effective_colors(cell, default_fg, default_bg)
                    if bg then
                        local r, g, b = to_float(bg)
                        cairo.set_rgb(cr, r, g, b)
                        cairo.rectangle(cr, x0 + col * cw,
                            y0 + vy * ch, cw, ch)
                        cairo.fill(cr)
                    end
                end
            end
        else
            -- Fila de scrollback: fondo default en toda la fila.
            if default_bg then
                local r, g, b = to_float(default_bg)
                cairo.set_rgb(cr, r, g, b)
                cairo.rectangle(cr, x0, y0 + vy * ch, cols * cw, ch)
                cairo.fill(cr)
            end
        end
    end

    -- Paso 2: textos + decoraciones.
    for vy = 0, rows - 1 do
        local vrow = vterm_row_of(layout, vy)
        if vrow then
            for col = 0, cols - 1 do
                local cell = term:cell(vrow, col)
                if cell and cell.utf8 ~= "" and not cell.attrs.conceal then
                    local fg = effective_colors(cell, default_fg, default_bg)
                    local r, g, b = to_float(fg)
                    local font = self:_font_for(cell.attrs)
                    pango.draw_text(cr,
                        x0 + col * cw,
                        y0 + vy * ch,
                        cell.utf8, font,
                        { r = r, g = g, b = b })

                    if cell.attrs.underline then
                        cairo.set_rgb(cr, r, g, b)
                        cairo.set_line_width(cr, 1)
                        local ly = y0 + vy * ch + ch - 1.5
                        cairo.move_to(cr, x0 + col * cw, ly)
                        cairo.line_to(cr, x0 + col * cw + cw, ly)
                        cairo.stroke(cr)
                    end

                    if cell.attrs.strike then
                        cairo.set_rgb(cr, r, g, b)
                        cairo.set_line_width(cr, 1)
                        local ly = y0 + vy * ch + ch / 2
                        cairo.move_to(cr, x0 + col * cw, ly)
                        cairo.line_to(cr, x0 + col * cw + cw, ly)
                        cairo.stroke(cr)
                    end
                end
            end
        else
            -- Fila de scrollback: texto plano, color fg default.
            local text = scrollback_text_of(layout, vy)
            if text and text ~= "" and default_fg then
                local r, g, b = to_float(default_fg)
                pango.draw_text(cr, x0, y0 + vy * ch, text,
                    self.font, { r = r, g = g, b = b })
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
