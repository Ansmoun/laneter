-- render.lua: dibuja una grilla de celdas de libvterm con cairo+pango.
--
-- Estrategia de rendimiento:
--
-- 1. Snapshot: la grilla del vterm se lee UNA VEZ cuando cambia
--    (feed, resize, cambio de colores), no en cada draw. El
--    snapshot es una tabla de filas con celdas reusadas entre
--    snapshots (cero allocations por actualizacion).
--
-- 2. Runs horizontales: en cada fila agrupamos celdas contiguas
--    con el mismo fondo (1 rectangle por run) y con el mismo
--    fg+attrs (1 pango.draw_text por run). Una linea de shell
--    tipica pasa de 112 draws a ~3-5.
--
-- 3. Draw limpio: solo se dibujan las celdas con contenido no
--    vacio. Filas vacias cuestan 0 draws de texto.
--
-- El scrollback (cuando row_layout viene dado) usa el camino
-- naive: es menos frecuente y mezclar fuentes con el scrollback
-- complica la agrupacion.

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
        _grid = nil,       -- tabla 2D de celdas reusadas
        _grid_cols = 0,
        _grid_rows = 0,
        _snap_valid = false,
    }, Renderer)
    return self
end

function Renderer:cell_size()
    return self.cell_w, self.cell_h
end

-- Invalida el snapshot. Se llama cuando la grilla del vterm pudo
-- haber cambiado (feed, resize, cambio de colores por defecto).
function Renderer:invalidate_snapshot()
    self._snap_valid = false
end

