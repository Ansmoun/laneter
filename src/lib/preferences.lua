-- preferences.lua: ventana de configuracion con tabs internos.
--
-- Tabs:
--   Fuente          -- lista de fuentes monoespaciadas + preview + tamano
--   Comportamiento  -- shell + cursor parpadea
--   Scrollback      -- lineas
--   Apariencia      -- modo (theme/custom) + paletas de color
--
-- Se abre desde el menu (Ver -> Preferencias...). Modal: captura
-- el puntero, click fuera cancela. Botones: Cerrar (descarta) y
-- Aplicar (persiste y propaga a todas las tabs).

local Window  = require("lib.window")
local W       = require("lib.widgets")
local Area    = require("lib.area")
local cairo   = require("lib.cairo")
local pango   = require("lib.pango")
local G       = require("lib.helpers.graphics")
local log     = require("lib.log")
local xcb     = require("lib.xcb")
local config  = require("lib.config")
local kb      = require("lib.keybindings")

local TabbedPanel = require("lib.widgets.tabbedpanel")
local ScrollView  = require("lib.widgets.scrollview")
local ScrollBar   = require("lib.widgets.scrollbar")
local ScrollLink  = require("lib.widgets.scrolllink")

local M = {}

local _current = nil

local WIN_W = 660
local WIN_H = 500
local PAD   = 16
local LABEL_W = 160

-- Paleta de colores para los swatches. Mezcla de grises tipicos,
-- colores de terminal clasicos y un par de acentos modernos.
local PALETTE = {
    "#000000", "#141418", "#1d1f21", "#282a2e",
    "#373b41", "#4d5156", "#707880", "#c5c8c6",
    "#e0e0e0", "#ffffff", "#cc6666", "#de935f",
    "#f0c674", "#b5bd68", "#8abeb7", "#81a2be",
}

-- ── Utilidades ─────────────────────────────────────────────

