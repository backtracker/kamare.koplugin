-- Crop-borders detection, ported from Mihon's SSIV fork
-- (subsampling-scale-image-view: CropBorders.kt + cpp/crop/borders.cpp).
--
-- The detector works on a grayscale copy of a downscaled page. Each edge is
-- sampled to find the dominant border color (black or white), then scanned
-- inwards for the first line that contains a meaningful amount of content.
-- A tiny fill ratio (0.25%) keeps sparse line art from being cropped.
--
-- Unlike the original, probing/scanning starts a few pixels inside the edge.
-- Scanned pages often carry a dark or grey strip along one side; treating it
-- as a "black border" made the white margin right behind it look like
-- content, so that side was never cropped at all.
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local mupdf = require("ffi/mupdf")

local CropBorders = {}

local FILLED_RATIO = 0.0025
-- Anything at or above WHITE_MIN is on the white side, at or below BLACK_MAX
-- on the black side. Mid greys are neither, so a grey scan edge cannot pass
-- for a black border (the original single threshold treated everything below
-- 191 as black).
local WHITE_MIN = 191
local BLACK_MAX = 64
-- A probe line counts as a uniform margin when this share of its samples is
-- on one side of the thresholds.
local UNIFORM_RATIO = 0.97
-- Probes and scans start this far inside the edge (and skip the outermost
-- band on the perpendicular axis). Without it, a 1px dark strip along one
-- edge was read as a "black border", the white margin behind it as content,
-- and that whole side was left uncropped.
local MAX_INSET = 12

-- Mihon samples ~4M pixels natively. LuaJIT scanning is fast, but e-ink
-- devices pay for the gray conversion and render, so cap at ~1M pixels.
local MAX_SAMPLE_DIM = 1024
local MAX_SAMPLE_PIXELS = 1000000

local function roundFill(span)
    return math.floor(span * FILLED_RATIO / 2 + 0.5)
end

local function edgeInset(width, height)
    local inset = math.floor(math.min(width, height) * 0.01 + 0.5)
    return math.max(2, math.min(MAX_INSET, inset))
end

-- Classify a sampled row as "white", "black", or nil (mixed/noise).
local function classifyRow(gray, width, y, x0, x1)
    local white, black, n = 0, 0, 0
    for x = x0, x1, 2 do
        local v = gray[y * width + x]
        n = n + 1
        if v >= WHITE_MIN then
            white = white + 1
        elseif v <= BLACK_MAX then
            black = black + 1
        end
    end
    local need = math.ceil(n * UNIFORM_RATIO)
    if white >= need then return "white" end
    if black >= need then return "black" end
    return nil
end

-- Classify a sampled column as "white", "black", or nil (mixed/noise).
local function classifyCol(gray, width, x, y0, y1)
    local white, black, n = 0, 0, 0
    for y = y0, y1, 2 do
        local v = gray[y * width + x]
        n = n + 1
        if v >= WHITE_MIN then
            white = white + 1
        elseif v <= BLACK_MAX then
            black = black + 1
        end
    end
    local need = math.ceil(n * UNIFORM_RATIO)
    if white >= need then return "white" end
    if black >= need then return "black" end
    return nil
end

-- A pixel counts as content when it differs from the margin colour. `strong`
-- is the confident-ink variant: it drops light grey marks (watermarks, dust)
-- that are still dark/light enough to count as the loose variant.
local STRONG_DARK = 96
local STRONG_LIGHT = 160

local function isContent(value, bg, strong)
    if bg == "white" then
        if strong then return value < STRONG_DARK end
        return value < WHITE_MIN
    end
    if strong then return value > STRONG_LIGHT end
    return value > BLACK_MAX
end

-- Is the band between a confident bound and the loose bound made only of
-- sparse marks (a watermark, dust, a page number)? Dense artwork, a panel
-- edge or a grey area reaching the edge fills whole lines and is kept.
local STRIP_MAX_RATIO = 0.10
local STRIP_MAX_LINE = 0.25

