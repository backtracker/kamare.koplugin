-- Long-press magnifier geometry (pure module, no device).
--
-- The fragile part is mapping the finger from screen space back into
-- page-native coordinates and clamping the loupe to the page; assert that
-- arithmetic without instantiating the UI.

local Magnifier = require("kamaremagnifier")

local function base(overrides)
    local o = {
        canvas_w = 600,
        canvas_h = 800,
        h_margin = 0,
        top_margin = 0,
        bottom_margin = 0,
        native_w = 800,
        native_h = 1200,
        zoom = 0.5,
        zoom_mode = 0,
        center_x = 0.5,
        center_y = 0.5,
        finger_x = 300,
        finger_y = 400,
        edge_gap = 0,
    }
    for k, v in pairs(overrides or {}) do o[k] = v end
    return o
end

return function(t)
    -- Page 800x1200 at 0.5 => 400x600 centred in a 600x800 canvas:
    -- dest = (100,100), so finger (300,400) is page (400,600).
    local l = Magnifier.layout(base())
    t.ok(l ~= nil, "M1: layout exists")
    t.eq(l.w, math.floor(600 * 0.55), "M1: loupe is 55% of the short side")
    t.eq(l.h, l.w, "M1: loupe is square")

    -- The reader-config size scales the window; 55% stays the default.
    l = Magnifier.layout(base{ size_ratio = 0.70 })
    t.eq(l.w, math.floor(600 * 0.70), "M1b: 70% window")
    t.eq(l.h, l.w, "M1b: window stays square")
    l = Magnifier.layout(base{ size_ratio = 2.0 })
    t.eq(l.w, math.floor(600 * Magnifier.MAX_SIZE_RATIO),
        "M1b: oversized value clamps to the max")
    l = Magnifier.layout(base{ size_ratio = 0.01 })
    t.eq(l.w, math.floor(600 * Magnifier.MIN_SIZE_RATIO),
        "M1b: undersized value clamps to the min")
    t.eq(l.zoom, 1.0, "M1: 0.5 zoom magnifies to the 1.0 floor")
    t.near(l.src.x + l.src.w / 2, 400, 0.001, "M1: finger maps to page x")
    t.near(l.src.y + l.src.h / 2, 600, 0.001, "M1: finger maps to page y")

    -- Zooming the page in also raises the loupe zoom, capped at a safety max.
    l = Magnifier.layout(base{ zoom = 0.8 })
    t.near(l.zoom, 1.6, 0.001, "M2: loupe zoom follows the page zoom")
    -- 800x1200 at 0.8 overflows the 600x800 canvas: the visible rect starts
    -- at x=25, so finger x=300 is page x=400.
    t.near(l.src.x + l.src.w / 2, 400, 0.001, "M2: x still maps to the finger")
    l = Magnifier.layout(base{ zoom = 4.0 })
    t.eq(l.zoom, Magnifier.MAX_ZOOM, "M2: loupe zoom is capped")

    -- The reader-config factor scales the loupe zoom relative to the page.
    l = Magnifier.layout(base{ magnify_factor = 1.5 })
    t.near(l.zoom, 0.75, 0.001, "M2b: 1.5x level")
    l = Magnifier.layout(base{ magnify_factor = 2.5 })
    t.near(l.zoom, 1.25, 0.001, "M2b: 2.5x level")
    l = Magnifier.layout(base{ magnify_factor = 99 })
    t.near(l.zoom, 1.5, 0.001, "M2b: out-of-range factor clamps to the max")
    l = Magnifier.layout(base{ magnify_factor = 0 })
    t.near(l.zoom, 0.5, 0.001, "M2b: out-of-range low factor clamps to 1x")

    -- Clamping: the source window never leaves the page.
    l = Magnifier.layout(base{ finger_x = 0, finger_y = 0, edge_gap = 0 })
    t.ok(l.src.x >= 0 and l.src.y >= 0, "M3: top-left stays inside")
    l = Magnifier.layout(base{ finger_x = 600, finger_y = 800 })
    t.ok(l.src.x + l.src.w <= 800.001, "M3: right edge stays inside")
    t.ok(l.src.y + l.src.h <= 1200.001, "M3: bottom edge stays inside")

    -- The loupe itself stays on the canvas.
    l = Magnifier.layout(base{ finger_x = 0, finger_y = 0, edge_gap = 0 })
    t.ok(l.x >= 0 and l.y >= 0, "M4: loupe does not leave the canvas")
    l = Magnifier.layout(base{ finger_x = 600, finger_y = 800, edge_gap = 0 })
    t.ok(l.x + l.w <= 600.001, "M4: loupe stays inside on the right")
    t.ok(l.y + l.h <= 800.001, "M4: loupe stays inside at the bottom")

    -- Near the top edge the loupe flips below the finger.
    l = Magnifier.layout(base{ finger_y = 10, edge_gap = 60 })
    t.ok(l.y >= 10, "M5: loupe flips below the finger near the top")

    -- Panned pages (zoom_mode 1/2) use the canvas centre ratios.
    l = Magnifier.layout(base{ zoom_mode = 2, zoom = 1.0, center_y = 0.0 })
    t.near(l.src.y + l.src.h / 2, 400, 0.001,
        "M6: panned page maps the finger through the centre ratio")

    -- Degenerate inputs.
    t.is_nil(Magnifier.layout(base{ canvas_w = 0 }), "M7: no canvas")
    t.is_nil(Magnifier.layout(base{ native_w = 0 }), "M7: no page dimensions")
    t.is_nil(Magnifier.layout(base{ h_margin = 400 }), "M7: margins swallow the viewport")

    -- A page smaller than the loupe is magnified but not beyond its bounds.
    l = Magnifier.layout(base{ native_w = 300, native_h = 400, zoom = 1.0 })
    t.ok(l.src.x >= 0 and l.src.x + l.src.w <= 300.001, "M8: small page stays inside x")
    t.ok(l.src.y >= 0 and l.src.y + l.src.h <= 400.001, "M8: small page stays inside y")
end
