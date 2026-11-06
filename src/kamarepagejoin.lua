-- Temporary manual page-join ("合页") planning.
--
-- Pure page-type decisions, kept out of the viewer/canvas so they can be
-- unit-tested without a device or the image stack.
--
-- Rules (confirmed 2026-11-06):
--   * A Split half (side ~= nil) always joins its own physical page: the two
--     halves are the same source image, and the reading direction does not
--     apply to the physical layout.
--   * A whole portrait page joins the *next logical page* (numeric +1), which
--     must also be a whole portrait page. Reading direction only affects how
--     the two independent pages are displayed, never which pages are paired.
--   * Wide (already a complete spread), strip (too narrow to sit beside
--     anything) and the last page are rejected; the caller stays put.
--   * Navigation after a join is numeric: next = second + 1, prev = first - 1.
--     It deliberately bypasses the viewer's RTL page-turn inversion.

local PageJoin = {}

-- A page narrower than this (width / height) is a strip; pairing it would
-- leave both pages too small to read.
PageJoin.STRIP_RATIO = 0.45

local function dims_of(doc, page)
    local dims = doc and doc:getNativePageDimensions(page)
    if not dims or not dims.w or not dims.h or dims.w <= 0 or dims.h <= 0 then
        return nil
    end
    return dims
end

--- Classify one logical page.
--- @return table|nil { kind = "half"|"single"|"wide"|"strip", physical, side, dims }
function PageJoin.classify(doc, page)
    if not doc or type(page) ~= "number" or page < 1 then return nil end
    if doc.getPageCount and page > doc:getPageCount() then return nil end

    local physical, side = doc:getLogicalPosition(page)
    if not physical then return nil end

    local dims = dims_of(doc, page)
    if not dims then return nil end

    if side ~= nil then
        return { kind = "half", physical = physical, side = side, dims = dims }
    end
    if dims.w > dims.h then
        return { kind = "wide", physical = physical, dims = dims }
    end
    if dims.w / dims.h < PageJoin.STRIP_RATIO then
        return { kind = "strip", physical = physical, dims = dims }
    end
    return { kind = "single", physical = physical, dims = dims }
end

local function other_half(doc, page, info)
    local other_side = info.side == "left" and "right" or "left"
    if other_side == info.side then return nil end

    local other = doc:getLogicalPageForPhysical(info.physical, other_side)
    if not other or other == page then return nil end

    local physical, side = doc:getLogicalPosition(other)
    if physical ~= info.physical or side ~= other_side then return nil end
    return other
end

--- Build the join plan for `page`.
---
--- @return table|nil plan
---   kind == "split": { kind, physical, first, second, left, right }
---   kind == "pair":  { kind, first, second }
--- @return string|nil reason  why the join was rejected
function PageJoin.plan(doc, page)
    local info = PageJoin.classify(doc, page)
    if not info then return nil, "no-page" end

    if info.kind == "half" then
        local other = other_half(doc, page, info)
        if not other then return nil, "half-mismatch" end
        return {
            kind = "split",
            physical = info.physical,
            first = math.min(page, other),
            second = math.max(page, other),
            -- Physical left/right, not logical order: the two halves are one
            -- scanned spread and must never be mirror-swapped.
            left = info.side == "left" and page or other,
            right = info.side == "left" and other or page,
        }
    end

    if info.kind == "wide" then return nil, "wide-page" end
    if info.kind == "strip" then return nil, "strip-page" end

    local next_page = page + 1
    if next_page > doc:getPageCount() then return nil, "last-page" end

    local next_info = PageJoin.classify(doc, next_page)
    if not next_info then return nil, "no-next-page" end
    if next_info.kind ~= "single" then
        return nil, "next-" .. next_info.kind
    end

    return {
        kind = "pair",
        first = page,
        second = next_page,
    }
end

--- Display pages for an independent pair. Reading direction only swaps the
--- two sides; it never changes which pages are paired.
--- @return number left, number right
function PageJoin.pair_pages(plan, page_direction)
    if page_direction == 1 then
        return plan.second, plan.first
    end
    return plan.first, plan.second
end

--- Numeric exit targets. Deliberately independent of page_direction.
function PageJoin.next_target(plan)
    return plan and plan.second + 1 or nil
end

function PageJoin.prev_target(plan)
    return plan and plan.first - 1 or nil
end

--- Shared zoom for two halves of one physical page, laid out tight (no gap).
--- The halves already carry their own cropped content; the gutter between
--- them was removed by Split and must not be reintroduced.
function PageJoin.split_layout(vp_w, vp_h, left_dims, right_dims)
    if not (left_dims and right_dims) then return nil end
    local total_w = left_dims.w + right_dims.w
    local total_h = math.max(left_dims.h, right_dims.h)
    if total_w <= 0 or total_h <= 0 or vp_w <= 0 or vp_h <= 0 then return nil end

    local zoom = math.min(vp_w / total_w, vp_h / total_h)
    zoom = math.max(0.01, zoom)
    return {
        zoom = zoom,
        total_w = total_w * zoom,
        total_h = total_h * zoom,
    }
end

return PageJoin
