-- Pager settings moved from the old top-8% ButtonDialog into the bottom reader
-- config dialog (new Bluetooth tab, right before the settings tab). The table
-- is loaded with stubbed device/optionsutil modules so the assertions run
-- without a device or the font/UI stack; the viewer side is checked at source
-- level because that module pulls in the whole reader UI.

return function(t)
    local function read_src(name)
        local handle = io.open((t.spec_dir or "spec") .. "/../src/" .. name, "rb")
        if not handle then return "" end
        local body = handle:read("*a")
        handle:close()
        return body or ""
    end

    ----------------------------------------------------------------
    -- Load the real option table with a fake pager + device stubs
    ----------------------------------------------------------------
    -- Restore every key explicitly: a key whose saved value is nil would be
    -- dropped from a table constructor and would stay stubbed for later specs.
    local stub_names = { "device", "ui/data/optionsutil", "kamareoptions", "kamarepager" }
    local saved = {}
    for __, name in ipairs(stub_names) do saved[name] = package.loaded[name] end
    local fake_pager = { enabled = false, flipped = false }
    function fake_pager.is_enabled() return fake_pager.enabled end
    function fake_pager.swipe_flipped() return fake_pager.flipped end
    package.loaded["device"] = { hasFrontlight = function() return false end }
    package.loaded["ui/data/optionsutil"] = {
        enableIfEquals = function() return false end,
        showValues = function() end,
    }
    package.loaded["kamareoptions"] = nil
    package.loaded["kamarepager"] = fake_pager

    local ok, options = pcall(require, "kamareoptions")

    local function restore()
        for __, name in ipairs(stub_names) do
            package.loaded[name] = saved[name]
        end
    end

    if not ok then
        restore()
        t.ok(false, "P1: kamareoptions loads: " .. tostring(options))
        return
    end

    ----------------------------------------------------------------
    -- Tab position and icon
    ----------------------------------------------------------------
    t.eq(#options, 4, "P1: four config tabs")
    t.eq(options.pager_panel, 3, "P1: pager_panel points at the third tab")

    local panel = options[options.pager_panel]
    t.ok(panel ~= nil and panel.options ~= nil, "P1: the pager tab exists at that index")
    t.ok(options[4].icon == "appbar.settings", "P1: the settings tab stays last")

    local icon = panel and panel.icon
    t.ok(type(icon) == "string" and icon:find("icons/bluetooth", 1, true) ~= nil,
        "P1: the pager tab uses the plugin's Bluetooth icon")
    local lfs = require("libs/libkoreader-lfs")
    t.ok(icon and lfs.attributes("resources/icons/mdlight/" .. icon .. ".svg", "mode") == "file",
        "P1: the Bluetooth icon resolves through IconWidget's lookup path")

    local icon_file = io.open((t.spec_dir or "spec") .. "/../src/icons/bluetooth.svg", "rb")
    local icon_svg = icon_file and icon_file:read("*a") or ""
    if icon_file then icon_file:close() end
    t.ok(icon_svg:find('fill="none"', 1, true) ~= nil
        and icon_svg:find("stroke-width", 1, true) ~= nil,
        "P1: the Bluetooth icon is a thin stroke glyph, not a solid fill")

    ----------------------------------------------------------------
    -- Rows -> events, values and live state
    ----------------------------------------------------------------
    local rows = {}
    for __, row in ipairs((panel and panel.options) or {}) do
        rows[row.name] = row
    end

    local expected = {
        { "pager_rescan", "RescanPager" },
        { "pager_save_diagnostics", "SavePagerDiagnostics" },
        { "pager_sniff", "SniffPagerKeys" },
        { "pager_diagnostics", "ShowPagerDiagnostics" },
        { "pager_swipe_inverted", "SetPagerSwipeInverted" },
        { "pager_keys", "ShowPagerKeys" },
        { "pager_enabled", "SetPagerEnabled" },
    }
    for __, spec in ipairs(expected) do
        local name, event = spec[1], spec[2]
        t.ok(rows[name] ~= nil, "P2: the pager tab exposes " .. name)
        t.eq(rows[name] and rows[name].event, event,
            "P2: " .. name .. " dispatches " .. event)
    end

    -- The two real settings read Pager's live state instead of storing a
    -- duplicate copy in the reader configurable.
    local enabled_row = rows.pager_enabled
    if enabled_row and enabled_row.current_func then
        fake_pager.enabled = false
        t.eq(enabled_row.current_func(), 0, "P3: enable row shows off when Pager is off")
        fake_pager.enabled = true
        t.eq(enabled_row.current_func(), 1, "P3: enable row shows on when Pager is on")
        t.eq(enabled_row.values[1], 0, "P3: enable row maps the off toggle to 0")
        t.eq(enabled_row.values[2], 1, "P3: enable row maps the on toggle to 1")
    else
        t.ok(false, "P3: enable row has a current_func")
    end

    local swipe_row = rows.pager_swipe_inverted
    if swipe_row and swipe_row.current_func then
        fake_pager.flipped = false
        t.eq(swipe_row.current_func(), 0, "P3: swipe row shows normal")
        fake_pager.flipped = true
        t.eq(swipe_row.current_func(), 1, "P3: swipe row shows inverted")
        t.eq(swipe_row.values[1], 0, "P3: swipe row maps normal to 0")
        t.eq(swipe_row.values[2], 1, "P3: swipe row maps inverted to 1")
    else
        t.ok(false, "P3: swipe row has a current_func")
    end

    restore()

    ----------------------------------------------------------------
    -- Viewer wiring (source-level: loading the viewer needs the UI stack)
    ----------------------------------------------------------------
    local viewer = read_src("kamareimageviewer.lua")

    local handlers = {
        { "onSetPagerEnabled", "Pager.set_enabled(tonumber(enabled) == 1)" },
        { "onShowPagerKeys", "Pager.show_bindings()" },
        { "onSetPagerSwipeInverted", "Pager.set_swipe_flipped(tonumber(inverted) == 1)" },
        { "onShowPagerDiagnostics", "Pager.show_diagnostics()" },
        { "onSniffPagerKeys", "Pager.sniff_for(30)" },
        { "onSavePagerDiagnostics", "Pager.save_diagnostics()" },
        { "onRescanPager", "Pager.rescan()" },
    }
    for __, spec in ipairs(handlers) do
        local handler, call = spec[1], spec[2]
        t.ok(viewer:find("function KamareImageViewer:" .. handler, 1, true) ~= nil,
            "P4: " .. handler .. " exists")
        t.ok(viewer:find(call, 1, true) ~= nil,
            "P4: " .. handler .. " calls " .. call)
    end

    t.ok(viewer:find("self.options.pager_panel", 1, true) ~= nil,
        "P5: the top-8% shortcut opens the pager tab")
    t.ok(viewer:find("onShowConfigPanel(panel_index or 1)", 1, true) ~= nil,
        "P5: onShowConfigMenu honours the requested tab")
    t.ok(viewer:find('title = _("Pager")', 1, true) == nil,
        "P5: the old standalone pager dialog is gone")

    -- Device-level pager state must not leak into per-series reading settings.
    t.ok(viewer:find("self.configurable.pager_enabled", 1, true) == nil,
        "P5: the enable switch is not saved as a reading setting")
    t.ok(viewer:find("self.configurable.pager_swipe_inverted", 1, true) == nil,
        "P5: the swipe switch is not saved as a reading setting")
end
