--[[--
Unit tests for the experimental pen-width picker.

Covers:
- setPenWidth mutates tool_settings and triggers saveSettings
- Width round-trips through saveSettings / loadSettings
- available_widths shape
- Picker item list respects the experimental_pen_width gate
- Picker callback routes width taps through width_value (not by name match)
- Width is validated on load so a bad settings file cannot inject junk

Run with: busted spec/pen_width_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local TOOL_PEN = "pen"

-- Mock pencil that mirrors the width-related behaviour in main.lua.
-- Kept intentionally small — only the state touched by the pen-width feature.
local function createMockPencil(opts)
    opts = opts or {}

    local mock = {
        tool_settings = {
            [TOOL_PEN] = {
                width = 3,
                color = { value = 0x00 },
                color_name = "Black",
            },
        },
        available_colors = {
            { name = "Black", color = { value = 0x00 } },
            { name = "Red",   color = { value = 0xFF } },
        },
        available_widths = {
            { name = "w3", width = 3 },
            { name = "w5", width = 5 },
            { name = "w7", width = 7 },
            { name = "w9", width = 9 },
        },
        experimental_pen_width = opts.experimental_pen_width or false,
        experimental_color_picker = opts.experimental_color_picker or false,

        -- Hold-pen-still gesture state
        color_picker_start_time = nil,
        color_picker_showing = false,
        _picker_shown = false,

        -- Mirror of G_reader_settings for this test
        _settings_store = opts.settings or {},
        _save_count = 0,
    }

    function mock:saveSettings()
        self._save_count = self._save_count + 1
        self._settings_store = {
            experimental_pen_width = self.experimental_pen_width,
            experimental_color_picker = self.experimental_color_picker,
            pen_color_name = self.tool_settings[TOOL_PEN].color_name,
            pen_width = self.tool_settings[TOOL_PEN].width,
        }
    end

    function mock:loadSettings()
        local settings = self._settings_store or {}
        self.experimental_pen_width = settings.experimental_pen_width or false
        self.experimental_color_picker = settings.experimental_color_picker or false
        local saved_width = settings.pen_width
        if saved_width then
            for _, w in ipairs(self.available_widths) do
                if w.width == saved_width then
                    self.tool_settings[TOOL_PEN].width = saved_width
                    break
                end
            end
        end
    end

    function mock:setPenWidth(width)
        self.tool_settings[TOOL_PEN].width = width
        self:saveSettings()
    end

    -- Mirrors checkColorPickerTrigger's gate: the hold-pen-still gesture
    -- only opens the picker when experimental_color_picker is on.
    function mock:checkColorPickerTrigger()
        if not self.experimental_color_picker then return false end
        if not self.color_picker_start_time then return false end
        if self.color_picker_showing then return false end
        self._picker_shown = true
        self.color_picker_showing = true
        return true
    end

    -- Mirrors ColorPickerWidget:init()'s per-row item construction. Colors
    -- and widths live in separate rows; returning them as two lists lets
    -- tests assert on both the layout and the gate without poking at widget
    -- internals.
    function mock:buildPickerRows()
        local color_items = {}
        for _, c in ipairs(self.available_colors) do
            table.insert(color_items, {
                kind = "color",
                name = c.name,
                color_value = c.color,
            })
        end
        local width_items = {}
        if self.experimental_pen_width then
            for _, w in ipairs(self.available_widths) do
                table.insert(width_items, {
                    kind = "width",
                    name = w.name,
                    width_value = w.width,
                })
            end
        end
        return color_items, width_items
    end

    -- Back-compat for any test that just wants the flat list of visible items.
    function mock:buildPickerItems()
        local colors, widths = self:buildPickerRows()
        local items = {}
        for _, c in ipairs(colors) do table.insert(items, c) end
        for _, w in ipairs(widths) do table.insert(items, w) end
        return items
    end

    -- Mirrors the picker callback in showColorPicker
    function mock:pickerCallback(color_value, color_name, width_value)
        if width_value then
            self:setPenWidth(width_value)
            return "width"
        end
        self.tool_settings[TOOL_PEN].color = color_value
        self.tool_settings[TOOL_PEN].color_name = color_name
        self:saveSettings()
        return "color"
    end

    return mock
end


describe("available_widths", function()

    it("exposes four widths in ascending order", function()
        local pencil = createMockPencil()
        assert.equals(4, #pencil.available_widths)
        assert.equals(3, pencil.available_widths[1].width)
        assert.equals(5, pencil.available_widths[2].width)
        assert.equals(7, pencil.available_widths[3].width)
        assert.equals(9, pencil.available_widths[4].width)
    end)

    it("uses non-numeric names to avoid collision with color names", function()
        local pencil = createMockPencil()
        for _, w in ipairs(pencil.available_widths) do
            -- Names must not be parseable as bare integers (e.g. "3") because
            -- a previous prototype string-matched on name to detect widths
            -- and any future color named "3" would collide silently.
            assert.is_nil(tonumber(w.name), "width name " .. tostring(w.name) .. " is a bare number")
        end
    end)

end)


describe("setPenWidth", function()

    it("updates the pen tool's width", function()
        local pencil = createMockPencil()
        pencil:setPenWidth(7)
        assert.equals(7, pencil.tool_settings[TOOL_PEN].width)
    end)

    it("triggers saveSettings", function()
        local pencil = createMockPencil()
        local before = pencil._save_count
        pencil:setPenWidth(5)
        assert.equals(before + 1, pencil._save_count)
    end)

end)


describe("width persistence", function()

    it("round-trips a selected width through save/load", function()
        local pencil = createMockPencil()
        pencil:setPenWidth(9)

        local fresh = createMockPencil({ settings = pencil._settings_store })
        fresh:loadSettings()

        assert.equals(9, fresh.tool_settings[TOOL_PEN].width)
    end)

    it("defaults to 3 when no saved width exists", function()
        local fresh = createMockPencil({ settings = {} })
        fresh:loadSettings()
        assert.equals(3, fresh.tool_settings[TOOL_PEN].width)
    end)

    it("rejects a saved width that is not in available_widths", function()
        -- A malformed settings file should not inject arbitrary widths.
        -- Default (3) must win.
        local fresh = createMockPencil({ settings = { pen_width = 42 } })
        fresh:loadSettings()
        assert.equals(3, fresh.tool_settings[TOOL_PEN].width)
    end)

    it("preserves the experimental toggle across save/load", function()
        local pencil = createMockPencil()
        pencil.experimental_pen_width = true
        pencil:saveSettings()

        local fresh = createMockPencil({ settings = pencil._settings_store })
        fresh:loadSettings()

        assert.is_true(fresh.experimental_pen_width)
    end)

end)


describe("picker item list (gate-aware)", function()

    it("omits width items when the flag is off", function()
        local pencil = createMockPencil({ experimental_pen_width = false })
        local items = pencil:buildPickerItems()

        for _, item in ipairs(items) do
            assert.not_equals("width", item.kind)
        end
        assert.equals(#pencil.available_colors, #items)
    end)

    it("appends width items after colors when the flag is on", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local items = pencil:buildPickerItems()

        assert.equals(#pencil.available_colors + #pencil.available_widths, #items)
        -- Colors come first
        for i = 1, #pencil.available_colors do
            assert.equals("color", items[i].kind)
        end
        -- Widths come last
        for i = #pencil.available_colors + 1, #items do
            assert.equals("width", items[i].kind)
        end
    end)

    it("preserves width order in the item list", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local items = pencil:buildPickerItems()

        local width_items = {}
        for _, item in ipairs(items) do
            if item.kind == "width" then
                table.insert(width_items, item.width_value)
            end
        end

        assert.same({ 3, 5, 7, 9 }, width_items)
    end)

end)


describe("picker row layout", function()

    it("puts widths in a separate row from colors when flag is on", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local color_row, width_row = pencil:buildPickerRows()

        -- Colors and widths are returned as distinct lists. If anyone ever
        -- folds them back into a single row, this test fails loudly.
        assert.equals(#pencil.available_colors, #color_row)
        assert.equals(#pencil.available_widths, #width_row)
        for _, item in ipairs(color_row) do
            assert.equals("color", item.kind)
        end
        for _, item in ipairs(width_row) do
            assert.equals("width", item.kind)
        end
    end)

    it("leaves the width row empty when flag is off", function()
        local pencil = createMockPencil({ experimental_pen_width = false })
        local color_row, width_row = pencil:buildPickerRows()
        assert.equals(#pencil.available_colors, #color_row)
        assert.equals(0, #width_row)
    end)

end)


describe("picker callback routing", function()

    it("routes a width tap through setPenWidth", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local result = pencil:pickerCallback(nil, "w7", 7)

        assert.equals("width", result)
        assert.equals(7, pencil.tool_settings[TOOL_PEN].width)
    end)

    it("does not mutate pen color on a width tap", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local original_color_name = pencil.tool_settings[TOOL_PEN].color_name

        pencil:pickerCallback(nil, "w5", 5)

        assert.equals(original_color_name, pencil.tool_settings[TOOL_PEN].color_name)
    end)

    it("routes a color tap through setPenColor (not setPenWidth)", function()
        local pencil = createMockPencil({ experimental_pen_width = true })
        local red = pencil.available_colors[2].color

        local result = pencil:pickerCallback(red, "Red", nil)

        assert.equals("color", result)
        assert.equals("Red", pencil.tool_settings[TOOL_PEN].color_name)
        -- Width stays at its default, not overwritten
        assert.equals(3, pencil.tool_settings[TOOL_PEN].width)
    end)

    it("distinguishes width from color without string-matching the name", function()
        -- Regression guard: a color named "3" must still be treated as a color.
        -- The callback discriminates on the width_value arg, not the name.
        local pencil = createMockPencil({ experimental_pen_width = true })
        local fake_color = { value = 0xAB }

        pencil:pickerCallback(fake_color, "3", nil)

        assert.equals("3", pencil.tool_settings[TOOL_PEN].color_name)
        assert.equals(fake_color, pencil.tool_settings[TOOL_PEN].color)
        -- Width unchanged
        assert.equals(3, pencil.tool_settings[TOOL_PEN].width)
    end)

end)


describe("experimental_color_picker gate", function()

    it("defaults to off", function()
        local pencil = createMockPencil()
        assert.is_false(pencil.experimental_color_picker)
    end)

    it("suppresses the hold-pen-still trigger when off", function()
        local pencil = createMockPencil({ experimental_color_picker = false })
        pencil.color_picker_start_time = 1000  -- would normally cause trigger

        local opened = pencil:checkColorPickerTrigger()

        assert.is_false(opened)
        assert.is_false(pencil.color_picker_showing)
    end)

    it("allows the trigger when on", function()
        local pencil = createMockPencil({ experimental_color_picker = true })
        pencil.color_picker_start_time = 1000

        local opened = pencil:checkColorPickerTrigger()

        assert.is_true(opened)
        assert.is_true(pencil.color_picker_showing)
    end)

    it("round-trips the flag through save/load", function()
        local pencil = createMockPencil({ experimental_color_picker = true })
        pencil:saveSettings()

        local fresh = createMockPencil({ settings = pencil._settings_store })
        fresh:loadSettings()

        assert.is_true(fresh.experimental_color_picker)
    end)

    it("is independent of experimental_pen_width", function()
        -- Width picker flag on but color picker off: gesture still suppressed
        -- (the width picker rides inside the color picker, so without it
        -- opening, width rows are unreachable).
        local pencil = createMockPencil({
            experimental_pen_width = true,
            experimental_color_picker = false,
        })
        pencil.color_picker_start_time = 1000

        local opened = pencil:checkColorPickerTrigger()

        assert.is_false(opened)
    end)

end)