-- ── Fuentes ─────────────────────────────────────────────────
--
-- Devuelve la variante de fuente pango para (bold, italic).
-- Cacheada por combinacion. El font base tiene el formato
-- "<family> <size>"; insertamos las variantes entre medio.
function Renderer:_font_variant(bold, italic)
    if not bold and not italic then return self.font end
    local key = (bold and "b" or "") .. (italic and "i" or "")
    local cached = self._font_cache[key]
    if cached then return cached end
    local family, size = self.font:match("^(.+)%s+(%d+)$")
    local result = self.font
    if family then
        local parts = { family }
        if bold then parts[#parts + 1] = "Bold" end
        if italic then parts[#parts + 1] = "Italic" end
        parts[#parts + 1] = size
        result = table.concat(parts, " ")
    end
    self._font_cache[key] = result
    return result
end

-- ── Snapshot ────────────────────────────────────────────────
--
-- Reutiliza las tablas de la grilla entre actualizaciones. Solo
-- se reasignan los campos; no se crean tablas nuevas salvo el
-- primer snapshot de cada tamano.

local function ensure_grid(self, cols, rows)
    if self._grid and self._grid_cols == cols and self._grid_rows == rows then
        return self._grid
    end
    local g = {}
    for r = 1, rows do
        local row = {}
        for c = 1, cols do
            row[c] = {
                utf8 = "", width = 1, fg = nil, bg = nil,
                bold = false, italic = false,
                underline = false, strike = false, conceal = false,
            }
        end
        g[r] = row
    end
    self._grid = g
    self._grid_cols = cols
    self._grid_rows = rows
    return g
end

function Renderer:_take_snapshot(term, cols, rows, default_fg, default_bg)
    local g = ensure_grid(self, cols, rows)
    for row = 0, rows - 1 do
        local row_tbl = g[row + 1]
        for col = 0, cols - 1 do
            local dst = row_tbl[col + 1]
            local c = term:cell(row, col)
            if c then
                dst.utf8  = c.utf8
                dst.width = c.width
                local fg = c.fg or default_fg
                local bg = c.bg or default_bg
                if c.reverse then fg, bg = bg, fg end
                dst.fg = fg
                dst.bg = bg
                dst.bold      = c.bold
                dst.italic    = c.italic
                dst.underline = c.underline
                dst.strike    = c.strike
                dst.conceal   = c.conceal
            else
                dst.utf8 = ""
                dst.width = 1
                dst.fg = default_fg
                dst.bg = default_bg
                dst.bold = false
                dst.italic = false
                dst.underline = false
                dst.strike = false
                dst.conceal = false
            end
        end
    end
    self._snap_valid = true
    return g
end

-- ── Helpers de comparacion ──────────────────────────────────

local function same_color(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- ── Draw desde snapshot (run-length) ────────────────────────

function Renderer:_draw_snapshot(cr, x0, y0, cols, rows, cursor,
                                  default_bg, is_selected)
    local g = self._grid
    local cw, ch = self.cell_w, self.cell_h

    -- ── Paso 1: fondos con run-length ──
    -- Saltamos celdas cuyo bg es identico (por referencia) al
    -- default_bg: el widget ya pintó el fondo completo con
    -- fill_bg al principio de draw.
    for row = 0, rows - 1 do
        local row_tbl = g[row + 1]
        local ry = y0 + row * ch
        local col = 0
        while col < cols do
            local bg = row_tbl[col + 1].bg
            if not bg or bg == default_bg then
                col = col + 1
            else
                local start = col
                local br, bgc, bb = bg[1], bg[2], bg[3]
                col = col + 1
                while col < cols do
                    local b2 = row_tbl[col + 1].bg
                    if not b2 or b2 == default_bg then break end
                    if b2[1] ~= br or b2[2] ~= bgc or b2[3] ~= bb then break end
                    col = col + 1
                end
                cairo.set_rgb(cr, br / 255, bgc / 255, bb / 255)
                cairo.rectangle(cr, x0 + start * cw, ry,
                    (col - start) * cw, ch)
                cairo.fill(cr)
            end
        end
    end

    -- ── Paso 2: texto con run-length ──
    for row = 0, rows - 1 do
        local row_tbl = g[row + 1]
        local ry = y0 + row * ch
        local col = 0
        while col < cols do
            local cell = row_tbl[col + 1]
            if cell.utf8 == "" or cell.conceal then
                col = col + 1
            else
                -- Run: mismas fg, bold, italic, underline, strike.
                local start = col
                local parts = { cell.utf8 }
                local fg = cell.fg
                local bold, italic = cell.bold, cell.italic
                local underline, strike = cell.underline, cell.strike
                col = col + 1
                while col < cols do
                    local c2 = row_tbl[col + 1]
                    if c2.utf8 == "" or c2.conceal then break end
                    if c2.bold ~= bold or c2.italic ~= italic then break end
                    if c2.underline ~= underline or c2.strike ~= strike then break end
                    if not same_color(c2.fg, fg) then break end
                    parts[#parts + 1] = c2.utf8
                    col = col + 1
                end
                local text = table.concat(parts)
                local font = self:_font_variant(bold, italic)
                local r, gg, b = fg[1] / 255, fg[2] / 255, fg[3] / 255
                pango.draw_text(cr, x0 + start * cw, ry, text, font,
                                { r = r, g = gg, b = b })

                -- Underline: una linea por run completo.
                if underline then
                    cairo.set_rgb(cr, r, gg, b)
                    cairo.set_line_width(cr, 1)
                    local ly = ry + ch - 1.5
                    cairo.move_to(cr, x0 + start * cw, ly)
                    cairo.line_to(cr, x0 + col * cw, ly)
                    cairo.stroke(cr)
                end
                -- Strike: una linea por run, al medio.
                if strike then
                    cairo.set_rgb(cr, r, gg, b)
                    cairo.set_line_width(cr, 1)
                    local ly = ry + ch / 2
                    cairo.move_to(cr, x0 + start * cw, ly)
                    cairo.line_to(cr, x0 + col * cw, ly)
                    cairo.stroke(cr)
                end
            end
        end
    end

    -- ── Paso 3: seleccion (raro: mantenemos celda por celda) ──
    if is_selected then
        cairo.set_rgba(cr, 0.45, 0.55, 0.85, 0.40)
        for row = 0, rows - 1 do
            local ry = y0 + row * ch
            for col = 0, cols - 1 do
                if is_selected(row, col) then
                    cairo.rectangle(cr, x0 + col * cw, ry, cw, ch)
                    cairo.fill(cr)
                end
            end
        end
    end

    -- ── Paso 4: cursor ──
    if cursor and cursor.visible ~= false then
        local cc = cursor.color
        if cc then
            cairo.set_rgba(cr, cc[1] / 255, cc[2] / 255, cc[3] / 255, 0.55)
        else
            cairo.set_rgba(cr, 0.9, 0.9, 0.9, 0.35)
        end
        cairo.rectangle(cr, x0 + cursor.col * cw,
            y0 + cursor.row * ch, cw, ch)
        cairo.fill(cr)
    end
end

-- ── Draw scrollback (naive, se usa solo cuando hay layout) ──

local function vterm_row_of(layout, vy)
    local e = layout and layout[vy + 1]
    if e and e.source == "vterm" then return e.row end
    return nil
end

local function scrollback_text_of(layout, vy)
    local e = layout and layout[vy + 1]
    if e and e.source == "scrollback" then return e.text or "" end
    return nil
end

function Renderer:_draw_scrollback(cr, term, x0, y0, cols, rows, cursor,
                                    default_fg, default_bg, is_selected,
                                    layout)
    local cw, ch = self.cell_w, self.cell_h

    for vy = 0, rows - 1 do
        local vrow = vterm_row_of(layout, vy)
        if vrow then
            for col = 0, cols - 1 do
                local cell = term:cell(vrow, col)
                if cell then
                    local fg = cell.fg or default_fg
                    local bg = cell.bg or default_bg
                    if cell.reverse then fg, bg = bg, fg end
                    if bg and bg ~= default_bg then
                        cairo.set_rgb(cr, bg[1] / 255, bg[2] / 255, bg[3] / 255)
                        cairo.rectangle(cr, x0 + col * cw, y0 + vy * ch, cw, ch)
                        cairo.fill(cr)
                    end
                end
            end
        else
            if default_bg then
                cairo.set_rgb(cr, default_bg[1] / 255,
                    default_bg[2] / 255, default_bg[3] / 255)
                cairo.rectangle(cr, x0, y0 + vy * ch, cols * cw, ch)
                cairo.fill(cr)
            end
        end
    end

    for vy = 0, rows - 1 do
        local vrow = vterm_row_of(layout, vy)
        if vrow then
            for col = 0, cols - 1 do
                local cell = term:cell(vrow, col)
                if cell and cell.utf8 ~= "" and not cell.conceal then
                    local fg = cell.fg or default_fg
                    local bg = cell.bg or default_bg
                    if cell.reverse then fg, bg = bg, fg end
                    local font = self:_font_variant(
                        cell.bold, cell.italic)
                    pango.draw_text(cr, x0 + col * cw, y0 + vy * ch,
                        cell.utf8, font,
                        { r = fg[1] / 255, g = fg[2] / 255, b = fg[3] / 255 })
                end
            end
        else
            local text = scrollback_text_of(layout, vy)
            if text and text ~= "" and default_fg then
                pango.draw_text(cr, x0, y0 + vy * ch, text, self.font,
                    { r = default_fg[1] / 255,
                      g = default_fg[2] / 255,
                      b = default_fg[3] / 255 })
            end
        end
    end

    if is_selected then
        cairo.set_rgba(cr, 0.45, 0.55, 0.85, 0.40)
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                if is_selected(row, col) then
                    cairo.rectangle(cr, x0 + col * cw, y0 + row * ch, cw, ch)
                    cairo.fill(cr)
                end
            end
        end
    end

    if cursor and cursor.visible ~= false then
        local cc = cursor.color
        if cc then
            cairo.set_rgba(cr, cc[1] / 255, cc[2] / 255, cc[3] / 255, 0.55)
        else
            cairo.set_rgba(cr, 0.9, 0.9, 0.9, 0.35)
        end
        cairo.rectangle(cr, x0 + cursor.col * cw,
            y0 + cursor.row * ch, cw, ch)
        cairo.fill(cr)
    end
end

-- ── API principal ───────────────────────────────────────────

function Renderer:draw(cr, term, x0, y0, cols, rows, cursor,
                      default_fg, default_bg, is_selected, layout)
    -- Scrollback: camino naive (poco frecuente).
    if layout then
        return self:_draw_scrollback(cr, term, x0, y0, cols, rows, cursor,
                                     default_fg, default_bg, is_selected,
                                     layout)
    end

    -- Snapshot: se toma si esta invalido o cambio el tamano.
    if not self._snap_valid
       or self._grid_cols ~= cols or self._grid_rows ~= rows then
        self:_take_snapshot(term, cols, rows, default_fg, default_bg)
    end

    self:_draw_snapshot(cr, x0, y0, cols, rows, cursor,
                        default_bg, is_selected)
end

return M
