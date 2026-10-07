-- selection.lua: estado de la seleccion de texto con el mouse.
--
-- Solo maneja el ancla y el cursor. El consumidor (widget) es
-- responsable de traducir eventos X11 a (row, col) y de dibujar
-- el highlight.
--
-- API:
--   Sel.new()                -> seleccion vacia
--   sel:start(row, col)      marca el ancla y el cursor
--   sel:extend(row, col)     extiende el cursor (drag)
--   sel:finish()             mouse up; limpia si fue click simple
--   sel:clear()
--   sel:is_empty()
--   sel:range()              -> a, b normalizados (a <= b)
--   sel:contains(row, col)
--   sel:get_text(term, cols) extrae el texto del vterm

local M = {}

local Sel = {}
Sel.__index = Sel

function M.new()
    return setmetatable({
        anchor = nil,
        cursor = nil,
        active = false,
    }, Sel)
end

function Sel:start(row, col)
    self.anchor = { row = row, col = col }
    self.cursor = { row = row, col = col }
    self.active = true
end

function Sel:extend(row, col)
    if not self.anchor then return end
    self.cursor = { row = row, col = col }
end

function Sel:finish()
    self.active = false
    -- Click simple sin arrastre: no es una seleccion.
    if self.anchor and self.cursor
       and self.anchor.row == self.cursor.row
       and self.anchor.col == self.cursor.col then
        self.anchor = nil
        self.cursor = nil
    end
end

function Sel:clear()
    self.anchor = nil
    self.cursor = nil
    self.active = false
end

function Sel:is_empty()
    return self.anchor == nil
end

function Sel:range()
    if not self.anchor or not self.cursor then return nil end
    local a, b = self.anchor, self.cursor
    if a.row > b.row or (a.row == b.row and a.col > b.col) then
        a, b = b, a
    end
    return a, b
end

function Sel:contains(row, col)
    local a, b = self:range()
    if not a then return false end
    if row < a.row or row > b.row then return false end
    if row == a.row and col < a.col then return false end
    if row == b.row and col > b.col then return false end
    return true
end

function Sel:get_text(term, cols)
    local a, b = self:range()
    if not a then return "" end
    local lines = {}
    for row = a.row, b.row do
        local start_col = (row == a.row) and a.col or 0
        local end_col   = (row == b.row) and b.col or (cols - 1)
        local parts = {}
        for col = start_col, end_col do
            local cell = term:cell(row, col)
            if cell then
                local u = cell.utf8
                parts[#parts + 1] = (u == "" and " " or u)
            else
                parts[#parts + 1] = " "
            end
        end
        -- Trim derecho: muchos comandos no llenan toda la linea.
        lines[#lines + 1] = (table.concat(parts):gsub("%s+$", ""))
    end
    return table.concat(lines, "\n")
end

return M
