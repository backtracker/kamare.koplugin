-- Source-level wiring checks for the long-press magnifier. Rendering and
-- gestures need a real device; these assertions catch accidental removal or
-- rename of the plumbing (same approach as pager A21).

return function(t)
    local function read_src(name)
        local handle = io.open((t.spec_dir or "spec") .. "/../src/" .. name, "rb")
        if not handle then return "" end
        local body = handle:read("*a")
        handle:close()
        return body or ""
    end

    local viewer = read_src("kamareimageviewer.lua")
    local canvas = read_src("virtualpagecanvas.lua")
    local options = read_src("kamareoptions.lua")

    ------------------------------------------------------------------------
    -- Gesture zones
    ------------------------------------------------------------------------
    t.ok(viewer:find('id = "kamare_page_hold"', 1, true) ~= nil,
        "G1: viewer registers a page-level hold zone")
    t.ok(viewer:find('id = "kamare_page_hold_pan"', 1, true) ~= nil,
        "G1: viewer registers hold_pan (finger follows)")
    t.ok(viewer:find('id = "kamare_page_hold_release"', 1, true) ~= nil,
        "G1: viewer registers hold_release (restore on lift)")
    t.ok(viewer:find('ges = "hold_pan"', 1, true) ~= nil,
        "G1: hold_pan is the actual gesture")
    t.ok(viewer:find('ges = "hold_release"', 1, true) ~= nil,
        "G1: hold_release is the actual gesture")
    t.ok(viewer:find('overrides%s*=%s*{%s*"kamare_page_hold"') ~= nil,
        "G1: the top-8%% pager menu keeps priority over the page hold")

    ------------------------------------------------------------------------
    -- Handlers and switch
    ------------------------------------------------------------------------
    t.ok(viewer:find("function KamareImageViewer:onPageHold", 1, true) ~= nil,
        "G2: hold handler exists")
    t.ok(viewer:find("function KamareImageViewer:onPageHoldPan", 1, true) ~= nil,
        "G2: hold_pan handler exists")
    t.ok(viewer:find("function KamareImageViewer:onPageHoldRelease", 1, true) ~= nil,
        "G2: hold_release handler exists")
    t.ok(viewer:find("self.long_press_magnifier ~= 1", 1, true) ~= nil,
        "G2: the handlers honour the on/off switch")
    t.ok(viewer:find("function KamareImageViewer:onSetLongPressMagnifier", 1, true) ~= nil,
        "G2: the option event has a handler")
    t.ok(viewer:find("long_press_magnifier = self.long_press_magnifier", 1, true) ~= nil,
        "G2: the switch is persisted through configurable")
    t.ok(viewer:find("function KamareImageViewer:onMagnifierZoomUpdate", 1, true) ~= nil,
        "G2: the zoom level has a handler")
    t.ok(viewer:find("function KamareImageViewer:onMagnifierScopeUpdate", 1, true) ~= nil,
        "G2: the scope has a handler")
    t.ok(viewer:find("self.canvas.magnifier_zoom = factor", 1, true) ~= nil,
        "G2: the zoom level reaches the canvas")
    t.ok(viewer:find("self.canvas.magnifier_scope = self.magnifier_scope", 1, true) ~= nil,
        "G2: the scope reaches the canvas")
    t.ok(viewer:find("magnifier_zoom = self.magnifier_zoom", 1, true) ~= nil,
        "G2: the zoom level is persisted through configurable")
    t.ok(viewer:find("magnifier_scope = self.magnifier_scope", 1, true) ~= nil,
        "G2: the scope is persisted through configurable")

    ------------------------------------------------------------------------
    -- Canvas rendering
    ------------------------------------------------------------------------
    t.ok(canvas:find("function VirtualPageCanvas:moveLoupe", 1, true) ~= nil,
        "G3: canvas owns the magnifier position")
    t.ok(canvas:find("function VirtualPageCanvas:paintLoupe", 1, true) ~= nil,
        "G3: canvas paints the magnifier")
    t.ok(canvas:find("function VirtualPageCanvas:_loupeLayout", 1, true) ~= nil,
        "G3: canvas maps the finger into page coordinates")
    t.ok(canvas:find("magnify_factor = self.magnifier_zoom", 1, true) ~= nil,
        "G3: the zoom level is passed to the geometry")
    t.ok(canvas:find("scope_ratio = self.magnifier_scope", 1, true) ~= nil,
        "G3: the scope is passed to the geometry")
    t.ok(canvas:find("function VirtualPageCanvas:refreshLoupe", 1, true) ~= nil,
        "G3: an open loupe repaints after a zoom change")

    ------------------------------------------------------------------------
    -- Reader config menu
    ------------------------------------------------------------------------
    t.ok(options:find('name = "long_press_magnifier"', 1, true) ~= nil,
        "G4: the reader config menu exposes the switch")
    t.ok(options:find('event = "SetLongPressMagnifier"', 1, true) ~= nil,
        "G4: the switch event is wired")
    t.ok(options:find('name = "magnifier_zoom"', 1, true) ~= nil,
        "G4: the reader config menu exposes the zoom level")
    t.ok(options:find('event = "MagnifierZoomUpdate"', 1, true) ~= nil,
        "G4: the zoom event is wired")
    t.ok(options:find('name = "magnifier_scope"', 1, true) ~= nil,
        "G4: the reader config menu exposes the scope")
    t.ok(options:find('event = "MagnifierScopeUpdate"', 1, true) ~= nil,
        "G4: the window size event is wired")
end
