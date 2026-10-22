-- Crop-borders detection, ported from Mihon's SSIV fork
-- (subsampling-scale-image-view: CropBorders.kt + cpp/crop/borders.cpp).
--
-- The detector works on a grayscale copy of a downscaled page. Each edge is
-- sampled to find the dominant border color (black or white), then scanned
-- inwards for the first line that contains a meaningful amount of content.
-- A tiny fill ratio (0.25%) keeps sparse line art from being cropped.
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local mupdf = require("ffi/mupdf")

local CropBorders = {}

local FILLED_RATIO = 0.0025
local THRESHOLD = 0.75
local BLACK_THRESHOLD = math.floor(255 * THRESHOLD)
local WHITE_THRESHOLD = math.floor(255 - 255 * THRESHOLD)

-- Mihon samples ~4M pixels natively. LuaJIT scanning is fast, but e-ink
-- devices pay for the gray conversion and render, so cap at ~1M pixels.
local MAX_SAMPLE_DIM = 1024
local MAX_SAMPLE_PIXELS = 1000000

local function roundFill(span)
    return math.floor(span * FILLED_RATIO / 2 + 0.5)
end

-- `gray` is a uint8_t array of width*height bytes. Returns left, top, right,
-- bottom in sample coordinates; the full rect when no content is found.
function CropBorders.findBorders(gray, width, height)
    if width < 2 or height < 2 then
        return 0, 0, width, height
    end

    local function is_black(x, y)
        return gray[y * width + x] < BLACK_THRESHOLD
    end
    local function is_white(x, y)
        return gray[y * width + x] > WHITE_THRESHOLD
    end

    local function find_top()
        local limit = roundFill(width)
        local white, black = 0, 0
        for x = 0, width - 1, 2 do
            if is_black(x, 0) then
                black = black + 1
            elseif is_white(x, 0) then
                white = white + 1
            end
        end
        local detect = is_black
        if white > limit and black > limit then
            return 0
        elseif black > limit then
            detect = is_white
        end
        for y = 1, height - 1 do
            local filled = 0
            for x = 0, width - 1, 2 do
                if detect(x, y) then filled = filled + 1 end
            end
            if filled > limit then return y end
        end
        return 0
    end

    local function find_bottom()
        local limit = roundFill(width)
        local white, black = 0, 0
        local last_y = height - 1
        for x = 0, width - 1, 2 do
            if is_black(x, last_y) then
                black = black + 1
            elseif is_white(x, last_y) then
                white = white + 1
            end
        end
        local detect = is_black
        if white > limit and black > limit then
            return height
        elseif black > limit then
            detect = is_white
        end
        for y = height - 2, 1, -1 do
            local filled = 0
            for x = 0, width - 1, 2 do
                if detect(x, y) then filled = filled + 1 end
            end
            if filled > limit then return y + 1 end
        end
        return height
    end

    local top = find_top()
    local bottom = find_bottom()
    if bottom <= top then
        return 0, 0, width, height
    end

    local function find_left()
        local limit = roundFill(height)
        local white, black = 0, 0
        for y = top, bottom - 1, 2 do
            if is_black(0, y) then
                black = black + 1
            elseif is_white(0, y) then
                white = white + 1
            end
        end
        local detect = is_black
        if white > limit and black > limit then
            return 0
        elseif black > limit then
            detect = is_white
        end
        for x = 1, width - 1 do
            local filled = 0
            for y = top, bottom - 1, 2 do
                if detect(x, y) then filled = filled + 1 end
            end
            if filled > limit then return x end
        end
        return 0
    end

    local function find_right()
        local limit = roundFill(height)
        local white, black = 0, 0
        local last_x = width - 1
        for y = top, bottom - 1, 2 do
            if is_black(last_x, y) then
                black = black + 1
            elseif is_white(last_x, y) then
                white = white + 1
            end
        end
        local detect = is_black
        if white > limit and black > limit then
            return width
        elseif black > limit then
            detect = is_white
        end
        for x = width - 2, 1, -1 do
            local filled = 0
            for y = top, bottom - 1, 2 do
                if detect(x, y) then filled = filled + 1 end
            end
            if filled > limit then return x + 1 end
        end
        return width
    end

    local left = find_left()
    local right = find_right()
    return left, top, right, bottom
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

    local found, left, top, right, bottom = pcall(CropBorders.findBorders, gray, width, height)
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

    return { x = x, y = y, w = x2 - x, h = y2 - y }
end

return CropBorders
