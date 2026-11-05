-- Crop-border / gutter detection on synthetic scans.
--
-- The gutter case that matters here: a two-page spread can have artwork on
-- every outer edge (so no border is cropped at all) while still having a
-- blank band down the middle. Splitting at the geometric midpoint then
-- leaves half of that band as a white strip on each half.

local CropBorders = require("cropborders")

local function canvas(w, h, value)
    local gray = {}
    for y = 0, h - 1 do
        local row = y * w
        for x = 0, w - 1 do gray[row + x] = value end
    end
    return gray
end

-- Sparse ink: every third row of the given columns. Each column is mixed, so
-- classifyCol does not call it a margin, but the page is still mostly paper.
local function inkColumns(gray, w, x1, x2, h)
    for y = 0, h - 1, 3 do
        local row = y * w
        for x = x1, x2 - 1 do gray[row + x] = 0 end
    end
end

return function(t)
    local W, H = 200, 60

    -- Artwork runs to every outer edge; the middle band (71..119) is blank.
    local spread = canvas(W, H, 255)
    inkColumns(spread, W, 0, 71, H)
    inkColumns(spread, W, 120, W, H)

    local gx1, gx2 = CropBorders.findGutter(spread, W, H, 0, 0, W, H, nil)
    t.eq(gx1, 71, "C1: gutter found when no outer margin was detected")
    t.eq(gx2, 120, "C1: gutter ends at the right page")

    -- Explicit margin colour keeps working.
    local ex1, ex2 = CropBorders.findGutter(spread, W, H, 0, 0, W, H, "white")
    t.eq(ex1, 71, "C2: explicit white margin still finds the gutter")
    t.eq(ex2, 120, "C2: explicit white margin ends at the right page")

    -- A solid black panel in the middle of a white page is content, not a
    -- gutter: the inferred background is white, so the black band is skipped.
    local panel = canvas(W, H, 255)
    inkColumns(panel, W, 0, 81, H)
    inkColumns(panel, W, 120, W, H)
    for y = 0, H - 1 do
        local row = y * W
        for x = 81, 119 do panel[row + x] = 0 end
    end
    t.is_nil(CropBorders.findGutter(panel, W, H, 0, 0, W, H, nil),
        "C3: solid black panel is not mistaken for a gutter")

    -- No blank band at all: no split hint.
    local solid = canvas(W, H, 255)
    inkColumns(solid, W, 0, W, H)
    t.is_nil(CropBorders.findGutter(solid, W, H, 0, 0, W, H, nil),
        "C4: a page without a blank band has no gutter")

    -- End to end through detect(): a full-bleed spread (no outer margin at
    -- all, so the old early return dropped the result) must still come back
    -- as a full rect carrying the gutter.
    local Blitbuffer = require("ffi/blitbuffer")
    local pw, ph = 400, 120
    local bb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    for y = 0, ph - 1 do
        for x = 0, pw - 1 do
            -- Mixed ink on both pages so no outer edge classifies as a
            -- uniform margin; the gutter (143..199) stays pure white.
            if (x < 143 or x >= 200) and (x * 7 + y * 11) % 5 < 2 then
                bb:setPixel(x, y, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    local path = t.tmpdir() .. "/spread.png"
    assert(bb:writePNG(path))
    bb:free()
    local f = assert(io.open(path, "rb"))
    local raw = f:read("*a")
    f:close()

    local rect = CropBorders.detect(raw, pw, ph)
    t.ok(rect ~= nil, "C5: full-bleed spread still yields a detection")
    if rect then
        t.eq(rect.x, 0, "C5: nothing cut from the left")
        t.eq(rect.y, 0, "C5: nothing cut from the top")
        t.eq(rect.w, pw, "C5: nothing cut from the right")
        t.eq(rect.h, ph, "C5: nothing cut from the bottom")
        t.ok(rect.gutter ~= nil, "C5: gutter recorded")
        if rect.gutter then
            t.eq(rect.gutter.x1, 143, "C5: gutter starts at the left page edge")
            t.eq(rect.gutter.x2, 200, "C5: gutter ends at the right page edge")
        end
    end
end
