local manifest = require("kamarefeatures")

return function(t)
    t.eq(manifest.api_version, 1, "api_version")
    t.ok(type(manifest.features) == "table", "features is a table")
    t.ok(#manifest.features > 0, "features is non-empty")
    t.ok(#manifest.features <= 8, "Moon renders at most 8 entries")
    local seen = {}
    for i, title in ipairs(manifest.features) do
        t.ok(type(title) == "string" and title ~= "", "feature " .. i .. " is non-empty text")
        t.ok(not title:find(" · ", 1, true), "manifest must not include Moon's separator: " .. tostring(title))
        t.ok(not seen[title], "duplicate feature: " .. tostring(title))
        seen[title] = true
    end
end
