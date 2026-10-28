-- Plugin version. The literal "@VERSION@" below is replaced by the release
-- workflow; from a plain checkout it stays unreplaced and we report a dev
-- version instead. The sentinel used for that check is assembled at runtime so
-- it is not touched by the version injection.
local version = "@VERSION@"
local placeholder = "@VERSION" .. "@"

if version == placeholder or version == "" then
    version = "0.10.2-dev"
end

return version