local function stripIsSparse(gray, width, x1, x2, y1, y2, bg, rows_are_lines)
    local w, h = x2 - x1, y2 - y1
    if w <= 0 or h <= 0 then return true end
    if not bg then return false end

    local total, max_line = 0, 0
    if rows_are_lines then
        for y = y1, y2 - 1 do
            local cnt = 0
            local row = y * width
            for x = x1, x2 - 1 do
                if isContent(gray[row + x], bg, false) then cnt = cnt + 1 end
            end
            total = total + cnt
            if cnt > max_line then max_line = cnt end
        end
        return total <= w * h * STRIP_MAX_RATIO and max_line <= w * STRIP_MAX_LINE
    end

    for x = x1, x2 - 1 do
        local cnt = 0
        for y = y1, y2 - 1 do
            if isContent(gray[y * width + x], bg, false) then cnt = cnt + 1 end
        end
        total = total + cnt
        if cnt > max_line then max_line = cnt end
    end
    return total <= w * h * STRIP_MAX_RATIO and max_line <= h * STRIP_MAX_LINE
end

-- Two-page scans are one wide image with a blank gutter between the pages.
-- Splitting at the geometric midpoint lands inside that gutter, so both
-- halves keep a white strip on their inner edge. Look for a full-height
-- blank band near the middle of the content and return its sample-space
-- bounds (x2 exclusive); nil when the page has no such gutter.
function CropBorders.findGutter(gray, width, height, left, top, right, bottom, bg)
    local span = right - left
    if span < 24 or bottom - top < 8 or not bg then
        return nil
    end

    -- Only the page background counts: a solid black panel is uniform too,
    -- but it is content, not the gap between two scanned pages.
    local function blank(x)
        return classifyCol(gray, width, x, top, bottom - 1) == bg
    end

    local centre = left + span / 2
    local lo = left + math.floor(span * 0.30)
    local hi = left + math.ceil(span * 0.70)

    local best_len, best_x1, best_x2 = 0, nil, nil
    local run_x1
    for x = lo, hi do
        if blank(x) then
            run_x1 = run_x1 or x
        elseif run_x1 then
            local len = x - run_x1
            if len > best_len or
               (len == best_len and best_x1 and
                math.abs((run_x1 + x - 1) / 2 - centre) <
                math.abs((best_x1 + best_x2 - 1) / 2 - centre)) then
                best_len, best_x1, best_x2 = len, run_x1, x
            end
            run_x1 = nil
        end
    end
    if run_x1 then
        local len = hi + 1 - run_x1
        if len > best_len then
            best_len, best_x1, best_x2 = len, run_x1, hi + 1
        end
    end

    -- Too thin to be a gutter (or a page with no gutter at all).
    if not best_x1 or best_len < math.max(4, math.floor(span * 0.004)) then
        return nil
    end
    return best_x1, best_x2
end

