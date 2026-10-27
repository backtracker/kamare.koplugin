local Utils = {}

local _ = require("gettext")
local T = require("ffi/util").template

local function hasWord(str, word)
    return str:find("%f[%a]" .. word .. "%f[%A]") ~= nil
end

function Utils.firstNonEmpty(...)
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= "" then
            return v
        end
    end
    return nil
end

function Utils.joinPersonNames(persons, limit)
    if type(persons) == "string" then return persons end
    if type(persons) ~= "table" then return nil end
    limit = limit or 3
    local names = {}
    for __, p in ipairs(persons) do
        if #names >= limit then break end
        if type(p) == "string" then
            table.insert(names, p)
        elseif type(p) == "table" and p.name then
            table.insert(names, p.name)
        end
    end
    if #names == 0 then return nil end
    local result = table.concat(names, ", ")
    if #persons > limit then
        result = result .. ", ..."
    end
    return result
end

function Utils.buildVolumeTitle(dto)
    local vol_prefix = dto.number and T(_("Volume %1"), tostring(dto.number)) or nil
    if Utils.firstNonEmpty(dto.name) then
        local name = dto.name
        local lower = name:lower()
        local is_just_number = tonumber(name) ~= nil and name:match("^%d+$")
        -- Lua patterns are byte based: compare the 3-byte CJK suffix instead
        -- of putting it in a character class.
        local is_volume_number = name:match("^%d+%s*") ~= nil
            and (name:sub(-3) == "卷" or name:sub(-3) == "巻")
        local names_volume = hasWord(lower, "vol") or hasWord(lower, "volume")
            or name:find("卷", 1, true) ~= nil
        if (is_just_number or is_volume_number) and vol_prefix then return vol_prefix end
        if names_volume then return name end
        if vol_prefix then return vol_prefix .. ": " .. name end
        return name
    end
    return vol_prefix or T(_("Volume #%1"), tostring(dto.id or "?"))
end

function Utils.buildChapterTitle(dto)
    -- Kavita uses negative sentinel numbers (-100000) for loose/special
    -- chapters; prefixing those produces "Ch. -100000: ..." on every row.
    local number = tonumber(dto.number)
    local ch_prefix = (number and number >= 0)
        and T(_("Ch. %1"), tostring(dto.number)) or nil
    if dto.isSpecial then
        return Utils.firstNonEmpty(dto.titleName, dto.title, dto.range, T(_("Special #%1"), tostring(dto.id or "?")))
    end
    if Utils.firstNonEmpty(dto.titleName) then
        local lower = dto.titleName:lower()
        local is_just_number = tonumber(dto.titleName) ~= nil and dto.titleName:match("^%d+$")
        if not (hasWord(lower, "ch") or hasWord(lower, "chap") or hasWord(lower, "chapter")
                or hasWord(lower, "vol") or hasWord(lower, "volume") or is_just_number) and ch_prefix then
            return ch_prefix .. ": " .. dto.titleName
        end
        return dto.titleName
    end
    return Utils.firstNonEmpty(dto.title, dto.range, ch_prefix, T(_("Chapter #%1"), tostring(dto.id or "?")))
end

function Utils.resolveTitle(metadata, fallback_title, default)
    default = default or _("Unknown")
    if metadata then
        return Utils.firstNonEmpty(metadata.localizedName, fallback_title, default)
    end
    return fallback_title or default
end

return Utils
