-- Information architecture of the reader config dialog: five tabs, each a
-- single concern, and every option lives in exactly one panel.

return function(t)
    local stub_names = { "device", "ui/data/optionsutil", "kamareoptions", "kamarepager" }
    local saved = {}
    for __, name in ipairs(stub_names) do saved[name] = package.loaded[name] end

    package.loaded["device"] = { hasFrontlight = function() return false end }
    package.loaded["ui/data/optionsutil"] = {
        enableIfEquals = function(configurable, key, value)
            return configurable[key] == value
        end,
        showValues = function() end,
    }
    package.loaded["kamareoptions"] = nil
    package.loaded["kamarepager"] = {
        is_enabled = function() return true end,
        swipe_flipped = function() return false end,
    }

    local ok, options = pcall(require, "kamareoptions")
    local function restore()
        for __, name in ipairs(stub_names) do
            package.loaded[name] = saved[name]
        end
    end

    if not ok then
        restore()
        t.ok(false, "IA1: kamareoptions loads: " .. tostring(options))
        return
    end

    local function names(panel)
        local out = {}
        for __, row in ipairs((panel and panel.options) or {}) do
            out[#out + 1] = row.name
        end
        return table.concat(out, ",")
    end

    local function row(panel, name)
        for __, r in ipairs((panel and panel.options) or {}) do
            if r.name == name then return r end
        end
        return nil
    end

    ----------------------------------------------------------------
    -- Tabs
    ----------------------------------------------------------------
    t.eq(#options, 5, "IA1: five tabs")
    t.eq(options[1].icon, "appbar.pageview", "IA1: reading tab")
    t.eq(options[2].icon, "appbar.pagefit", "IA1: layout tab")
    t.eq(options[3].icon, "appbar.tools", "IA1: interaction tab")
    t.ok(options[4].icon:find("icons/bluetooth", 1, true) ~= nil, "IA1: pager tab")
    t.eq(options[5].icon, "appbar.settings", "IA1: settings tab")
    t.eq(options.pager_panel, 4, "IA1: the pager shortcut points at the Bluetooth tab")

    ----------------------------------------------------------------
    -- Panel contents
    ----------------------------------------------------------------
    t.eq(names(options[1]),
        "view_mode,page_direction,wide_page_mode,split_wide_direction,crop_borders,footer_mode,chapter_end_behavior",
        "IA2: reading tab holds reading behaviour only")
    t.eq(names(options[2]),
        "zoom_mode_type,h_margin,top_margin,bottom_margin,page_gap_height,dual_page_gap,scroll_distance,background_color",
        "IA2: layout tab holds fit, margins, gaps and appearance")
    t.eq(names(options[3]),
        "magnifier_scope,magnifier_zoom,long_press_magnifier,join_direction,swipe_down_join",
        "IA2: interaction tab holds magnifier and join")
    t.eq(names(options[4]),
        "pager_tools,pager_swipe_inverted,pager_keys,pager_enabled",
        "IA2: pager tab holds settings, diagnostics behind one row")
    t.eq(names(options[5]),
        "prefetch_pages,render_quality,contrast,color_boost,rotation_lock,frontlight",
        "IA2: settings tab holds rendering and device controls")

    -- No option may appear twice (a copy-paste move is easy to get wrong).
    local seen, duplicate = {}, nil
    for __, panel in ipairs(options) do
        for __, r in ipairs(panel.options or {}) do
            if seen[r.name] then duplicate = r.name end
            seen[r.name] = true
        end
    end
    t.eq(duplicate, nil, "IA3: every option appears in exactly one panel")

    ----------------------------------------------------------------
    -- The join switch
    ----------------------------------------------------------------
    local join = row(options[3], "swipe_down_join")
    t.ok(join ~= nil, "IA4: the join switch exists in the interaction tab")
    if join then
        t.eq(join.default_value, 1, "IA4: the join switch defaults to on")
        t.eq(join.event, "SetSwipeDownJoin", "IA4: the switch dispatches its own event")
        t.eq(join.values[1], 0, "IA4: off maps to 0")
        t.eq(join.values[2], 1, "IA4: on maps to 1")
        t.ok(join.enabled_func({ view_mode = 0 }) == true,
            "IA4: the switch is enabled in page mode")
        t.ok(join.enabled_func({ view_mode = 1 }) == false,
            "IA4: the switch is disabled in continuous mode")
        t.ok(join.enabled_func({ view_mode = 2 }) == false,
            "IA4: the switch is disabled in dual mode")
    end

    local tools = row(options[4], "pager_tools")
    t.ok(tools ~= nil, "IA5: pager tools row exists")
    t.eq(tools and tools.event, "ShowPagerTools", "IA5: pager tools dispatches ShowPagerTools")

    ----------------------------------------------------------------
    -- Join direction
    ----------------------------------------------------------------
    local direction = row(options[3], "join_direction")
    t.ok(direction ~= nil, "IA6: the join direction row exists")
    if direction then
        t.eq(direction.default_value, 0, "IA6: auto by default")
        t.eq(direction.event, "SetJoinDirection", "IA6: dispatches SetJoinDirection")
        t.eq(direction.values[1], 0, "IA6: auto maps to 0")
        t.eq(direction.values[2], 1, "IA6: LTR maps to 1")
        t.eq(direction.values[3], 2, "IA6: RTL maps to 2")
        t.ok(direction.enabled_func({ view_mode = 0, swipe_down_join = 1 }) == true,
            "IA6: enabled when the join is on in page mode")
        t.ok(direction.enabled_func({ view_mode = 0, swipe_down_join = 0 }) == false,
            "IA6: disabled when the join is off")
        t.ok(direction.enabled_func({ view_mode = 1, swipe_down_join = 1 }) == false,
            "IA6: disabled outside page mode")
    end

    restore()
end