-- One border pass. `strong` selects the ink threshold.
local function findBounds(gray, width, height, strong)
    if width < 2 or height < 2 then
        return 0, 0, width, height
    end

    local inset = edgeInset(width, height)
    if width <= inset * 2 + 2 or height <= inset * 2 + 2 then
        inset = 1
    end
    if width <= inset * 2 + 2 or height <= inset * 2 + 2 then
        return 0, 0, width, height
    end

    local ix0, ix1 = inset, width - 1 - inset
    local iy0, iy1 = inset, height - 1 - inset

    -- Top: probe the first line inside the edge for the margin colour, then
    -- look inward for the first line carrying content. A hit on the probe
    -- line itself means content reaches the edge: leave that side alone.
    local top = 0
    do
        local limit = roundFill(ix1 - ix0 + 1)
        local bg = classifyRow(gray, width, iy0, ix0, ix1)
        -- A black probe is only a margin when the edge itself is black too;
        -- otherwise it is content that happens to reach this edge.
        if bg == "black" and classifyRow(gray, width, 0, 0, width - 1) ~= "black" then
            bg = nil
        end
        if bg then
            for y = iy0, iy1 do
                local filled = 0
                for x = ix0, ix1, 2 do
                    if isContent(gray[y * width + x], bg, strong) then
                        filled = filled + 1
                    end
                end
                if filled > limit then
                    if y > iy0 then top = y end
                    break
                end
            end
        end
    end

    local bottom = height
    do
        local limit = roundFill(ix1 - ix0 + 1)
        local bg = classifyRow(gray, width, iy1, ix0, ix1)
        if bg == "black" and classifyRow(gray, width, height - 1, 0, width - 1) ~= "black" then
            bg = nil
        end
        if bg then
            for y = iy1, iy0, -1 do
                local filled = 0
                for x = ix0, ix1, 2 do
                    if isContent(gray[y * width + x], bg, strong) then
                        filled = filled + 1
                    end
                end
                if filled > limit then
                    if y < iy1 then bottom = y + 1 end
                    break
                end
            end
        end
    end

    if bottom - top < 3 then
        return 0, 0, width, height
    end

    local y0, y1 = top, bottom - 1
    local left = 0
    do
        local limit = roundFill(y1 - y0 + 1)
        local bg = classifyCol(gray, width, ix0, y0, y1)
        if bg == "black" and classifyCol(gray, width, 0, 0, height - 1) ~= "black" then
            bg = nil
        end
        if bg then
            for x = ix0, ix1 do
                local filled = 0
                for y = y0, y1, 2 do
                    if isContent(gray[y * width + x], bg, strong) then
                        filled = filled + 1
                    end
                end
                if filled > limit then
                    if x > ix0 then left = x end
                    break
                end
            end
        end
    end

    local right = width
    do
        local limit = roundFill(y1 - y0 + 1)
        local bg = classifyCol(gray, width, ix1, y0, y1)
        if bg == "black" and classifyCol(gray, width, width - 1, 0, height - 1) ~= "black" then
            bg = nil
        end
        if bg then
            for x = ix1, ix0, -1 do
                local filled = 0
                for y = y0, y1, 2 do
                    if isContent(gray[y * width + x], bg, strong) then
                        filled = filled + 1
                    end
                end
                if filled > limit then
                    if x < ix1 then right = x + 1 end
                    break
                end
            end
        end
    end

    if right - left < 2 or bottom - top < 2 then
        return 0, 0, width, height
    end

    -- Page background colour, needed to tell a blank gutter from solid art.
    local margin = classifyRow(gray, width, iy0, ix0, ix1)
        or classifyRow(gray, width, iy1, ix0, ix1)
        or classifyCol(gray, width, ix0, top, bottom - 1)
        or classifyCol(gray, width, ix1, top, bottom - 1)

    return left, top, right, bottom, margin
end

-- `gray` is a uint8_t array of width*height bytes. Returns left, top, right,
-- bottom in sample coordinates; the full rect when no content is found.
-- The loose pass finds any ink (including watermarks); the strong pass finds
-- confident ink only. A loose bound is dropped when the extra band contains
-- only sparse marks, so watermarks and dust do not defeat border cropping.
function CropBorders.findBorders(gray, width, height)
    local left, top, right, bottom, margin = findBounds(gray, width, height, false)
    local sl, st, sr, sb = findBounds(gray, width, height, true)

    if sl > left and stripIsSparse(gray, width, left, sl, top, bottom, margin, false) then
        left = sl
    end
    if sr < right and stripIsSparse(gray, width, sr, right, top, bottom, margin, false) then
        right = sr
    end
    if st > top and stripIsSparse(gray, width, left, right, top, st, margin, true) then
        top = st
    end
    if sb < bottom and stripIsSparse(gray, width, left, right, sb, bottom, margin, true) then
        bottom = sb
    end

    return left, top, right, bottom, margin
end