local function list_mono_fonts()
    local p = io.popen("fc-list :spacing=mono family 2>/dev/null")
    if not p then return { "DejaVu Sans Mono" } end
    local set = {}
    for line in p:lines() do
        for fam in line:gmatch("[^,]+") do
            fam = fam:gsub("^%s+", ""):gsub("%s+$", "")
            if fam ~= "" then set[fam] = true end
        end
    end
    p:close()
    local out = {}
    for fam in pairs(set) do out[#out + 1] = fam end
    table.sort(out)
    if #out == 0 then out[1] = "DejaVu Sans Mono" end
    return out
end

local function make_label(theme, text, bold)
    local fg = theme.fg_rgb or { 0.9, 0.9, 0.9 }
    return W.Text.new {
        text = text,
        font = bold and "DejaVu Sans Bold 10" or "DejaVu Sans 10",
        align = "left", valign = "center",
        r = fg[1], g = fg[2], b = fg[3],
        min_width = LABEL_W, max_width = LABEL_W,
    }
end

local function make_row(theme, label, widget, bold)
    return W.Group.new {
        orientation = "horizontal",
        spacing = 8,
        children = {
            { widget = make_label(theme, label, bold), weight = 0 },
            { widget = widget, weight = 1 },
        },
    }
end

local function make_text_input(theme, opts)
    opts = opts or {}
    return W.TextInput.new {
        text = opts.text or "",
        font = "DejaVu Sans 10",
        padding_x = 8, padding_y = 4,
        min_height = 26,
        color_bg = theme.bg_focus,
        color_border = theme.separator,
        corner_radius = 4,
        color_text = theme.fg_rgb,
        color_cursor = theme.accent_rgb,
        placeholder = opts.placeholder,
        color_placeholder = theme.muted_rgb,
    }
end

local function make_toggle(theme, initial)
    local value = initial and true or false
    local btn
    local function label_of(v) return v and "Si" or "No" end
    btn = W.Button.new {
        text = label_of(value),
        font = "DejaVu Sans 10",
        padding_x = 16, padding_y = 5,
        corner_radius = 4,
        color_normal  = { 0.22, 0.22, 0.28 },
        color_hover   = { 0.30, 0.30, 0.38 },
        color_pressed = { 0.15, 0.15, 0.20 },
        color_border  = { 0.42, 0.42, 0.52 },
        color_text    = { 0.95, 0.95, 0.95 },
        on_click = function()
            value = not value
            btn:set_text(label_of(value))
        end,
    }
    return btn, function() return value end
end

-- ── ColorPalette: grid horizontal de swatches ────────────────

local ColorPalette = setmetatable({}, { __index = Area })
ColorPalette.__index = ColorPalette

function ColorPalette.new(opts)
    opts = opts or {}
    local self = setmetatable(Area.new({}), ColorPalette)
    self._hover_visual = true
    self.colors  = opts.colors or PALETTE
    self.selected = opts.selected
    self.on_select = opts.on_select
    self.enabled  = opts.enabled ~= false
    self.swatch   = 22
    self.gap      = 4
    self._hover_idx = nil
    self.min_h = self.swatch + 8
    self.max_h = self.min_h
    self.min_w = #self.colors * (self.swatch + self.gap)
    self.max_w = self.min_w
    return self
end

-- Indice del swatch bajo (mx, my) o nil si el click cae en el gap
-- o fuera del rect.
function ColorPalette:_index_at(mx, my)
    if my < 4 or my > 4 + self.swatch then return nil end
    local i = math.floor(mx / (self.swatch + self.gap)) + 1
    if i < 1 or i > #self.colors then return nil end
    local off = mx - (i - 1) * (self.swatch + self.gap)
    if off > self.swatch then return nil end
    return i
end

function ColorPalette:on_mouse_move(mx, my)
    if not self.enabled then
        if self._hover_idx then
            self._hover_idx = nil
            self:damage()
        end
        return
    end
    local i = self:_index_at(mx, my)
    if i ~= self._hover_idx then
        self._hover_idx = i
        self:damage()
    end
end

function ColorPalette:set_hover(v)
    Area.set_hover(self, v)
    if not v and self._hover_idx then
        self._hover_idx = nil
        self:damage()
    end
end

function ColorPalette:set_selected(hex)
    self.selected = hex
    self:damage()
end

function ColorPalette:set_enabled(v)
    self.enabled = v and true or false
    self:damage()
end

function ColorPalette:draw(cr)
    local x0, y0 = self.x0, self.y0
    local T = self.opts.theme or {}
    for i, hex in ipairs(self.colors) do
        local x = x0 + (i - 1) * (self.swatch + self.gap)
        local y = y0 + 4
        local r, g, b = G.hex_to_rgba(hex)

        if not self.enabled then
            -- Deshabilitado: colores apagados + borde gris tenue.
            cairo.set_rgba(cr, r, g, b, 0.18)
            cairo.rounded_rect(cr, x, y, self.swatch, self.swatch, 4)
            cairo.fill(cr)
            cairo.set_rgba(cr, 0.5, 0.5, 0.5, 0.4)
            cairo.set_line_width(cr, 1)
            cairo.rounded_rect(cr, x + 0.5, y + 0.5,
                self.swatch - 1, self.swatch - 1, 4)
            cairo.stroke(cr)
        else
            cairo.set_rgb(cr, r, g, b)
            cairo.rounded_rect(cr, x, y, self.swatch, self.swatch, 4)
            cairo.fill(cr)

            -- Hover: borde claro.
            if i == self._hover_idx and hex ~= self.selected then
                cairo.set_rgba(cr, 1, 1, 1, 0.6)
                cairo.set_line_width(cr, 1)
                cairo.rounded_rect(cr, x + 0.5, y + 0.5,
                    self.swatch - 1, self.swatch - 1, 4)
                cairo.stroke(cr)
            end
        end

        if hex == self.selected then
            local ar, ag, ab = G.hex_to_rgba(T.accent or "#8ec07c")
            cairo.set_rgb(cr, ar, ag, ab)
            cairo.set_line_width(cr, 2)
            cairo.rounded_rect(cr, x + 0.5, y + 0.5,
                self.swatch - 1, self.swatch - 1, 4)
            cairo.stroke(cr)
        end
    end
end

function ColorPalette:on_mouse_press(mx, my, button)
    if button ~= 1 or not self.enabled then return end
    local i = self:_index_at(mx, my)
    if not i then return end
    local hex = self.colors[i]
    self.selected = hex
    self:damage()
    if self.on_select then self.on_select(hex) end
end

-- ── FontPreview: bloque de texto grande en una fuente ────────

local FontPreview = setmetatable({}, { __index = Area })
FontPreview.__index = FontPreview

function FontPreview.new(opts)
    opts = opts or {}
    local self = setmetatable(Area.new({}), FontPreview)
    self.family = opts.family or "DejaVu Sans Mono"
    self.size   = opts.size   or 11
    self.theme  = opts.theme
    self.min_h  = 70
    self.max_h  = 70
    self.min_w  = 200
    return self
end

function FontPreview:set_font(family, size)
    self.family = family or self.family
    self.size   = size   or self.size
    self:damage()
end

function FontPreview:draw(cr)
    local T = self.theme or {}
    local x, y = self.x0, self.y0
    local w, h = self:getWidth(), self:getHeight()

    -- Marco
    cairo.set_rgb(cr,
        (T.bg_focus_rgb or { 0.15, 0.15, 0.15 })[1],
        (T.bg_focus_rgb or { 0.15, 0.15, 0.15 })[2],
        (T.bg_focus_rgb or { 0.15, 0.15, 0.15 })[3])
    cairo.rounded_rect(cr, x, y, w, h, 4)
    cairo.fill(cr)

    local fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
    local font = string.format("%s %d", self.family, self.size)
    local sample1 = "abc ABC 123"
    local sample2 = "¡Hola, mundo! 0O1l  ->  fn()"
    pango.draw_text(cr, x + 10, y + 8, sample1, font,
        { r = fg[1], g = fg[2], b = fg[3] })
    pango.draw_text(cr, x + 10, y + 8 + self.size + 8, sample2, font,
        { r = fg[1], g = fg[2], b = fg[3] })
end

-- ── Tab Fuente ──────────────────────────────────────────────

local function build_tab_fuente(T, prefs)
    local fonts = list_mono_fonts()
    log.info("preferences", "%d fuentes monoespaciadas", #fonts)

    -- Buscar indice de la fuente actual (o el primero).
    local current_idx = 1
    for i, f in ipairs(fonts) do
        if f == prefs.font_family then current_idx = i; break end
    end

    local selected_idx = current_idx

    local preview = FontPreview.new {
        family = fonts[selected_idx],
        size   = prefs.font_size,
        theme  = T,
    }

    -- ScrollView con draw_row custom. Cada fila dibuja el nombre
    -- de la fuente EN SU PROPIA FUENTE (lo que hace lxterminal).
    local list = ScrollView.new {
        row_height = 26,
        min_width  = 300,
        min_height = 220,
    }

    local hover_idx = -1
    list.draw_row = function(cr, item, idx, y, row_h, width, hover, self_sv)
        if hover then
            cairo.set_rgba(cr,
                (T.bg_focus_rgb or { 0.2, 0.2, 0.2 })[1],
                (T.bg_focus_rgb or { 0.2, 0.2, 0.2 })[2],
                (T.bg_focus_rgb or { 0.2, 0.2, 0.2 })[3], 0.9)
            cairo.rectangle(cr, 0, y, width, row_h)
            cairo.fill(cr)
        end
        if idx == selected_idx then
            local ar, ag, ab = G.hex_to_rgba(T.accent or "#8ec07c")
            cairo.set_rgba(cr, ar, ag, ab, 0.30)
            cairo.rectangle(cr, 0, y, width, row_h)
            cairo.fill(cr)
        end
        -- Nombre en su propia fuente. Tamano fijo 12 para que
        -- todas las filas midan similar.
        local f = string.format("%s 12", item.name or "")
        local fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
        pango.draw_text(cr, 10, y + 6, item.name or "", f,
            { r = fg[1], g = fg[2], b = fg[3] })
    end

    -- Convertir lista de familias a items de ScrollView.
    local items = {}
    for i, fam in ipairs(fonts) do
        items[i] = { name = fam }
    end
    list:set_items(items)

    local sb = ScrollBar.new {
        orientation  = "vertical",
        width        = 12,
        thickness    = 3,
        handle_r     = 5,
        step         = 40,
        color_handle = T.accent,
        color_track  = T.separator,
    }
    ScrollLink.link(list, sb)

    -- Click en la lista: cambiar seleccion y actualizar preview.
    list.on_click = function(item, idx)
        selected_idx = idx
        prefs.font_family = item.name
        preview:set_font(item.name, prefs.font_size)
        list:damage()
    end

    -- Input de tamano.
    local size_input = make_text_input(T, {
        text = tostring(prefs.font_size),
    })

    -- Fuente compartida: caja con lista + scrollbar.
    local list_box = W.Group.new {
        orientation = "horizontal",
        spacing = 0,
        children = {
            { widget = list, weight = 1 },
            { widget = sb,   weight = 0 },
        },
    }

    local layout = W.Group.new {
        orientation = "vertical",
        spacing = 12,
        children = {
            { widget = list_box, weight = 1 },
            { widget = W.Text.new {
                text = "Preview:",
                font = "DejaVu Sans 10",
                align = "left", valign = "center",
                r = (T.muted_rgb or { 0.55, 0.55, 0.55 })[1],
                g = (T.muted_rgb or { 0.55, 0.55, 0.55 })[2],
                b = (T.muted_rgb or { 0.55, 0.55, 0.55 })[3],
              }, weight = 0 },
            { widget = preview, weight = 0 },
            { widget = make_row(T, "Tamaño", size_input), weight = 0 },
        },
    }

    return {
        widget = layout,
        collect = function()
            prefs.font_family = fonts[selected_idx]
            local sz = tonumber(size_input:get_text()) or 11
            if sz < 6 then sz = 6 end
            if sz > 32 then sz = 32 end
            prefs.font_size = sz
        end,
        preview_change = function()
            local sz = tonumber(size_input:get_text()) or 11
            if sz < 6 then sz = 6 end
            if sz > 32 then sz = 32 end
            prefs.font_size = sz
            preview:set_font(fonts[selected_idx], sz)
        end,
    }
end

-- ── Tab Comportamiento ──────────────────────────────────────

local function build_tab_comportamiento(T, prefs)
    local shell_input = make_text_input(T, {
        text = prefs.shell or "",
        placeholder = os.getenv("SHELL") or "/bin/sh",
    })
    local toggle_blink, get_blink = make_toggle(T,
        prefs.cursor_blink)

    local layout = W.Group.new {
        orientation = "vertical",
        spacing = 14,
        children = {
            { widget = make_row(T, "Shell", shell_input), weight = 0 },
            { widget = make_row(T, "Cursor parpadea", toggle_blink), weight = 0 },
            { widget = W.Text.new { text = "", min_height = 1 }, weight = 1 },
        },
    }
    return {
        widget = layout,
        collect = function()
            local s = shell_input:get_text()
            -- Normalizar "" -> nil. Un string vacio es truthy en Lua
            -- y execvp("") falla con ENOENT, matando el shell al
            -- instante.
            if s == "" then s = nil end
            prefs.shell = s
            prefs.cursor_blink = get_blink()
        end,
    }
end

-- ── Tab Scrollback ──────────────────────────────────────────

local function build_tab_scrollback(T, prefs)
    local sb_input = make_text_input(T, {
        text = tostring(prefs.scrollback_lines),
    })
    local layout = W.Group.new {
        orientation = "vertical",
        spacing = 14,
        children = {
            { widget = make_row(T, "Lineas maximas", sb_input), weight = 0 },
            { widget = W.Text.new { text = "", min_height = 1 }, weight = 1 },
        },
    }
    return {
        widget = layout,
        collect = function()
            local n = tonumber(sb_input:get_text()) or 2000
            if n < 100 then n = 100 end
            if n > 100000 then n = 100000 end
            prefs.scrollback_lines = n
        end,
    }
end

-- ── Tab Apariencia ──────────────────────────────────────────

local function build_tab_apariencia(T, prefs)
    -- Chips de modo (radio simple hecho con dos botones).
    local mode = prefs.color_mode or "theme"
    local btn_theme, btn_custom
    -- Forward declarations. Los botones de modo se crean ANTES que
    -- hint_lbl/refresh_hint, pero sus on_click las llaman. Sin este
    -- forward, refresh_hint es un global (nil) al invocarse y crashea.
    local hint_lbl
    local refresh_hint
    local function refresh_mode_buttons()
        local function set_colors(btn, active)
            if active then
                btn:set_colors({
                    normal  = { 0.30, 0.55, 0.35 },
                    hover   = { 0.38, 0.65, 0.42 },
                    pressed = { 0.22, 0.42, 0.28 },
                    border  = { 0.45, 0.65, 0.50 },
                })
            else
                btn:set_colors({
                    normal  = { 0.22, 0.22, 0.28 },
                    hover   = { 0.30, 0.30, 0.38 },
                    pressed = { 0.15, 0.15, 0.20 },
                    border  = { 0.42, 0.42, 0.52 },
                })
            end
        end
        set_colors(btn_theme, mode == "theme")
        set_colors(btn_custom, mode == "custom")
    end

    -- Paletas. Solo activas en modo custom.
    local pal_text = ColorPalette.new {
        colors = PALETTE,
        selected = prefs.text_color,
        enabled = (mode == "custom"),
        theme = T,
    }
    local pal_bg = ColorPalette.new {
        colors = PALETTE,
        selected = prefs.bg_color,
        enabled = (mode == "custom"),
        theme = T,
    }
    local pal_cur = ColorPalette.new {
        colors = PALETTE,
        selected = prefs.cursor_color,
        enabled = (mode == "custom"),
        theme = T,
    }

    pal_text.on_select = function(hex) prefs.text_color = hex end
    pal_bg.on_select   = function(hex) prefs.bg_color = hex end
    pal_cur.on_select  = function(hex) prefs.cursor_color = hex end

    local function set_palettes_enabled(v)
        pal_text:set_enabled(v)
        pal_bg:set_enabled(v)
        pal_cur:set_enabled(v)
    end

    btn_theme = W.Button.new {
        text = "Usar colores del tema",
        font = "DejaVu Sans 10",
        padding_x = 16, padding_y = 6,
        corner_radius = 4,
        color_normal  = { 0.22, 0.22, 0.28 },
        color_hover   = { 0.30, 0.30, 0.38 },
        color_pressed = { 0.15, 0.15, 0.20 },
        color_border  = { 0.42, 0.42, 0.52 },
        color_text    = { 0.95, 0.95, 0.95 },
        on_click = function()
            mode = "theme"
            set_palettes_enabled(false)
            refresh_mode_buttons()
            refresh_hint()
        end,
    }
    btn_custom = W.Button.new {
        text = "Personalizados",
        font = "DejaVu Sans 10",
        padding_x = 16, padding_y = 6,
        corner_radius = 4,
        color_normal  = { 0.22, 0.22, 0.28 },
        color_hover   = { 0.30, 0.30, 0.38 },
        color_pressed = { 0.15, 0.15, 0.20 },
        color_border  = { 0.42, 0.42, 0.52 },
        color_text    = { 0.95, 0.95, 0.95 },
        on_click = function()
            mode = "custom"
            set_palettes_enabled(true)
            refresh_mode_buttons()
            refresh_hint()
        end,
    }
    refresh_mode_buttons()

    local mode_row = W.Group.new {
        orientation = "horizontal",
        spacing = 8,
        children = {
            { widget = btn_theme,  weight = 0 },
            { widget = btn_custom, weight = 0 },
            { widget = W.Text.new { text = "", min_width = 1 }, weight = 1 },
        },
    }

    -- Etiqueta contextual: avisa si los swatches estan activos o no.
    hint_lbl = W.Text.new {
        text = "",
        font = "DejaVu Sans 9",
        align = "left", valign = "center",
        r = (T.muted_rgb or { 0.55, 0.55, 0.55 })[1],
        g = (T.muted_rgb or { 0.55, 0.55, 0.55 })[2],
        b = (T.muted_rgb or { 0.55, 0.55, 0.55 })[3],
    }
    refresh_hint = function()
        if mode == "theme" then
            hint_lbl:set_text(
                "El terminal usa los colores del tema LANE. "
                .. "Elegí 'Personalizados' para editar los colores.")
        else
            hint_lbl:set_text(
                "Hacé click en un cuadro de color para aplicarlo.")
        end
    end
    refresh_hint()

    local function palette_row(label, pal)
        return W.Group.new {
            orientation = "horizontal",
            spacing = 8,
            children = {
                { widget = W.Text.new {
                    text = label,
                    font = "DejaVu Sans 10",
                    align = "left", valign = "center",
                    r = (T.fg_rgb or {0.9,0.9,0.9})[1],
                    g = (T.fg_rgb or {0.9,0.9,0.9})[2],
                    b = (T.fg_rgb or {0.9,0.9,0.9})[3],
                    min_width = 130, max_width = 130,
                  }, weight = 0 },
                { widget = pal, weight = 1 },
            },
        }
    end

    local layout = W.Group.new {
        orientation = "vertical",
        spacing = 14,
        children = {
            { widget = W.Text.new {
                text = "Modo de colores",
                font = "DejaVu Sans Bold 10",
                align = "left", valign = "center",
                r = (T.fg_rgb or {0.9,0.9,0.9})[1],
                g = (T.fg_rgb or {0.9,0.9,0.9})[2],
                b = (T.fg_rgb or {0.9,0.9,0.9})[3],
              }, weight = 0 },
            { widget = mode_row, weight = 0 },
            { widget = hint_lbl, weight = 0 },
            { widget = W.Text.new { text = "", min_height = 6 }, weight = 0 },
            { widget = palette_row("Color de texto",  pal_text), weight = 0 },
            { widget = palette_row("Color de fondo",  pal_bg),   weight = 0 },
            { widget = palette_row("Color del cursor", pal_cur), weight = 0 },
            { widget = W.Text.new { text = "", min_height = 1 }, weight = 1 },
        },
    }

    return {
        widget = layout,
        collect = function()
            prefs.color_mode = mode
            -- Los swatches actualizan prefs.text_color/etc via on_select,
            -- pero por las dudas resincronizamos con el estado actual.
            prefs.text_color   = pal_text.selected
            prefs.bg_color     = pal_bg.selected
            prefs.cursor_color = pal_cur.selected
        end,
    }
end

-- ── Tab Atajos ──────────────────────────────────────────────
--
-- Cada accion tiene una fila: label + boton con el combo actual.
-- Click en el boton entra en modo captura. La proxima tecla
-- (con modificadores) define el combo. Escape cancela.
--
-- Los combos se guardan en prefs.keybindings al hacer Aplicar,
-- SOLO si difieren del default. Un combo duplicado desasigna la
-- otra accion (vuelve a su default).

local function build_tab_atajos(T, prefs)
    -- Bindings efectivos para esta sesion del dialogo: defaults
    -- pisados por lo que ya este guardado.
    local bindings = {}
    local cur = prefs.keybindings or {}
    for _, a in ipairs(kb.ACTIONS) do
        bindings[a.id] = cur[a.id] or a.default
    end

    local capturing_id = nil
    local buttons = {}

    local function set_button_label(id)
        local btn = buttons[id]
        if not btn then return end
        if capturing_id == id then
            btn:set_text("Presioná una tecla…")
        else
            btn:set_text(bindings[id] or "")
        end
    end

    local function start_capture(id)
        if capturing_id and capturing_id ~= id then
            local prev = capturing_id
            capturing_id = nil
            set_button_label(prev)
        end
        if capturing_id == id then
            capturing_id = nil
            set_button_label(id)
        else
            capturing_id = id
            set_button_label(id)
        end
    end

    local function cancel_capture()
        if capturing_id then
            local prev = capturing_id
            capturing_id = nil
            set_button_label(prev)
        end
    end

    local function commit_capture(combo)
        local id = capturing_id
        if not id then return end
        -- Desasignar cualquier otra accion que ya tenga este combo:
        -- vuelve a su default.
        for other_id, other_combo in pairs(bindings) do
            if other_id ~= id and other_combo == combo then
                bindings[other_id] = kb.BY_ID[other_id].default
                set_button_label(other_id)
            end
        end
        bindings[id] = combo
        capturing_id = nil
        set_button_label(id)
    end

    local function row_for(action)
        local fg = T.fg_rgb or { 0.9, 0.9, 0.9 }
        local btn = W.Button.new {
            text = bindings[action.id] or "",
            font = "DejaVu Sans Mono 10",
            padding_x = 14, padding_y = 4,
            corner_radius = 4,
            -- min y max fijos: sin max, el boton se estira al
            -- espacio disponible y las filas quedan desalineadas
            -- segun el largo del combo.
            min_width = 200, max_width = 200,
            color_normal  = { 0.20, 0.20, 0.26 },
            color_hover   = { 0.28, 0.28, 0.36 },
            color_pressed = { 0.14, 0.14, 0.20 },
            color_border  = { 0.42, 0.42, 0.52 },
            color_text    = { 0.95, 0.95, 0.95 },
            on_click = function() start_capture(action.id) end,
        }
        buttons[action.id] = btn
        return W.Group.new {
            orientation = "horizontal",
            spacing = 8,
            children = {
                { widget = W.Text.new {
                    text = action.label,
                    font = "DejaVu Sans 10",
                    align = "left", valign = "center",
                    r = fg[1], g = fg[2], b = fg[3],
                    min_width = 230, max_width = 230,
                  }, weight = 0 },
                { widget = btn, weight = 0 },
                { widget = W.Text.new { text = "", min_width = 1 }, weight = 1 },
            },
        }
    end

    local function section_header(text)
        return W.Text.new {
            text = text,
            font = "DejaVu Sans Bold 10",
            align = "left", valign = "center",
            r = (T.muted_rgb or { 0.55, 0.55, 0.55 })[1],
            g = (T.muted_rgb or { 0.55, 0.55, 0.55 })[2],
            b = (T.muted_rgb or { 0.55, 0.55, 0.55 })[3],
        }
    end

    local terminal_rows = {}
    for _, a in ipairs(kb.by_section("terminal")) do
        terminal_rows[#terminal_rows + 1] = { widget = row_for(a), weight = 0 }
    end
    local tabs_rows = {}
    for _, a in ipairs(kb.by_section("tabs")) do
        tabs_rows[#tabs_rows + 1] = { widget = row_for(a), weight = 0 }
    end

    local layout = W.Group.new {
        orientation = "vertical",
        spacing = 10,
        children = {
            { widget = section_header("Terminal"), weight = 0 },
            { widget = W.Group.new {
                orientation = "vertical",
                spacing = 4,
                children = terminal_rows,
              }, weight = 0 },
            { widget = W.Text.new { text = "", min_height = 8 }, weight = 0 },
            { widget = section_header("Pestañas"), weight = 0 },
            { widget = W.Group.new {
                orientation = "vertical",
                spacing = 4,
                children = tabs_rows,
              }, weight = 0 },
            { widget = W.Text.new { text = "", min_height = 1 }, weight = 1 },
        },
    }

    return {
        widget = layout,
        collect = function()
            -- Guardar solo lo que difiere del default. Los que
            -- volvieron al default se eliminan del dict.
            local out = {}
            for id, combo in pairs(bindings) do
                local def = kb.BY_ID[id] and kb.BY_ID[id].default
                if combo and combo ~= def then
                    out[id] = combo
                end
            end
            prefs.keybindings = next(out) and out or nil
        end,
        -- La ventana delega aca el teclado ANTES de su propio Esc.
        -- Devuelve true si consumio la tecla (estamos capturando).
        handle_key = function(key_event)
            if not capturing_id then return false end
            if not key_event.pressed then return true end
            if key_event.name == "Escape" then
                cancel_capture()
                return true
            end
            local combo = kb.combo_from_event(key_event)
            if not combo then
                -- Modificador solo. Consumir, seguir esperando.
                return true
            end
            commit_capture(combo)
            return true
        end,
    }
end

-- ── M.show ──────────────────────────────────────────────────

function M.show(opts)
    if _current then _current:close() end

    local parent = opts.parent_win
    local srv    = opts.srv
    local theme  = opts.theme
    local T      = theme

    -- Snapshot mutable de preferencias. Los tabs escriben aca.
    local prefs = {
        font_family      = config.get("font_family"),
        font_size        = tonumber(config.get("font_size")) or 11,
        shell            = config.get("shell"),
        scrollback_lines = tonumber(config.get("scrollback_lines")) or 2000,
        cursor_blink     = config.get("cursor_blink") and true or false,
        color_mode       = config.get("color_mode") or "theme",
        text_color       = config.get("text_color") or "#e0e0e0",
        bg_color         = config.get("bg_color") or "#141418",
        cursor_color     = config.get("cursor_color") or "#e0e0e0",
    }

    local tab_fuente         = build_tab_fuente(T, prefs)
    local tab_comportamiento = build_tab_comportamiento(T, prefs)
    local tab_scrollback     = build_tab_scrollback(T, prefs)
    local tab_apariencia     = build_tab_apariencia(T, prefs)
    local tab_atajos         = build_tab_atajos(T, prefs)

    local tabbed = TabbedPanel.new {
        theme = T,
        spacing = 8,
        tabs = {
            { id = "fuente",         label = "Fuente",
              factory = function() return tab_fuente         end },
            { id = "comportamiento", label = "Comportamiento",
              factory = function() return tab_comportamiento end },
            { id = "scrollback",     label = "Scrollback",
              factory = function() return tab_scrollback     end },
            { id = "apariencia",     label = "Apariencia",
              factory = function() return tab_apariencia     end },
            { id = "atajos",         label = "Atajos",
              factory = function() return tab_atajos         end },
        },
    }

    local win

    local function close_dialog(applied)
        if not win or win.destroyed then return end
        local w = win
        win = nil
        _current = nil
        xcb.ungrab_pointer(srv.conn)
        if not w.destroyed then
            w:close("preferencias cerradas")
        end
        if applied then
            -- Recolectar de cada tab antes de persistir.
            tab_fuente.collect()
            tab_comportamiento.collect()
            tab_scrollback.collect()
            tab_apariencia.collect()
            tab_atajos.collect()

            config.set("font_family",      prefs.font_family)
            config.set("font_size",        prefs.font_size)
            config.set("shell",            prefs.shell)
            config.set("scrollback_lines", prefs.scrollback_lines)
            config.set("cursor_blink",     prefs.cursor_blink)
            config.set("color_mode",       prefs.color_mode)
            config.set("text_color",       prefs.text_color)
            config.set("bg_color",         prefs.bg_color)
            config.set("cursor_color",     prefs.cursor_color)
            config.set("keybindings",      prefs.keybindings)
            config.save()

            log.info("preferences",
                "aplicado: font=%s %d, sb=%d, blink=%s, colors=%s",
                prefs.font_family, prefs.font_size,
                prefs.scrollback_lines,
                tostring(prefs.cursor_blink),
                prefs.color_mode)
            if prefs.keybindings then
                local n = 0
                for _ in pairs(prefs.keybindings) do n = n + 1 end
                log.info("preferences", "%d atajos personalizados", n)
            end

            if opts.on_apply then
                opts.on_apply(prefs)
            end
        end
    end

    local btn_close = W.Button.new {
        text = "Cerrar",
        font = "DejaVu Sans 10",
        padding_x = 16, padding_y = 6,
        corner_radius = 4,
        color_normal  = { 0.22, 0.22, 0.28 },
        color_hover   = { 0.30, 0.30, 0.38 },
        color_pressed = { 0.15, 0.15, 0.20 },
        color_border  = { 0.42, 0.42, 0.52 },
        color_text    = { 0.95, 0.95, 0.95 },
        on_click = function() close_dialog(false) end,
    }
    local btn_apply = W.Button.new {
        text = "Aplicar",
        font = "DejaVu Sans Bold 10",
        padding_x = 16, padding_y = 6,
        corner_radius = 4,
        color_normal  = { 0.30, 0.55, 0.35 },
        color_hover   = { 0.38, 0.65, 0.42 },
        color_pressed = { 0.22, 0.42, 0.28 },
        color_border  = { 0.45, 0.65, 0.50 },
        color_text    = { 0.95, 0.95, 0.95 },
        on_click = function() close_dialog(true) end,
    }

    local title_lbl = W.Text.new {
        text = "Preferencias del terminal",
        font = "DejaVu Sans Bold 11",
        align = "left", valign = "center",
        r = T.fg_rgb[1], g = T.fg_rgb[2], b = T.fg_rgb[3],
        min_height = 20,
    }

    local buttons = W.Group.new {
        orientation = "horizontal",
        spacing = 8,
        children = {
            { widget = W.Text.new { text = "", min_width = 1 }, weight = 1 },
            { widget = btn_close, weight = 0 },
            { widget = btn_apply, weight = 0 },
        },
    }

    local body = W.Group.new {
        orientation = "vertical",
        spacing = 10,
        padding = PAD,
        children = {
            { widget = title_lbl, weight = 0 },
            { widget = tabbed,    weight = 1 },
            { widget = buttons,   weight = 0 },
        },
    }

    local px = math.floor((parent.width  - WIN_W) / 2)
    local py = math.floor((parent.height - WIN_H) / 2)
    if px < 10 then px = 10 end
    if py < 10 then py = 10 end

    win = Window.new(srv, {
        parent_window = parent,
        kind          = "child",
        width  = WIN_W,
        height = WIN_H,
        x      = px,
        y      = py,
        disable_q_close = true,
        title = "Preferencias",
        on_draw = function(cr, cw, ch)
            local bg  = T.bg_card_rgb or T.bg_rgb
            local sep = T.separator_rgb or { 0.2, 0.2, 0.2 }
            cairo.set_rgb(cr, bg[1], bg[2], bg[3])
            cairo.rectangle(cr, 0, 0, cw, ch)
            cairo.fill(cr)
            cairo.set_rgb(cr, sep[1], sep[2], sep[3])
            cairo.set_line_width(cr, 1)
            cairo.rectangle(cr, 0.5, 0.5, cw - 1, ch - 1)
            cairo.stroke(cr)
        end,
        on_key = function(key)
            -- Si el tab de atajos esta capturando una tecla, el
            -- consume. Escape cancela la captura, no cierra la
            -- ventana.
            if tab_atajos.handle_key(key) then return end
            if key.pressed and key.name == "Escape" then
                close_dialog(false)
            end
        end,
        on_mouse = function(mx, my, button)
            if button ~= 1 then return end
            if mx < 0 or my < 0 or mx >= WIN_W or my >= WIN_H then
                close_dialog(false)
            end
        end,
    })

    win:set_root(body)
    xcb.grab_pointer(srv.conn, win.id)

    _current = { close = function() close_dialog(false) end }
    log.info("preferences", "abiertas")
end

function M.close_current()
    if _current then _current:close() end
end

return M
