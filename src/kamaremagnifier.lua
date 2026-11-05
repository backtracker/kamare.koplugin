--[[--
Geometry for the long-press magnifier.

Pure arithmetic: given the canvas/page metrics and the finger position, work
out where the magnified window goes and which part of the page it shows.
Kept out of VirtualPageCanvas so it can be tested without a device.

All inputs are pixels; `zoom` is the page's current display zoom. The result
is a plain table (no Geom), the canvas wraps `src` when drawing.
--]]

local Math = require("optmath")

local Magnifier = {}

-- Fraction of the screen's short side used by the loupe.
-- The reader config menu overrides this per book/globally.
Magnifier.SIZE_RATIO = 0.55
Magnifier.MIN_SIZE_RATIO = 0.45
Magnifier.MAX_SIZE_RATIO = 1.00
-- How much bigger than the page's current display zoom the loupe is.
-- The reader config menu overrides this per book/globally.
Magnifier.MAGNIFY_FACTOR = 2.0
Magnifier.MIN_FACTOR = 1.0
Magnifier.MAX_FACTOR = 3.0
Magnifier.MIN_ZOOM = 0.1
-- Absolute render-zoom ceiling. The option is a factor relative to the page
-- zoom, so this must leave room for the largest factor on a fit-height page.
Magnifier.MAX_ZOOM = 6.0

--- @param o table
---   canvas_w, canvas_h, h_margin, top_margin, bottom_margin,
---   native_w, native_h, zoom, zoom_mode, center_x, center_y,
---   finger_x, finger_y, edge_gap, size_ratio, magnify_factor
--- @return table|nil { x, y, w, h, zoom, src = { x, y, w, h } }
function Magnifier.layout(o)
    o = o or {}
    local canvas_w, canvas_h = o.canvas_w, o.canvas_h
    if not canvas_w or not canvas_h or canvas_w <= 0 or canvas_h <= 0 then
        return nil
    end
    local native_w, native_h = o.native_w, o.native_h
    if not native_w or not native_h or native_w <= 0 or native_h <= 0 then
        return nil
    end

    local h_margin = o.h_margin or 0
    local top_margin = o.top_margin or 0
    local bottom_margin = o.bottom_margin or 0
    local viewport_w = math.floor(math.max(0, canvas_w - 2 * h_margin))
    local viewport_h = math.floor(math.max(0, canvas_h - top_margin - bottom_margin))
    if viewport_w <= 0 or viewport_h <= 0 then return nil end

    local zoom = o.zoom or 1
    if zoom <= 0 then zoom = 1 end

    -- Same projection as paintSinglePage, inverted below.
    local scaled_w, scaled_h = native_w * zoom, native_h * zoom
    local view_w = math.min(viewport_w, scaled_w)
    local view_h = math.min(viewport_h, scaled_h)
    local cx = (o.zoom_mode == 0) and 0.5 or Math.clamp(o.center_x or 0.5, 0, 1)
    local cy = (o.zoom_mode == 0) and 0.5 or Math.clamp(o.center_y or 0.5, 0, 1)
    local src_x = Math.clamp(math.floor(cx * scaled_w - view_w / 2), 0,
        math.max(0, scaled_w - view_w))
    local src_y = Math.clamp(math.floor(cy * scaled_h - view_h / 2), 0,
        math.max(0, scaled_h - view_h))

    local rect_x = src_x / zoom
    local rect_y = src_y / zoom
    local rect_w = view_w / zoom
    local rect_h = view_h / zoom
    local dest_x = h_margin + math.floor((viewport_w - view_w) / 2)
    local dest_y = top_margin + math.floor((viewport_h - view_h) / 2)

    local px = Math.clamp(o.finger_x, dest_x, dest_x + view_w)
    local py = Math.clamp(o.finger_y, dest_y, dest_y + view_h)
    local page_x = Math.clamp(rect_x + (px - dest_x) / zoom, rect_x, rect_x + rect_w)
    local page_y = Math.clamp(rect_y + (py - dest_y) / zoom, rect_y, rect_y + rect_h)

    local short = math.min(canvas_w, canvas_h)
    local size_ratio = tonumber(o.size_ratio) or Magnifier.SIZE_RATIO
    size_ratio = Math.clamp(size_ratio,
        Magnifier.MIN_SIZE_RATIO, Magnifier.MAX_SIZE_RATIO)
    local loupe_w = math.floor(short * size_ratio)
    local loupe_h = loupe_w
    local factor = tonumber(o.magnify_factor) or Magnifier.MAGNIFY_FACTOR
    factor = Math.clamp(factor, Magnifier.MIN_FACTOR, Magnifier.MAX_FACTOR)
    local loupe_zoom = Math.clamp(zoom * factor,
        Magnifier.MIN_ZOOM, Magnifier.MAX_ZOOM)
    local src_w = math.min(loupe_w / loupe_zoom, rect_w)
    local src_h = math.min(loupe_h / loupe_zoom, rect_h)
    local sx = Math.clamp(page_x - src_w / 2, rect_x, rect_x + rect_w - src_w)
    local sy = Math.clamp(page_y - src_h / 2, rect_y, rect_y + rect_h - src_h)

    local edge_gap = o.edge_gap or 0
    local loupe_x = math.floor(px - loupe_w / 2)
    loupe_x = Math.clamp(loupe_x, 0, math.max(0, canvas_w - loupe_w))
    local loupe_y = math.floor(py - loupe_h - edge_gap)
    if loupe_y < 0 then loupe_y = math.floor(py + edge_gap) end
    loupe_y = Math.clamp(loupe_y, 0, math.max(0, canvas_h - loupe_h))

    return {
        x = loupe_x,
        y = loupe_y,
        w = loupe_w,
        h = loupe_h,
        zoom = loupe_zoom,
        src = { x = sx, y = sy, w = src_w, h = src_h },
    }
end

return Magnifier
