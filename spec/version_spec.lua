local version = require("kamareversion")

return function(t)
    t.ok(type(version) == "string" and #version > 0, "version is a non-empty string")
    t.ok(version:match("^%d+%.%d+%.%d+") ~= nil, "version looks semver-ish: " .. tostring(version))
    t.ok(not version:find("@VERSION", 1, true), "placeholder was replaced")
end
