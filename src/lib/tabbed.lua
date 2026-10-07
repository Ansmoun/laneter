-- tabbed.lua: contenedor de la aplicacion. Menubar + tabs_bar +
-- stack de terminales.
--
-- Layout:
--   Group (vertical)
--   ├── top_row (horizontal): menubar + spacer + tabs_bar
--   ├── divider
--   └── view_stack (Stack de Terminales)
--
-- Atajos globales (antes de delegar al terminal activo):
--   Ctrl+T          nueva pestaña
--   Ctrl+W          cerrar pestaña (o la ventana si es la ultima)
--   Ctrl+Tab        siguiente pestaña
--   Ctrl+Shift+Tab  anterior pestaña

local W           = require("lib.widgets")
local Stack       = require("lib.widgets.stack")
local log         = require("lib.log")
local Menubar     = require("lib.menubar")
local TabsBar     = require("lib.tabs_bar")
local Divider     = require("lib.divider")
local Terminal    = require("lib.terminal.widget")
local ContextMenu = require("lib.widgets.contextmenu")

local M = {}

local Tabbed = {}
Tabbed.__index = Tabbed

function M.new(srv, theme, opts)
    opts = opts or {}
    local self = setmetatable({}, Tabbed)
    self.srv = srv
    self.theme = theme
    self.opts = opts

    self.tabs = {}
    self.by_id = {}
    self.active_id = nil
    self._next_id = 1

    self.menubar = Menubar.new(theme, self:_build_menus(),
        function(anchor, items, on_close)
            self:_open_menu(anchor, items, on_close)
        end,
        function() end,
        { compact = true })

    self.tabs_bar = TabsBar.new(theme, {
        on_select = function(id) self:switch_to(id) end,
        on_close  = function(id) self:close_tab(id) end,
        on_new    = function() self:new_tab() end,
    })

    self.stack = Stack.new {}

    -- Primera tab.
    local first = self:_add_tab()
    self.active_id = first.id
    self.stack:add(first.id, first.container)
    self.stack.active = first.id

    local top_row = W.Group.new {
        orientation = "horizontal",
        spacing = 0,
        padding = 0,
        children = {
            { widget = self.menubar,  weight = 0 },
            { widget = W.Text.new { text = "", min_width = 8 }, weight = 0 },
            { widget = self.tabs_bar, weight = 1 },
        },
    }

    self.widget = W.Group.new {
        orientation = "vertical",
        spacing = 0,
        padding = 0,
        children = {
            { widget = top_row,            weight = 0 },
            { widget = Divider.new(theme), weight = 0 },
            { widget = self.stack,         weight = 1 },
        },
    }

    -- Interceptar set_window del widget raiz. Window:set_root llama
    -- a widget:set_window sobre el Group, que propaga a los hijos.
    -- Este hook nos avisa para guardar self.window (los menus lo
    -- necesitan) sin duplicar la propagacion.
    local _orig_sw = self.widget.set_window
    self.widget.set_window = function(widget_self, win)
        if _orig_sw then
            _orig_sw(widget_self, win)
        else
            widget_self.window = win
            for _, c in ipairs(widget_self.children or {}) do
                if c.set_window then c:set_window(win)
                else c.window = win end
            end
        end
        self.window = win
    end

    self:_sync_tabs_bar()
    return self
end

-- ── Tabs ───────────────────────────────────────────────────

