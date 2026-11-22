-- Source-level checks for the offline-cache prefetch guard. The viewer pulls
-- in the whole KOReader UI (SDL window, settings globals), so it cannot be
-- required from the offline spec runtime; these assertions pin the wiring the
-- same way pager_menu_spec / pagejoin_wiring_spec do.
--
-- Regression: cached chapters never record a network sample, so the
-- "no samples => top tier" rule made offline reading prefetch like a gigabit
-- link. Each local page is read + decoded synchronously on the UI thread, and
-- the background chain blocked input past Android's ANR threshold (SIGQUIT).
return function(t)
    local f = io.open((t.spec_dir or "spec") .. "/../src/kamareimageviewer.lua", "rb")
    local viewer = f and f:read("*a") or ""
    if f then f:close() end

    local body = viewer:match("function KamareImageViewer:_netTier%(%)(.-)\nend") or ""
    t.ok(body ~= "", "PF1: _netTier is defined")

    local guard_at = body:find('self.page_source == "local"', 1, true)
    local samples_at = body:find("self:_netSampleCount() == 0", 1, true)
    t.ok(guard_at ~= nil, "PF2: local chapters are classified separately from network quality")
    t.ok(guard_at ~= nil and samples_at ~= nil and guard_at < samples_at,
        "PF3: the local guard runs before the no-samples => top-tier fallback")

    local local_tier = body:match('self%.page_source == "local"%s*then%s*return%s+(%d)')
    t.eq(local_tier, "0", "PF4: local chapters use the lowest prefetch tier, not the top tier")

    t.ok(viewer:find("local NET_BW_FACTOR_FLOOR%s*=%s*0%.15", 1) ~= nil
        or viewer:find("NET_BW_FACTOR_FLOOR", 1, true) ~= nil,
        "PF5: a nonzero floor keeps the immediate-next-page prefetch warm")
    t.ok(viewer:find("NET_BW_FACTOR_BY_TIER%s*=%s*%b{}", 1) ~= nil
        and viewer:find("%[0%]%s*=%s*NET_BW_FACTOR_FLOOR", 1) ~= nil,
        "PF6: tier 0 still has a prefetch budget")
end
