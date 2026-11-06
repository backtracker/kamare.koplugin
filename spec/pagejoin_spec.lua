-- Pure page-join planning: page-type classification, pair selection, display
-- order and numeric exit targets. No device, no image stack.

return function(t)
    local PageJoin = require("kamarepagejoin")

    local function make_doc(entries)
        local d = { entries = entries }
        function d:getPageCount() return #self.entries end
        function d:getLogicalPosition(page)
            local e = self.entries[page]
            if not e then return nil end
            return e.physical, e.side
        end
        function d:getNativePageDimensions(page)
            local e = self.entries[page]
            if not e then return nil end
            return { w = e.w, h = e.h }
        end
        function d:getLogicalPageForPhysical(physical, side)
            local fallback
            for i, e in ipairs(self.entries) do
                if e.physical == physical then
                    fallback = fallback or i
                    if not side or e.side == side then return i end
                end
            end
            return fallback or 1
        end
        return d
    end

    local function single(n, w, h)
        local list = {}
        for i = 1, n do
            list[i] = { physical = i, w = w or 1000, h = h or 1500 }
        end
        return list
    end

    ----------------------------------------------------------------
    -- Single portrait pages: numeric +1 pair
    ----------------------------------------------------------------
    local doc = make_doc(single(10))
    local plan, reason = PageJoin.plan(doc, 5)
    t.ok(plan ~= nil, "J1: a normal portrait page can join")
    t.eq(plan and plan.kind, "pair", "J1: kind is pair")
    t.eq(plan and plan.first, 5, "J1: pair starts at the current page")
    t.eq(plan and plan.second, 6, "J1: pair is numeric current + 1")
    t.eq(reason, nil, "J1: no rejection reason")

    local from6 = PageJoin.plan(doc, 6)
    t.eq(from6 and from6.first, 6, "J2: page 6 pairs with 7, not with 5")
    t.eq(from6 and from6.second, 7, "J2: numeric pairing is independent of direction")

    ----------------------------------------------------------------
    -- Display order follows page_direction, pairing does not
    ----------------------------------------------------------------
    local ltr_left, ltr_right = PageJoin.pair_pages(plan, 0)
    t.eq(ltr_left, 5, "J3: LTR puts the current page on the left")
    t.eq(ltr_right, 6, "J3: LTR puts the next page on the right")

    local rtl_left, rtl_right = PageJoin.pair_pages(plan, 1)
    t.eq(rtl_left, 6, "J4: RTL puts the next page on the left")
    t.eq(rtl_right, 5, "J4: RTL puts the current page on the right")

    ----------------------------------------------------------------
    -- Exit targets are numeric
    ----------------------------------------------------------------
    t.eq(PageJoin.next_target(plan), 7, "J5: next skips both joined pages")
    t.eq(PageJoin.prev_target(plan), 4, "J6: prev goes before the pair")

    ----------------------------------------------------------------
    -- Rejections
    ----------------------------------------------------------------
    local last, last_reason = PageJoin.plan(doc, 10)
    t.eq(last, nil, "J7: the last page cannot join")
    t.eq(last_reason, "last-page", "J7: reason is last-page")

    local wide_doc = make_doc({
        { physical = 1, w = 1000, h = 1500 },
        { physical = 2, w = 1600, h = 1000 },
        { physical = 3, w = 1000, h = 1500 },
    })
    local wide, wide_reason = PageJoin.plan(wide_doc, 2)
    t.eq(wide, nil, "J8: a whole wide page is already a spread")
    t.eq(wide_reason, "wide-page", "J8: reason is wide-page")

    local strip_doc = make_doc({
        { physical = 1, w = 400, h = 1200 },
        { physical = 2, w = 1000, h = 1500 },
    })
    local strip, strip_reason = PageJoin.plan(strip_doc, 1)
    t.eq(strip, nil, "J9: a strip page cannot join")
    t.eq(strip_reason, "strip-page", "J9: reason is strip-page")

    local next_wide = make_doc({
        { physical = 1, w = 1000, h = 1500 },
        { physical = 2, w = 1600, h = 1000 },
    })
    local nw, nw_reason = PageJoin.plan(next_wide, 1)
    t.eq(nw, nil, "J10: a wide next page is rejected")
    t.eq(nw_reason, "next-wide", "J10: reason names the wide next page")

    ----------------------------------------------------------------
    -- Split halves: always the same physical page, from either half
    ----------------------------------------------------------------
    local split = make_doc({
        { physical = 1, w = 1000, h = 1500 },
        { physical = 3, side = "left", w = 400, h = 2000 },
        { physical = 3, side = "right", w = 400, h = 2000 },
        { physical = 4, w = 1000, h = 1500 },
    })

    local from_left = PageJoin.plan(split, 2)
    t.ok(from_left ~= nil, "J11: a split half can join")
    t.eq(from_left and from_left.kind, "split", "J11: kind is split")
    t.eq(from_left and from_left.physical, 3, "J11: the physical page is kept")
    t.eq(from_left and from_left.left, 2, "J11: left half is the physical left")
    t.eq(from_left and from_left.right, 3, "J11: right half is the physical right")
    t.eq(from_left and from_left.first, 2, "J11: first is the lower logical page")
    t.eq(from_left and from_left.second, 3, "J11: second is the higher logical page")

    local from_right = PageJoin.plan(split, 3)
    t.ok(from_right ~= nil, "J12: the other half joins too")
    t.eq(from_right and from_right.physical, 3, "J12: same physical page")
    t.eq(from_right and from_right.left, 2, "J12: left stays left")
    t.eq(from_right and from_right.right, 3, "J12: right stays right")

    -- RTL logical order (right half first) must not mirror the physical page.
    local split_rtl = make_doc({
        { physical = 3, side = "right", w = 400, h = 2000 },
        { physical = 3, side = "left", w = 400, h = 2000 },
    })
    local rtl = PageJoin.plan(split_rtl, 1)
    t.eq(rtl and rtl.left, 2, "J13: RTL split still draws the physical left on the left")
    t.eq(rtl and rtl.right, 1, "J13: and the physical right on the right")

    ----------------------------------------------------------------
    -- Split layout: shared zoom, tight, height-bound
    ----------------------------------------------------------------
    local layout = PageJoin.split_layout(618, 933,
        { w = 400, h = 2000 }, { w = 400, h = 2000 })
    t.ok(layout ~= nil, "J14: split layout is computable")
    t.ok(math.abs(layout.zoom - math.min(618 / 800, 933 / 2000)) < 1e-9,
        "J14: zoom fits the combined width and height")
    t.ok(math.abs(layout.total_w - 800 * layout.zoom) < 1e-6,
        "J14: total width is the two halves at the shared zoom")
    t.ok(math.abs(layout.total_h - 2000 * layout.zoom) < 1e-6,
        "J14: total height is the shared height")

    local unequal = PageJoin.split_layout(618, 933,
        { w = 500, h = 2000 }, { w = 300, h = 2000 })
    t.ok(unequal ~= nil and unequal.zoom > 0, "J15: unequal half widths still lay out")
    t.ok(math.abs(unequal.total_w - 800 * unequal.zoom) < 1e-6,
        "J15: widths are summed at the shared zoom")

    ----------------------------------------------------------------
    -- A pair whose next page is a half is rejected
    ----------------------------------------------------------------
    local next_half = make_doc({
        { physical = 1, w = 1000, h = 1500 },
        { physical = 2, side = "left", w = 400, h = 2000 },
        { physical = 2, side = "right", w = 400, h = 2000 },
    })
    local nh, nh_reason = PageJoin.plan(next_half, 1)
    t.eq(nh, nil, "J16: a half next page is rejected")
    t.eq(nh_reason, "next-half", "J16: reason names the half next page")

    ----------------------------------------------------------------
    -- Join direction: Auto follows Page Direction; LTR/RTL override it
    ----------------------------------------------------------------
    t.eq(PageJoin.resolve_direction(0, 0), 0, "J17: auto + LTR page = LTR join")
    t.eq(PageJoin.resolve_direction(1, 0), 1, "J17: auto + RTL page = RTL join")
    t.eq(PageJoin.resolve_direction(1, 1), 0, "J18: forced LTR beats an RTL page")
    t.eq(PageJoin.resolve_direction(0, 2), 1, "J18: forced RTL beats an LTR page")
    t.eq(PageJoin.resolve_direction(0, 1), 0, "J18: forced LTR on an LTR page")
    t.eq(PageJoin.resolve_direction(1, 2), 1, "J18: forced RTL on an RTL page")
end