function Tabbed:_add_tab()
    local id = "tab-" .. self._next_id
    local num = self._next_id
    self._next_id = self._next_id + 1

    local term = Terminal.new {
        shell = self.opts.shell,
        font  = self.opts.font,
        theme = self.theme,
    }

    -- ScrollBar al lado del terminal. Se auto-oculta cuando
    -- scrollback_count == 0. auto_hide lo maneja el widget.
    local sb = W.ScrollBar.new {
        orientation  = "vertical",
        width        = 12,
        thickness    = 3,
        handle_r     = 5,
        step         = 3,   -- 3 lineas por click de rueda
        color_handle = self.theme.accent,
        color_track  = self.theme.separator,
        auto_hide    = true,
    }
    term:set_scrollbar(sb)

    -- Container horizontal: terminal (weight 1) + SB (weight 0).
    local container = W.Group.new {
        orientation = "horizontal",
        spacing = 0,
        padding = 0,
        children = {
            { widget = term, weight = 1 },
            { widget = sb,   weight = 0 },
        },
    }

    local entry = {
        id = id, name = "Terminal " .. num,
        term = term, sb = sb, container = container,
    }
    self.tabs[#self.tabs + 1] = entry
    self.by_id[id] = entry
    return entry
end

function Tabbed:_sync_tabs_bar()
    local list = {}
    for _, t in ipairs(self.tabs) do
        list[#list + 1] = { id = t.id, name = t.name }
    end
    self.tabs_bar:set_tabs(list, self.active_id)
end

function Tabbed:active_term()
    local t = self.by_id[self.active_id]
    return t and t.term or nil
end

function Tabbed:switch_to(id)
    if not self.by_id[id] then return end
    self.active_id = id
    self.stack:set_active(id)
    self:_sync_tabs_bar()
    if self.window then self.window:damage_all() end
end

function Tabbed:new_tab()
    local entry = self:_add_tab()
    -- Registrar el fd del PTY con el server. Los widgets creados
    -- despues de set_root no reciben set_window automaticamente.
    -- Llamar al container propaga a term (que registra el PTY) y
    -- a sb (que necesita window para dañar).
    if self.window then entry.container:set_window(self.window) end
    self.stack:add(entry.id, entry.container)
    self:switch_to(entry.id)
    log.info("tabbed", "nueva pestaña: %s", entry.id)
end

function Tabbed:close_tab(id)
    if #self.tabs <= 1 then
        if self.window then self.window:close("ultima tab") end
        return
    end
    local idx
    for i, t in ipairs(self.tabs) do
        if t.id == id then idx = i; break end
    end
    if not idx then return end

    local entry = self.tabs[idx]
    entry.term:destroy()
    table.remove(self.tabs, idx)
    self.by_id[id] = nil
    self.stack:remove(id)

    if self.active_id == id then
        local next_id = self.tabs[1] and self.tabs[1].id
        if next_id then self:switch_to(next_id) end
    else
        self:_sync_tabs_bar()
        if self.window then self.window:damage_all() end
    end
    log.info("tabbed", "cerrada: %s", id)
end

function Tabbed:next_tab()
    local n = #self.tabs
    if n <= 1 then return end
    local idx
    for i, t in ipairs(self.tabs) do
        if t.id == self.active_id then idx = i; break end
    end
    local nxt = (idx % n) + 1
    self:switch_to(self.tabs[nxt].id)
end

function Tabbed:prev_tab()
    local n = #self.tabs
    if n <= 1 then return end
    local idx
    for i, t in ipairs(self.tabs) do
        if t.id == self.active_id then idx = i; break end
    end
    local prv = idx - 1
    if prv < 1 then prv = n end
    self:switch_to(self.tabs[prv].id)
end

-- ── Menus ──────────────────────────────────────────────────

function Tabbed:_build_menus()
    local s = self
    return {
        { label = "Archivo", build = function() return {
            { label = "Nueva pestaña",
              on_click = function() s:new_tab() end },
            { label = "Cerrar pestaña",
              on_click = function() s:close_tab(s.active_id) end,
              enabled = #s.tabs > 1 },
            { sep = true },
            { label = "Cerrar ventana",
              on_click = function()
                  if s.window then s.window:close("menu") end
              end },
        } end },
        { label = "Editar", build = function() return {
            { label = "Copiar",
              on_click = function() s:do_copy() end },
            { label = "Pegar",
              on_click = function() s:do_paste() end },
        } end },
        { label = "Ver", build = function()
            local t = s:active_term()
            return {
                { label = "Fuente más grande",
                  on_click = function()
                      local a = s:active_term()
                      if a then a:adjust_font_size(1) end
                  end },
                { label = "Fuente más pequeña",
                  on_click = function()
                      local a = s:active_term()
                      if a then a:adjust_font_size(-1) end
                  end },
                { label = "Tamaño por defecto",
                  on_click = function()
                      local a = s:active_term()
                      if a then a:reset_font_size() end
                  end },
                { sep = true },
                { label = (t and t:is_blink_enabled())
                    and "Desactivar parpadeo" or "Activar parpadeo",
                  on_click = function()
                      local a = s:active_term()
                      if a then a:set_blink_enabled(not a:is_blink_enabled()) end
                  end },
            }
        end },
        { label = "Pestañas", build = function() return {
            { label = "Siguiente",
              on_click = function() s:next_tab() end,
              enabled = #s.tabs > 1 },
            { label = "Anterior",
              on_click = function() s:prev_tab() end,
              enabled = #s.tabs > 1 },
        } end },
    }
end

function Tabbed:_open_menu(anchor, items, on_close)
    local cm = ContextMenu.new(self.srv, self.window, self.theme)
    local ar = nil
    if anchor and anchor.x0 and anchor.x1 then
        ar = {
            x = anchor.x0,
            y = anchor.y0,
            w = anchor.x1 - anchor.x0,
            h = anchor.y1 - anchor.y0,
        }
    end
    cm:show(anchor.x0, anchor.y1 + 2, items, {
        on_close = on_close,
        anchor_rect = ar,
    })
end

-- ── Ciclo de vida ──────────────────────────────────────────

function Tabbed:on_key(key)
    if not key or not key.pressed then return false end
    local m = key.mods or {}
    local n = key.name

    -- Atajos de la app (antes de delegar al terminal).
    if m.ctrl then
        if n == "t" and not m.shift then
            self:new_tab()
            return true
        end
        if n == "w" and not m.shift then
            self:close_tab(self.active_id)
            return true
        end
        if n == "Tab" then
            if m.shift then self:prev_tab() else self:next_tab() end
            return true
        end
    end

    -- Delegar al terminal activo.
    local term = self:active_term()
    if term and term.on_key then
        if term:on_key(key) then return true end
    end
    return false
end

function Tabbed:destroy()
    for _, t in ipairs(self.tabs) do
        if t.term and t.term.destroy then t.term:destroy() end
    end
    self.tabs = {}
    self.by_id = {}
end

-- ── Acciones del menu ──────────────────────────────────────

function Tabbed:do_copy()
    local term = self:active_term()
    if not term then return end
    local clip = require("lib.terminal.clipboard")
    local text = term.sel:get_text(term.term, term.cols)
    if text and text ~= "" then
        clip.copy_to("clipboard", text)
        log.info("tabbed", "copy %d bytes", #text)
    end
end

function Tabbed:do_paste()
    local term = self:active_term()
    if not term then return end
    local clip = require("lib.terminal.clipboard")
    local pty  = require("lib.terminal.pty")
    local text = clip.paste_from("clipboard")
    if text then
        pty.write(term.pty.fd, text)
        log.info("tabbed", "paste %d bytes", #text)
    end
end

return M