local function toGray(bb)
    local width, height = bb:getWidth(), bb:getHeight()
    local bbtype = bb:getType()
    local src = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    local gray = ffi.new("uint8_t[?]", width * height)

    if bbtype == Blitbuffer.TYPE_BB8 then
        for y = 0, height - 1 do
            local src_row = src + y * stride
            local dst_row = gray + y * width
            for x = 0, width - 1 do
                dst_row[x] = src_row[x]
            end
        end
    elseif bbtype == Blitbuffer.TYPE_BB8A then
        -- 8-bit gray + 8-bit alpha: skip the alpha byte.
        for y = 0, height - 1 do
            local src_row = src + y * stride
            local dst_row = gray + y * width
            for x = 0, width - 1 do
                dst_row[x] = src_row[x * 2]
            end
        end
    elseif bbtype == Blitbuffer.TYPE_BBRGB24 or bbtype == Blitbuffer.TYPE_BBRGB32 then
        local bpp = bbtype == Blitbuffer.TYPE_BBRGB24 and 3 or 4
        -- MuPDF can hand back BGR-ordered pixmaps on some devices.
        local wr, wg, wb = 77, 150, 29
        if mupdf.bgr then wr, wb = 29, 77 end
        for y = 0, height - 1 do
            local src_row = src + y * stride
            local dst_row = gray + y * width
            for x = 0, width - 1 do
                local o = x * bpp
                dst_row[x] = (src_row[o] * wr + src_row[o + 1] * wg + src_row[o + 2] * wb) / 256
            end
        end
    else
        return nil, "unsupported image type " .. tostring(bbtype)
    end

    return gray, width, height
end

-- Detect the content rect of `raw_data`. Returns nil when the page is already
-- full-bleed or detection is not possible. `native_w`/`native_h` are the
-- page's layout dimensions (the same space the returned rect must use).
function CropBorders.detect(raw_data, native_w, native_h)
    if type(raw_data) ~= "string" or #raw_data == 0 then
        return nil
    end
    native_w, native_h = tonumber(native_w), tonumber(native_h)
    if not native_w or not native_h or native_w < 8 or native_h < 8 then
        return nil
    end

    local pixel_scale = math.min(1, MAX_SAMPLE_DIM / native_w,
                                 MAX_SAMPLE_DIM / native_h,
                                 math.sqrt(MAX_SAMPLE_PIXELS / (native_w * native_h)))
    local sample_w = math.max(2, math.floor(native_w * pixel_scale + 0.5))
    local sample_h = math.max(2, math.floor(native_h * pixel_scale + 0.5))

    local ok, bb = pcall(mupdf.renderImage, raw_data, #raw_data, sample_w, sample_h)
    if not ok or not bb then
        return nil
    end

    local scan_ok, gray, width, height = pcall(toGray, bb)
    bb:free()
    if not scan_ok or not gray then
        return nil
    end

    local found, left, top, right, bottom, margin =
        pcall(CropBorders.findBorders, gray, width, height)
    if not found then
        return nil
    end

    if left <= 0 and top <= 0 and right >= width and bottom >= height then
        return nil
    end

    -- A sampled pixel of slack each way keeps gaps between samples from
    -- cutting into content. It is only needed when the image was downscaled.
    local scaled = width < native_w or height < native_h
    local slack = scaled and 1 or 0
    local sx = native_w / width
    local sy = native_h / height

    local x = math.max(0, math.floor((left - slack) * sx))
    local y = math.max(0, math.floor((top - slack) * sy))
    local x2 = math.min(native_w, math.ceil((right + slack) * sx))
    local y2 = math.min(native_h, math.ceil((bottom + slack) * sy))

    if x2 - x < 2 or y2 - y < 2 then
        return nil
    end
    if x == 0 and y == 0 and x2 == native_w and y2 == native_h then
        return nil
    end

    local rect = { x = x, y = y, w = x2 - x, h = y2 - y }

    -- Record the blank gutter of a two-page scan so the viewer can split
    -- there instead of at the geometric midpoint. Round into the gutter
    -- (never into the page art) so no white sliver is left on either half.
    local gx1, gx2 = CropBorders.findGutter(gray, width, height, left, top, right, bottom, margin)
    if gx1 then
        local g1 = math.max(x, math.ceil(gx1 * sx))
        local g2 = math.min(x2, math.floor(gx2 * sx))
        if g2 - g1 >= 2 then
            rect.gutter = { x1 = g1, x2 = g2 }
        end
    end

    return rect
end

return CropBorders
