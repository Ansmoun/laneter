-- selection.lua: estado de la seleccion de texto con el mouse.
--
-- El ancla y el cursor viven en coordenadas de BUFFER, no del
-- viewport. brow = 0 es la linea mas vieja del scrollback;
-- brow = scrollback_count + rows - 1 es la ultima fila del vterm
-- vivo. Asi el scroll del viewport no mueve la seleccion: el
-- highlight se recalcula en cada draw mapeando fila visual ->
-- brow, y copiar recorre el buffer directamente.
--
-- API:
--   Sel.new()                -> seleccion vacia
--   sel:start(brow, col)     marca ancla y cursor
--   sel:extend(brow, col)    extiende el cursor (drag)
--   sel:finish()             mouse up; limpia si fue click simple
--   sel:clear()
--   sel:is_empty()
--   sel:range()              -> a, b normalizados (a <= b)
--   sel:contains(brow, col)
--   sel:get_text(source, cols)  source debe exponer
--                               :buffer_cell_at(brow, col)
--   sel:shift(delta)         ajusta ancla y cursor (usado por la
--                            rotacion del scrollback)

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

function Sel:start(brow, col)
    self.anchor = { row = brow, col = col }
    self.cursor = { row = brow, col = col }
    self.active = true
end

function Sel:extend(brow, col)
    if not self.anchor then return end
    self.cursor = { row = brow, col = col }
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

-- Ajusta ancla y cursor por un delta de brow. Usado cuando el
-- scrollback rota (la linea mas vieja se descarta, todos los
-- indices del buffer bajan en 1). Sin esto, la seleccion queda
-- apuntando a contenido distinto tras la rotacion.
function Sel:shift(delta)
    if not self.anchor then return end
    self.anchor.row = self.anchor.row + delta
    if self.anchor.row < 0 then self.anchor.row = 0 end
    if self.cursor then
        self.cursor.row = self.cursor.row + delta
        if self.cursor.row < 0 then self.cursor.row = 0 end
    end
end

function Sel:range()
    if not self.anchor or not self.cursor then return nil end
    local a, b = self.anchor, self.cursor
    if a.row > b.row or (a.row == b.row and a.col > b.col) then
        a, b = b, a
    end
    return a, b
end

function Sel:contains(brow, col)
    local a, b = self:range()
    if not a then return false end
    if brow < a.row or brow > b.row then return false end
    if brow == a.row and col < a.col then return false end
    if brow == b.row and col > b.col then return false end
    return true
end

function Sel:get_text(source, cols)
    local a, b = self:range()
    if not a then return "" end
    local lines = {}
    for brow = a.row, b.row do
        local start_col = (brow == a.row) and a.col or 0
        local end_col   = (brow == b.row) and b.col or (cols - 1)
        local parts = {}
        for col = start_col, end_col do
            local cell = source:buffer_cell_at(brow, col)
            if cell and cell.utf8 ~= "" then
                parts[#parts + 1] = cell.utf8
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
