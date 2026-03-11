local Parser = {}
Parser.__index = Parser

local mp = require("mp")
local utils = require("mp.utils")

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local ENABLE_CACHE = true
local CACHE_TTL_SECONDS = 12 * 60 * 60
local CACHE_MAX_ENTRIES = 256
local DEBUG_MATCHING = true

------------------------------------------------------------
-- CACHE
------------------------------------------------------------
local ANI_CACHE = {}

------------------------------------------------------------
-- SMALL UTILITIES
------------------------------------------------------------
local function debug_match(fmt, ...)
    if not DEBUG_MATCHING then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then
        mp.msg.info('anime parser: ' .. msg)
    else
        mp.msg.info('anime parser: ' .. tostring(fmt))
    end
end

-- Read from cache only if enabled and not expired.
local function cache_get(key)
    if not ENABLE_CACHE then return nil end
    local item = ANI_CACHE[key]
    if type(item) ~= "table" then
        return nil
    end
    if type(item.time) ~= "number" or (os.time() - item.time) > CACHE_TTL_SECONDS then
        ANI_CACHE[key] = nil
        return nil
    end
    return item.data
end

-- Write to cache and prune old/excess entries to keep memory bounded.
local function cache_put(key, data)
    if not ENABLE_CACHE or not key or data == nil then
        return
    end

    local now = os.time()
    ANI_CACHE[key] = { data = data, time = now }

    local entries = {}
    for k, v in pairs(ANI_CACHE) do
        if type(v) == "table" and type(v.time) == "number" and (now - v.time) <= CACHE_TTL_SECONDS then
            entries[#entries + 1] = { key = k, time = v.time }
        else
            ANI_CACHE[k] = nil
        end
    end

    if #entries <= CACHE_MAX_ENTRIES then
        return
    end

    table.sort(entries, function(a, b) return a.time > b.time end)
    for i = CACHE_MAX_ENTRIES + 1, #entries do
        ANI_CACHE[entries[i].key] = nil
    end
end
------------------------------------------------------------
-- STRONGER RELEASE-GROUP STRIPPING
------------------------------------------------------------
local RELEASE_GROUP_HINTS = {
    ["YTS"]=true,
    ["RARBG"]=true,
    ["EVO"]=true,
    ["iExTV"]=true,
    ["FGT"]=true,
    ["PSA"]=true,
	["Batch"]=true,
}

local function is_release_group(tokens, i)

    local t = tokens[i]
    local prev = tokens[i-1]

    if not t then return false end
    if t._is_release_group then return true end

    -- Case: "- GroupName"
    if prev and prev.value == "-" and t.kind == "word" then
        return true
    end

    -- Case: [GROUP]
    if t.kind == "word" and RELEASE_GROUP_HINTS[t.value] then
        return true
    end

    -- Case: ALL CAPS short token at end
    if t.kind == "word"
       and t.value:match("^[A-Z0-9]+$")
       and i == #tokens
    then
        return true
    end

    return false
end

------------------------------------------------------------
-- ORDINAL SUFFIX GENERATION for MAL
------------------------------------------------------------
local function ordinal(n)
    n = tonumber(n)
    if not n then return "" end
    local suffix = "th"
    if n % 10 == 1 and n % 100 ~= 11 then suffix = "st"
    elseif n % 10 == 2 and n % 100 ~= 12 then suffix = "nd"
    elseif n % 10 == 3 and n % 100 ~= 13 then suffix = "rd"
    end
    return tostring(n) .. suffix
end

local ORDINAL_WORD_NUMBERS = {
    first = 1,
    second = 2,
    third = 3,
    fourth = 4,
    fifth = 5,
    sixth = 6,
    seventh = 7,
    eighth = 8,
    ninth = 9,
    tenth = 10,
}

------------------------------------------------------------
-- JAPANESE SEASON NORMALIZATION (San no Shou ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Season 3)
------------------------------------------------------------
local JAPANESE_NUMBERS = {
    ichi = 1,
    ni = 2,
    san = 3,
    yon = 4,
    shi = 4,
    go = 5,
    roku = 6,
    nana = 7,
    shichi = 7,
    hachi = 8,
    kyuu = 9,
    ku = 9,
    juu = 10
}

local function extract_japanese_season_phrase(title)
    if not title then return nil end
    local t = title:lower()

    local word = t:match("(%a+)%s+no%s+shou")
    if word and JAPANESE_NUMBERS[word] then
        return JAPANESE_NUMBERS[word]
    end

    return nil
end

local function get_effective_season(title, season)
    if season and type(season) == "number" then
        return season
    end

    -- fallback: detect Japanese season from title
    local js = extract_japanese_season_phrase(title)
    if js and type(js) == "number" then
        return js
    end

    return nil
end

------------------------------------------------------------
-- CONFIDENCE DETECTION
------------------------------------------------------------
local function confidence_percent(a, b)
    local total = a + b
    if total <= 0 then return 50 end
    return math.floor((a / total) * 100 + 0.5)
end

local function calculate_confidence(result)
    if not result then return 0 end
    local score = 0

    if result.title and result.title ~= "" then
        score = score + 40
    end

    if result.episode_title and result.episode_title ~= "" then
        score = score + 40
    end

    if result.title and result.episode_title then
        score = score + 20
    end

    return score
end

------------------------------------------------------------
-- NUMERIC GUARDS
------------------------------------------------------------
local function looks_like_resolution(n)
    return n == 480 or n == 720 or n == 1080 or n == 2160
end

local function looks_like_year(n)
    local y = os.date("*t").year
    return n and n >= 1900 and n <= y + 1
end

------------------------------------------------------------
-- FILE-SIZE DETECTION SUPPRESSION
------------------------------------------------------------
local function is_filesize_pattern(tokens, i)
    local t = tokens[i]
    local n1 = tokens[i+1]
    local n2 = tokens[i+2]

    if not t then return false end

    -- Case: 700MB
    if t.kind == "word" then
        if t.value:match("^%d+%.?%d*[MG]B$") then
            return true
        end
    end

    -- Case: 1.2 GB
    if t.kind == "number"
       and n1 and n1.value == "."
       and n2 and n2.kind == "number"
    then
        local n3 = tokens[i+3]
        if n3 and n3.value and n3.value:upper() == "GB" then
            return true
        end
    end

    -- Case: 700 MB
    if t.kind == "number"
       and n1 and n1.value and n1.value:upper() == "MB"
    then
        return true
    end

    return false
end

------------------------------------------------------------
-- BITRATE DETECTION SUPPRESSION
------------------------------------------------------------
local function is_bitrate_pattern(tokens, i)
    local t = tokens[i]

    if not t then return false end

    -- 4500kbps
    if t.kind == "word" then
        if t.value:match("^%d+[KkMm]bps$") then
            return true
        end
    end

    -- 4500 kbps
    local n1 = tokens[i+1]
    if t.kind == "number"
       and n1
       and n1.value
       and n1.value:lower() == "kbps"
    then
        return true
    end

    return false
end

------------------------------------------------------------
-- AUDIO CHANNEL DETECTION (5.1 / 7.1)
------------------------------------------------------------
local function is_audio_channel_pattern(tokens, i)
    local t = tokens[i]
    local dot = tokens[i+1]
    local n2 = tokens[i+2]

    if not t or not dot or not n2 then return false end

    if t.kind == "number"
       and dot.value == "."
       and n2.kind == "number"
    then
        local left = tonumber(t.value)
        local right = tonumber(n2.value)

        if (left == 2 or left == 5 or left == 7)
           and (right == 0 or right == 1)
        then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- KEYWORD SYSTEM
------------------------------------------------------------
local KEYWORDS = {}

local function add(category, list)
    for i = 1, #list do
        KEYWORDS[list[i]] = category
    end
end

add("video", {"h264","h265","x264","x265","hevc","av1"})
add("audio", {"aac","flac","mp3","opus","ac3"})
add("source", {"bluray","bdrip","brrip","dvdrip","hdrip","web","webdl","webrip","hdtv","cam","ts"})
add("resolution", {"480p","720p","1080p","2160p"})
add("language", {"eng","english","jp","jpn","french","german","spanish","hindi","dub","dual","multi"})
add("subtitles", {"sub","subs","subtitle","subtitles","vostfr"})
add("release_information", {"batch","complete","patch","final"})
add("format", {"movie","theatrical"})

local MULTI_TOKEN_KEYWORDS = {
    { words = {"dual", "audio"}, key = "language", value = "Dual Audio" },
    { words = {"multi", "audio"}, key = "language", value = "Multi Audio" },
    { words = {"multiple", "audio"}, key = "language", value = "Multiple Audio" },
    { words = {"triple", "audio"}, key = "language", value = "Triple Audio" },

    { words = {"dual", "dub"}, key = "language", value = "Dual Dub" },

    { words = {"multi", "subs"}, key = "subtitles", value = "Multi Subs" },
    { words = {"multi", "sub"}, key = "subtitles", value = "Multi Sub" },
    { words = {"multi", "subtitle"}, key = "subtitles", value = "Multi Subtitle" },
    { words = {"multi", "subtitles"}, key = "subtitles", value = "Multi Subtitles" },

    { words = {"multiple", "subs"}, key = "subtitles", value = "Multiple Subs" },
    { words = {"multiple", "subtitle"}, key = "subtitles", value = "Multiple Subtitle" },
    { words = {"multiple", "subtitles"}, key = "subtitles", value = "Multiple Subtitles" },
}

------------------------------------------------------------
-- JAPANESE ARC PART WORDS (belong to TITLE, not episode title)
------------------------------------------------------------
local ARC_TITLE_WORDS = {
    ["zenpen"] = true,   -- ÃƒÂ¥Ã¢â‚¬Â°Ã‚ÂÃƒÂ§Ã‚Â·Ã‚Â¨ (part 1 / prologue)
    ["kouhen"] = true,   -- ÃƒÂ¥Ã‚Â¾Ã…â€™ÃƒÂ§Ã‚Â·Ã‚Â¨ (part 2 / conclusion)
    ["hen"]    = true,   -- ÃƒÂ§Ã‚Â·Ã‚Â¨ (arc)
}

------------------------------------------------------------
-- MOVIE TITLE BOUNDARY WORDS
------------------------------------------------------------
local MOVIE_BOUNDARY_WORDS = {
    ["movie"] = true,
    ["movies"] = true,
    ["film"] = true,
    ["the movie"] = true,
    ["gekijouban"] = true,
    ["gekijoban"] = true,
}

local MOVIE_SUBTITLE_STOPWORDS = {
    ["vostfr"] = true,
    ["vf"] = true,
    ["multi"] = true,
    ["dual"] = true,
    ["dub"] = true,
    ["sub"] = true,
    ["bd"] = true,
    ["dvd"] = true,
    ["hd"] = true,
}
------------------------------------------------------------
-- DURATION THRESHOLDS (seconds)
------------------------------------------------------------
local DURATION_THRESHOLDS = {
    tv      = {min = 20*60, max = 30*60, type = "episode"},
    ova     = {min = 40*60, max = 60*60, type = "episode"},
    special = {min = 40*60, max = 60*60, type = "episode"},
    movie   = {min = 60*60, max = math.huge, type = "movie"}
}
local EPISODE_MAX = 45*60  -- e.g., 45 minutes
local MOVIE_MIN   = 50*60  -- e.g., 50 minutes

------------------------------------------------------------
-- TOKEN
------------------------------------------------------------
local function newToken(value, kind)
    return {
        value = value,
        kind = kind,
        keyword = nil,
        category = "unknown",
        enclosed = false,
        _group_id = nil,
        _is_release_group = false,
        _title_bracket = false,
    }
end

------------------------------------------------------------
-- TOKENIZER
------------------------------------------------------------
local FULLWIDTH_TO_ASCII = {
    ["\227\128\128"] = " ",
    ["\239\188\136"] = "(", ["\239\188\137"] = ")",
    ["\227\128\140"] = "[", ["\227\128\141"] = "]",
    ["\227\128\142"] = "[", ["\227\128\143"] = "]",
    ["\227\128\144"] = "[", ["\227\128\145"] = "]",
    ["\239\188\187"] = "[", ["\239\188\189"] = "]",
    ["\239\188\142"] = ".", ["\239\188\140"] = ",",
    ["\239\188\139"] = "+", ["\239\189\158"] = "~",
    ["\239\188\144"] = "0", ["\239\188\145"] = "1", ["\239\188\146"] = "2",
    ["\239\188\147"] = "3", ["\239\188\148"] = "4", ["\239\188\149"] = "5",
    ["\239\188\150"] = "6", ["\239\188\151"] = "7", ["\239\188\152"] = "8",
    ["\239\188\153"] = "9",
}

local DASH_VARIANTS = {
    "\226\128\144", -- hyphen
    "\226\128\145", -- non-breaking hyphen
    "\226\128\146", -- figure dash
    "\226\128\147", -- en dash
    "\226\128\148", -- em dash
    "\226\128\149", -- horizontal bar
    "\239\188\141", -- full-width hyphen-minus
    "\226\136\146", -- minus sign
}

local OPENING_BRACKETS = {
    ["["] = true,
    --["("] = true,
    ["{"] = true,
}

local CLOSING_BRACKETS = {
    ["]"] = true,
    --[")"] = true,
    ["}"] = true,
}

local DELIMITER_CHARS = {
    [" "] = true,
    ["_"] = true,
    ["."] = true,
    ["|"] = true,
    [","] = true,
}

local HARD_SEPARATOR_CHARS = {
    ["-"] = true,
    ["+"] = true,
    ["~"] = true,
    ["&"] = true,
}

local SEPARATORS = {
    ["["]=true, ["]"]=true,
    ["("]=true, [")"]=true,
    ["{"]=true, ["}"]=true,
    ["."]=true, ["_"]=true,
    ["-"]=true, [" "]=true,
    ["+"]=true, ["~"]=true,
    ["|"]=true, [","]=true,
    ["&"]=true,
}

local BRACKET_PAIRS = {
    ["["] = "]",
    ["("] = ")",
    ["{"] = "}",
}

local function normalize_filename_for_parse(s)
    if type(s) ~= "string" or s == "" then
        return s or ""
    end

    for from, to in pairs(FULLWIDTH_TO_ASCII) do
        s = s:gsub(from, to)
    end

    for i = 1, #DASH_VARIANTS do
        s = s:gsub(DASH_VARIANTS[i], "-")
    end

    s = s:gsub("\195\151", "x") -- multiplication sign

    return s
end

local function tokenize(filename)
    filename = normalize_filename_for_parse(filename or "")

    local tokens = {}
    local buffer = {}

    local function flush()
        if #buffer > 0 then
            tokens[#tokens+1] = table.concat(buffer)
            buffer = {}
        end
    end

    for i = 1, #filename do
        local c = filename:sub(i,i)
        if SEPARATORS[c] then
            flush()
            tokens[#tokens+1] = c
        else
            buffer[#buffer+1] = c
        end
    end

    flush()
    return tokens
end

local function extract_file_extension(filename)
    if type(filename) ~= "string" or filename == "" then
        return nil
    end

    local base = filename:gsub("^.*[/\\]", "")
    local ext = base:match("%.([A-Za-z0-9]+)$")
    if not ext or #ext < 1 or #ext > 8 then
        return nil
    end

    return ext:lower()
end

------------------------------------------------------------
-- CLASSIFY
------------------------------------------------------------
local function classify(raw)

    -- strip version suffix early (E10v2 ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ E10)
    raw = raw:gsub("([Ss]%d+[Ee]%d+)[Vv]%d+$", "%1")
    raw = raw:gsub("([Ee]%d+)[Vv]%d+$", "%1")
    raw = raw:gsub("([Ee][Pp]?%d+)[Vv]%d+$", "%1")
    raw = raw:gsub("^(%d+)[Vv]%d+$", "%1")

    if raw:match("^%d+$") then
        local t = newToken(raw, "number")
        t.category = "unknown"
        return t
    elseif #raw == 1 and SEPARATORS[raw] then
        local t = newToken(raw, "separator")
        if OPENING_BRACKETS[raw] then
            t.category = "opening_bracket"
        elseif CLOSING_BRACKETS[raw] then
            t.category = "closing_bracket"
        elseif DELIMITER_CHARS[raw] then
            t.category = "delimiter"
        elseif HARD_SEPARATOR_CHARS[raw] then
            t.category = "separator"
        else
            t.category = "separator"
        end
        return t
    elseif #raw == 8 and raw:match("^[%x]+$") then
        local t = newToken(raw, "crc32")
        t.category = "unknown"
        return t
    else
        local t = newToken(raw, "word")
        t.category = "unknown"
        return t
    end
end

local function assignKeyword(token)
    if token.kind ~= "word" then return end
	
	local v = token.value:lower()
    if v == "episode" or v == "ep" then
        token.keyword = "episode_marker"
        return
    end
	
    token.keyword = KEYWORDS[v]
	
	if not token.keyword then
		local v = token.value:lower()
		if v:match("rip$") then
			token.keyword = "source"
		end
	end
end

local function is_matching_bracket_pair(open_bracket, close_bracket)
    return BRACKET_PAIRS[open_bracket] == close_bracket
end

local function prev_non_separator_token(tokens, idx)
    local j = idx - 1
    while tokens[j] and tokens[j].kind == "separator" do
        j = j - 1
    end
    return tokens[j], j
end

local function next_non_separator_token(tokens, idx)
    local j = idx + 1
    while tokens[j] and tokens[j].kind == "separator" do
        j = j + 1
    end
    return tokens[j], j
end

local function annotate_enclosed_groups(tokens)
    local groups = {}
    local stack = {}

    for i = 1, #tokens do
        local t = tokens[i]

        if t and t.category == "opening_bracket" then
            stack[#stack + 1] = { idx = i, value = t.value }

        elseif t and t.category == "closing_bracket" then
            for s = #stack, 1, -1 do
                local opener = stack[s]
                if is_matching_bracket_pair(opener.value, t.value) then
                    table.remove(stack, s)

                    local group_id = #groups + 1
                    local group = {
                        id = group_id,
                        start_idx = opener.idx,
                        end_idx = i,
                        open = opener.value,
                        close = t.value,
                    }
                    groups[group_id] = group

                    for j = opener.idx + 1, i - 1 do
                        local inner = tokens[j]
                        if inner and inner.category ~= "opening_bracket" and inner.category ~= "closing_bracket" then
                            inner.enclosed = true
                            inner._group_id = group_id
                        end
                    end

                    local prev_t = prev_non_separator_token(tokens, opener.idx)
                    local next_t = next_non_separator_token(tokens, i)
                    local maybe_title_bracket =
                        prev_t and next_t
                        and (prev_t.kind == "word" or prev_t.kind == "number")
                        and (next_t.kind == "word" or next_t.kind == "number")

                    if maybe_title_bracket then
                        local allowed = true
                        for j = opener.idx + 1, i - 1 do
                            local inner = tokens[j]
                            if inner then
                                if inner.kind == "crc32" then
                                    allowed = false
                                    break
                                end
                                if inner.keyword and (
                                    inner.keyword == "resolution"
                                    or inner.keyword == "video"
                                    or inner.keyword == "audio"
                                    or inner.keyword == "source"
                                ) then
                                    allowed = false
                                    break
                                end
                            end
                        end

                        if allowed then
                            for j = opener.idx + 1, i - 1 do
                                if tokens[j] then
                                    tokens[j]._title_bracket = true
                                end
                            end
                        end
                    end

                    break
                end
            end
        end
    end

    tokens._groups = groups
    return groups
end

local function group_to_text(tokens, group)
    if not group then return nil end

    local out = {}
    for i = group.start_idx + 1, group.end_idx - 1 do
        local t = tokens[i]
        if t then
            if t.category == "delimiter" then
                out[#out + 1] = " "
            elseif t.category ~= "opening_bracket" and t.category ~= "closing_bracket" then
                out[#out + 1] = t.value
            end
        end
    end

    local s = table.concat(out)
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function group_is_metadata_like(tokens, group)
    for i = group.start_idx + 1, group.end_idx - 1 do
        local t = tokens[i]
        if t then
            if t.kind == "crc32" then
                return true
            end

            if t.kind == "number" then
                local n = tonumber(t.value)
                if n and looks_like_resolution(n) then
                    return true
                end
            end

            if t.keyword and (
                t.keyword == "resolution"
                or t.keyword == "video"
                or t.keyword == "audio"
                or t.keyword == "source"
                or t.keyword == "subtitles"
            ) then
                return true
            end
        end
    end
    return false
end

local function mark_release_group_tokens(tokens, metadata_boundary)
    if type(tokens) ~= "table" then return nil end

    for i = 1, #tokens do
        if tokens[i] then
            tokens[i]._is_release_group = false
        end
    end

    local groups = tokens._groups or {}
    local chosen = nil

    for i = 1, #groups do
        local g = groups[i]
        if g
           and g.start_idx <= math.floor(#tokens * 0.40)
           and not group_is_metadata_like(tokens, g)
           and (not metadata_boundary or g.start_idx < metadata_boundary)
        then
            local text = group_to_text(tokens, g)
            if text and text ~= "" then
                chosen = g
                break
            end
        end
    end

    if not chosen then
        for i = #groups, 1, -1 do
            local g = groups[i]
            if g
               and g.end_idx >= math.floor(#tokens * 0.60)
               and not group_is_metadata_like(tokens, g)
            then
                local text = group_to_text(tokens, g)
                if text and text ~= "" then
                    chosen = g
                    break
                end
            end
        end
    end

    if not chosen then
        return nil
    end

    for i = chosen.start_idx + 1, chosen.end_idx - 1 do
        if tokens[i] then
            tokens[i]._is_release_group = true
        end
    end

    return group_to_text(tokens, chosen)
end

local function all_unknown_tokens_are_enclosed(tokens, metadata_boundary)
    local count = 0

    for i = 1, #tokens do
        local t = tokens[i]
        if t then
            local before_boundary = (not metadata_boundary) or i < metadata_boundary
            local unknown_candidate =
                t.kind ~= "separator"
                and t.category ~= "opening_bracket"
                and t.category ~= "closing_bracket"
                and not t.keyword
                and type(t.value) == "string"
                and #t.value > 1

            if before_boundary and unknown_candidate then
                count = count + 1
                if not t.enclosed then
                    return false, count
                end
            end
        end
    end

    return count > 0, count
end

------------------------------------------------------------
-- STRING NORMALIZATION
------------------------------------------------------------
local function norm(s)
    if not s then return "" end
    s = s:lower()
    s = s:gsub("&","and")
    s = s:gsub("[^%w%s]"," ")
    s = s:gsub("%s+"," ")
    return s:match("^%s*(.-)%s*$") or ""
end

------------------------------------------------------------
-- JAPANESE NUMBER
------------------------------------------------------------
local function match_japanese_season(tokens, i)
	local t = tokens[i]
	if not t or t.kind ~= "word" then return nil end

	local jp = JAPANESE_NUMBERS[t.value:lower()]
	if not jp then return nil end

	local j = i + 1

	-- skip separators
	while tokens[j] and tokens[j].kind == "separator" do
		j = j + 1
	end

	if not tokens[j] or tokens[j].value:lower() ~= "no" then
		return nil
	end

	j = j + 1

	while tokens[j] and tokens[j].kind == "separator" do
		j = j + 1
	end

	if tokens[j] and tokens[j].value:lower():match("^shou") then
		return jp
	end

	return nil
end

------------------------------------------------------------
-- MOVIE TITLE BOUNDARY DETECTION
------------------------------------------------------------
local function detect_movie_boundary(tokens)

    for i = 1, #tokens do

        local t = tokens[i]
        if not t or t.kind ~= "word" then goto continue end

        local v = t.value:lower()

        if MOVIE_BOUNDARY_WORDS[v] then

            local n1 = tokens[i+1]

            if n1 and n1.kind == "number" then
                return {
                    boundary = i,
                    movie_number = tonumber(n1.value)
                }
            end

            return {
                boundary = i,
                movie_number = nil
            }

        end

        ::continue::
    end

    return nil
end

local function resolve_number_role(tokens, i)

    local t = tokens[i]
    if not t or t.kind ~= "number" then return nil end

    local function neighbor_word_value(idx, step)
        local j = idx + step
        while tokens[j] and tokens[j].kind == "separator" do
            j = j + step
        end
        if not tokens[j] then
            return nil, nil
        end
        return tokens[j].value:lower(), j
    end

    local function has_separator_between(left, right, value)
        if not left or not right then return false end
        local a = math.min(left, right) + 1
        local b = math.max(left, right) - 1
        for k = a, b do
            if tokens[k] and tokens[k].value == value then
                return true
            end
        end
        return false
    end

    local prev, prev_idx = neighbor_word_value(i, -1)

    -- Movie index
    if prev == "movie" or prev == "film" then
        return "movie_index"
    end

    -- Episode keyword
    if prev == "episode" or prev == "ep" then
        return "episode"
    end

    -- Season keyword
    if prev == "season" then
        -- Treat dashed forms like "Season - 09" as episode context, not season index.
        if has_separator_between(prev_idx, i, "-") then
            return "unknown"
        end
        return "season"
    end

    -- Part keyword
    if prev == "part" then
        return "part"
    end

    -- Cour keyword
    if prev == "cour" then
        return "cour"
    end

    -- Year
    local n = tonumber(t.value)
    if looks_like_year(n) then
        return "year"
    end

    return "unknown"
end

------------------------------------------------------------
-- METADATA BOUNDARY DETECTION
------------------------------------------------------------
local METADATA_HINTS = {
    ["1080p"]=true,
    ["720p"]=true,
    ["480p"]=true,
    ["2160p"]=true,
    ["bluray"]=true,
    ["bdrip"]=true,
    ["webrip"]=true,
    ["webdl"]=true,
    ["x264"]=true,
    ["x265"]=true,
    ["h264"]=true,
    ["h265"]=true
}

local function detect_metadata_boundary(tokens)

    for i = 1, #tokens do

        local t = tokens[i]
        if not t then goto continue end

        local v = t.value:lower()

        if METADATA_HINTS[v] then
            return i
        end

        ::continue::
    end

    return nil
end

------------------------------------------------------------
-- STRUCTURAL PATTERN DETECTION
------------------------------------------------------------
-- Seed season/episode from high-confidence filename structures
-- before token-by-token heuristics run.
local function detect_structural_patterns(filename)
    local patterns = {}
    if type(filename) ~= "string" or filename == "" then
        return patterns
    end

    local lower = normalize_filename_for_parse(filename):lower()

    local function parse_word_ordinal(word)
        return ORDINAL_WORD_NUMBERS[word]
    end

    -- Explicit season ranges: "Seasons 1-3" / "Season 01 ~ 03"
    do
        local s1, s2 = lower:match("seasons?%s+(%d+)%s*[%-%~]%s*(%d+)")
        if s1 and s2 then
            patterns.season = tonumber(s1)
            patterns.season_end = tonumber(s2)
        end
    end

    -- Combined token episode range: S01E01-13 / S01EP29~31
    if not patterns.episode then
        local s, e1, e2 = lower:match("%f[%w]s(%d+)e[p]?(%d+)%s*[%-%~]%s*(%d+)%f[%W]")
        if s and e1 and e2 then
            patterns.season = tonumber(s)
            patterns.episode = tonumber(e1)
            patterns.episode_end = tonumber(e2)
        end
    end

    -- Combined token: S01E02 / S01EP02 / S01OVA01 / S01SP01
    --if not patterns.episode then
        --local s, e = lower:match("%f[%w]s(%d+)e(%d+)%f[%W]")
        --if not s then s, e = lower:match("%f[%w]s(%d+)ep(%d+)%f[%W]") end
        --if not s then s, e = lower:match("%f[%w]s(%d+)ova(%d+)%f[%W]") end
        --if not s then s, e = lower:match("%f[%w]s(%d+)oad(%d+)%f[%W]") end
        --if not s then s, e = lower:match("%f[%w]s(%d+)sp(%d+)%f[%W]") end
        --if s and e then
            --patterns.season = tonumber(s)
            --patterns.episode = tonumber(e)
        --end
    --end

    -- 01x02 format (guard against resolutions like 1920x1080)
    if not (patterns.season and patterns.episode) then
        local s, e = lower:match("%f[%d](%d+)[x](%d+)%f[%D]")
        if s and e then
            local sn = tonumber(s)
            local en = tonumber(e)
            if sn and en and sn > 0 and sn <= 30 and en > 0 and en <= 500 then
                if not (en < 10 and not e:match("^0%d$")) then
                    patterns.season = sn
                    patterns.episode = en
                end
            end
        end
    end

    -- Fansub style: "2nd Season - 09" / "2nd Season - 09-13"
    if not (patterns.season and patterns.episode) then
        local ord_num, ep_num, ep_end = lower:match("(%d+)%a%a%s+season%s*%-%s*(%d+)%s*[%-%~]%s*(%d+)")
        if ord_num and ep_num and ep_end then
            patterns.season = tonumber(ord_num)
            patterns.episode = tonumber(ep_num)
            patterns.episode_end = tonumber(ep_end)
        else
            ord_num, ep_num = lower:match("(%d+)%a%a%s+season%s*%-%s*(%d+)")
            if ord_num and ep_num then
                patterns.season = tonumber(ord_num)
                patterns.episode = tonumber(ep_num)
            end
        end
    end

    -- Word ordinal style: "First Season - 09"
    if not (patterns.season and patterns.episode) then
        local ord_word, ep_num = lower:match("(%a+)%s+season%s*%-%s*(%d+)")
        local ord_num = ord_word and parse_word_ordinal(ord_word)
        if ord_num and ep_num then
            patterns.season = ord_num
            patterns.episode = tonumber(ep_num)
        end
    end

    -- Variant: "Season 2 - 09" / "Season 2 - 09-13"
    if not (patterns.season and patterns.episode) then
        local season_num, ep_num, ep_end = lower:match("season%s+(%d+)%s*%-%s*(%d+)%s*[%-%~]%s*(%d+)")
        if season_num and ep_num and ep_end then
            patterns.season = tonumber(season_num)
            patterns.episode = tonumber(ep_num)
            patterns.episode_end = tonumber(ep_end)
        else
            season_num, ep_num = lower:match("season%s+(%d+)%s*%-%s*(%d+)")
            if season_num and ep_num then
                patterns.season = tonumber(season_num)
                patterns.episode = tonumber(ep_num)
            end
        end
    end

    -- Variant: "S1 - 09" / "S1 - 09-13"
    if not (patterns.season and patterns.episode) then
        local season_num, ep_num, ep_end = lower:match("%f[%w]s(%d+)%s*%-%s*(%d+)%s*[%-%~]%s*(%d+)%f[%W]")
        if season_num and ep_num and ep_end then
            patterns.season = tonumber(season_num)
            patterns.episode = tonumber(ep_num)
            patterns.episode_end = tonumber(ep_end)
        else
            season_num, ep_num = lower:match("%f[%w]s(%d+)%s*%-%s*(%d+)%f[%W]")
            if season_num and ep_num then
                patterns.season = tonumber(season_num)
                patterns.episode = tonumber(ep_num)
            end
        end
    end

    return patterns
end

------------------------------------------------------------
-- CONTEXT PARSER
------------------------------------------------------------
local function parseContext(tokens, patterns)

    local info = {
        title = nil,
        season = nil,
        season_end = nil,
		part = nil,
        cour = nil,
        episode = nil,
        episode_end = nil,
        _episode_anchor_idx = nil,
        episode_alt = nil,
        movie_index = nil,
        release_group = nil,
        episode_title = nil,
        type = "unknown",
        metadata = {},
        year = nil,
        airdate = nil,
        file_checksum = nil,
        file_extension = nil,

        _episode_score = 0,
        _movie_score = 0
    }
	
	------------------------------------------------------------
	-- APPLY STRUCTURAL PATTERNS
	------------------------------------------------------------
	if patterns then

		if patterns.movie_index then
			info.movie_index = patterns.movie_index
			info._movie_score = info._movie_score + 150
		end

		if patterns.episode then
			info.episode = patterns.episode
			info._episode_score = info._episode_score + 120
		end

		if patterns.episode_end then
			info.episode_end = patterns.episode_end
			info._episode_score = info._episode_score + 20
		end

		if patterns.season then
			info.season = patterns.season
		end

		if patterns.season_end then
			info.season_end = patterns.season_end
		end

		if patterns.year then
			info.year = patterns.year
		end
		
		if patterns.movie_boundary then
			info._movie_score = info._movie_score + 200
		end

	end

    local title_parts = {}
    local ep_title_parts = {}
    local inside_brackets = false
    local state = "title"

    local total_tokens = #tokens
	
	local number_context = nil -- allowed values: "part", "cour", "episode"
	
	local duration = mp.get_property_number("duration", 0) -- seconds

    local function prev_non_separator(idx)
        local j = idx - 1
        while tokens[j] and tokens[j].kind == "separator" do
            j = j - 1
        end
        return tokens[j]
    end

    local function next_non_separator(idx)
        local j = idx + 1
        while tokens[j] and tokens[j].kind == "separator" do
            j = j + 1
        end
        return tokens[j]
    end

    local function next_non_separator_index(idx)
        local j = idx + 1
        while tokens[j] and tokens[j].kind == "separator" do
            j = j + 1
        end
        return j, tokens[j]
    end

    local function has_dash_between_indices(left, right)
        if not left or not right then return false end
        local a = math.min(left, right) + 1
        local b = math.max(left, right) - 1
        for k = a, b do
            if tokens[k] and tokens[k].value == "-" then
                return true
            end
        end
        return false
    end

    local function has_range_separator_between_indices(left, right)
        if not left or not right then return false end
        local a = math.min(left, right) + 1
        local b = math.max(left, right) - 1
        for k = a, b do
            if tokens[k] and (tokens[k].value == "-" or tokens[k].value == "~") then
                return true
            end
        end
        return false
    end

    local function metadata_bucket_key(raw_key)
        if raw_key == "subtitle" then
            return "subtitles"
        end
        return raw_key
    end

    local function metadata_push_unique(raw_key, value)
        local key = metadata_bucket_key(raw_key)
        if type(key) ~= "string" or key == "" then
            return
        end
        if type(value) ~= "string" or value == "" then
            return
        end

        info.metadata[key] = info.metadata[key] or {}
        local bucket = info.metadata[key]
        local nv = norm(value)
        for i = 1, #bucket do
            if norm(bucket[i]) == nv then
                return
            end
        end

        table.insert(bucket, value)
    end

    local function match_multi_keyword_sequence(start_idx)
        local first = tokens[start_idx]
        if not first or first.kind ~= "word" or first._consumed then
            return nil, nil
        end

        for m = 1, #MULTI_TOKEN_KEYWORDS do
            local rule = MULTI_TOKEN_KEYWORDS[m]
            local idx = start_idx
            local matched = true
            local consumed_indices = {}

            for w = 1, #rule.words do
                local tk = tokens[idx]
                if not tk
                   or tk.kind ~= "word"
                   or tk._consumed
                   or tk.value:lower() ~= rule.words[w]
                then
                    matched = false
                    break
                end

                consumed_indices[#consumed_indices + 1] = idx

                if w < #rule.words then
                    idx = next_non_separator_index(idx)
                end
            end

            if matched then
                return rule, consumed_indices
            end
        end

        return nil, nil
    end

    ------------------------------------------------------------
    -- POSITION WEIGHTING
    ------------------------------------------------------------
    local function weight(i)
        local ratio = i / total_tokens
        return 1.2 - (ratio * 0.7) -- stronger early bias
    end

    ------------------------------------------------------------
    -- YEAR VALIDATION
    ------------------------------------------------------------
    local function is_valid_year(n)
        local y = os.date("*t").year
        return n and n >= 1900 and n <= y + 1
    end

    ------------------------------------------------------------
    -- EPISODE TOKEN DETECTOR (AUTHORITATIVE)
    ------------------------------------------------------------
    local function detect_episode_token(v)
        local s, e = v:match("^[Ss](%d+)[Ee][Pp]?(%d+)$")
        if not s then s, e = v:match("^[Ss](%d+)[Oo][Vv][Aa](%d+)$") end
        if not s then s, e = v:match("^[Ss](%d+)[Oo][Aa][Dd](%d+)$") end
        if not s then s, e = v:match("^[Ss](%d+)[Ss][Pp](%d+)$") end
        if not s then s, e = v:match("^(%d+)[xX](%d+)$") end
        if s and e then
            return tonumber(s), tonumber(e)
        end

        local ep = v:match("^[Ee][Pp]?(%d+)$")
            or v:match("^[Ee][Pp]?(%d+)[Vv]%d+$")
            or v:match("^#(%d+)$")
            or v:match("^(%d+)v%d+$")
            or v:match("^(%d+)'$")

        if ep then
            return nil, tonumber(ep)
        end

        return nil, nil
    end

    ------------------------------------------------------------
    -- METADATA KEYWORDS (HARD LOCK)
    ------------------------------------------------------------
    local META_LOCK = {
        ["1080p"]=true,
        ["720p"]=true,
        ["480p"]=true,
        ["WEBRip"]=true,
        ["BluRay"]=true,
        ["x264"]=true,
        ["x265"]=true,
        ["HDRip"]=true,
    }
	
	------------------------------------------------------------
    -- LANGUAGE MAP
    ------------------------------------------------------------
	local LANGUAGE_TAGS = {
		["ENG"]=true,
		["ENGLISH"]=true,
		["FRENCH"]=true,
		["GERMAN"]=true,
		["SPANISH"]=true,
		["HINDI"]=true,
		["MULTI"]=true,
		["DUAL"]=true,
		["AUDIO"]=true,
		["DUAL-AUDIO"]=true,
		["DUBBED"]=true,
		["ONLINE"]=true,
		["WATCH"]=true,
		["FREE"]=true,
	}
	
	------------------------------------------------------------
    -- SCENE TAG MAP
    ------------------------------------------------------------
	local SCENE_TAGS = {
		["PROPER"]=true,
		["REPACK"]=true,
		["REMUX"]=true,
		["EXTENDED"]=true,
		["UNRATED"]=true,
		["IMAX"]=true,
		["THEATRICAL"]=true,
	}

	local metadata_boundary = detect_metadata_boundary(tokens)
    info.release_group = mark_release_group_tokens(tokens, metadata_boundary)
    local all_unknown_enclosed = all_unknown_tokens_are_enclosed(tokens, metadata_boundary)

    ------------------------------------------------------------
    -- MAIN LOOP
    ------------------------------------------------------------
    for i = 1, total_tokens do
	
		if metadata_boundary and i >= metadata_boundary then
			state = "metadata"
		end
		
		-- Hard boundary: stop title capture
		if patterns and patterns.movie_boundary and i >= patterns.movie_boundary then
            state = "episode_title"
		end

        local t = tokens[i]
        local n1 = tokens[i+1]
        local n2 = tokens[i+2]
        local v = t.value
        local consumed = false
        local w = weight(i)
		
		if t._consumed then
			goto continue
		end

        --------------------------------------------------------
        -- BRACKET CONTROL
        --------------------------------------------------------
        if t.category == "opening_bracket" then
            inside_brackets = true

        elseif t.category == "closing_bracket" then
            inside_brackets = false

        elseif not inside_brackets or t._title_bracket or all_unknown_enclosed then
		
			local role = resolve_number_role(tokens, i)
		
			-- CRC32 SUPPRESSION
			if t.kind == "crc32" then
                if not info.file_checksum then
                    info.file_checksum = v:upper()
                end
				consumed = true
			end

            -- Multi-token keyword sequences (Dual Audio, Multiple Subtitles, ...)
            if not consumed and t.kind == "word" then
                local seq_rule, seq_indices = match_multi_keyword_sequence(i)
                if seq_rule then
                    metadata_push_unique(seq_rule.key, seq_rule.value)
                    for idx = 2, #seq_indices do
                        tokens[seq_indices[idx]]._consumed = true
                    end
                    info._movie_score = info._movie_score + (8 * w)
                    consumed = true
                end
            end
		
			--------------------------------------------------------
			-- FILE SIZE SUPPRESSION
			--------------------------------------------------------
			if is_filesize_pattern(tokens, i) then
				info.metadata["filesize"] = info.metadata["filesize"] or {}
				table.insert(info.metadata["filesize"], v)

				info._movie_score = info._movie_score + (20 * w)
				consumed = true
			end
			
			--------------------------------------------------------
			-- BITRATE DETECTION SUPPRESSION
			--------------------------------------------------------
			if is_bitrate_pattern(tokens, i) then
				info.metadata["bitrate"] = info.metadata["bitrate"] or {}
				table.insert(info.metadata["bitrate"], v)

				info._movie_score = info._movie_score + (10 * w)
				consumed = true
			end
			
			--------------------------------------------------------
			-- AUDIO CHANNEL SUPPRESSION
			--------------------------------------------------------
			if is_audio_channel_pattern(tokens, i) then
				info.metadata["audio_channels"] = info.metadata["audio_channels"] or {}
				table.insert(info.metadata["audio_channels"], t.value .. "." .. n2.value)

				info._movie_score = info._movie_score + (15 * w)
				consumed = true
			end
			
			-- Arc suppression
			if t.kind == "word" and v:lower() == "arc" then
				info.metadata["arc"] = true
				consumed = true
			end
			
			-- Part detection (handles "Part2" or "Part 2")
			if not consumed and t.kind == "word" and v:lower():match("^part") then
				-- Inline number (Part2)
				local n = v:match("^[Pp]art(%d+)$")
				if n then
					info.part = tonumber(n)
					info._episode_score = info._episode_score + (20 * w)
					number_context = nil   -- already consumed
					consumed = true
				else
					-- Separate number: Part 2
					number_context = "part"
					consumed = true        -- only Part keyword consumed
				end
			end

			-- Part number after "Part"
			if not consumed and t.kind == "number" and number_context == "part" then
				info.part = tonumber(v)
				info._episode_score = info._episode_score + (20 * w)
				consumed = true
				number_context = nil
			end
			
			-- Cour detection (e.g., Cour2 / Cour 2)
			if not consumed and t.kind == "word" and v:lower():match("^cour") then
				local n = v:match("^[Cc]our(%d+)$")
				if n then
					info.cour = tonumber(n)
					info._episode_score = info._episode_score + (20 * w)
					number_context = nil
					consumed = true
				else
					-- Separate number: Cour 2
					number_context = "cour"
					consumed = true
				end
			end

			-- Cour number after "Cour"
			if not consumed and t.kind == "number" and number_context == "cour" then
				info.cour = tonumber(v)
				info._episode_score = info._episode_score + (20 * w)
				consumed = true
				number_context = nil
			end

            -- Season detection (numeric + Japanese)
            if not consumed and not info.season then
                local vl = v:lower()
                local next_sig_idx, next_sig = next_non_separator_index(i)

                -- S3 / S03v2
                local ss = vl:match("^s(%d+)$") or vl:match("^s(%d+)v%d+$")

                -- 2nd Season / 3rd Season
                local ord = vl:match("^(%d+)%a%a$")

                -- First Season / Second Season
                local ord_word = ORDINAL_WORD_NUMBERS[vl]

                -- Japanese: San no Shou / Ni no Shou
                local js = match_japanese_season(tokens, i)

                if ord and next_sig and next_sig.kind == "word" and next_sig.value:lower() == "season" then
                    info.season = tonumber(ord)
                    info._episode_score = info._episode_score + (30 * w)
                    -- Keep ordinal season wording in the title (e.g., "2nd Season").

                elseif ord_word and next_sig and next_sig.kind == "word" and next_sig.value:lower() == "season" then
                    info.season = ord_word
                    info._episode_score = info._episode_score + (30 * w)

                elseif ss then
                    info.season = tonumber(ss)
                    info._episode_score = info._episode_score + (30 * w)
                    consumed = true

                
                elseif vl == "season" and next_sig and next_sig.kind == "number" then
                    -- Do not treat "Season - 09" as season index 9.
                    -- Keep "Season" in title and let episode detection consume 09.
                    if not has_dash_between_indices(i, next_sig_idx) then
                        info.season = tonumber(next_sig.value)
                        info._episode_score = info._episode_score + (30 * w)
                        consumed = true
                        tokens[next_sig_idx]._consumed = true
                    end

                -- Japanese pattern: "San no Shou"
                elseif js then
                    info.season = js
                    info._episode_score = info._episode_score + (30 * w)
                    --consumed = true
                end
            end
            -- EXPLICIT EPISODE TOKENS (S01E08 / 1x08 / EP08)
            ------------------------------------------------
            local s,e = detect_episode_token(v)
            if (s or e)
			   and not info.episode
			   and not (patterns and patterns.movie_boundary)
			then
                info.season = s or info.season or 1
                info.episode = e
                info._episode_anchor_idx = i
                info._episode_score = info._episode_score + (60 * w)
                state = "episode_title"
				number_context = "episode"
                consumed = true
            end

            ------------------------------------------------
            -- DASH PATTERN: - 08 -
            ------------------------------------------------
            if not consumed
			   and t.kind == "number"
			   and tokens[i-1] and tokens[i-1].value == "-"
			   and tokens[i+1] and tokens[i+1].value == "-"
			   and not info.episode
			then
				info.episode = tonumber(v)
				info._episode_anchor_idx = i
				info.season = info.season or 1
				info._episode_score = info._episode_score + (50 * w)
				state = "episode_title"
				number_context = "episode"
				consumed = true
			end
			
			------------------------------------------------
            -- Title - 08 - Episode Name
            ------------------------------------------------
			if state == "episode_title"
			   and t.kind == "word"
			   and tokens[i-1]
			   and tokens[i-1].kind == "number"
			then
			   info._episode_score = info._episode_score + 10
			end
			
			------------------------------------------------
			-- WORD EPISODE PATTERN (Episode 12)
			------------------------------------------------
			if not consumed
			   and t.kind == "word"
			   and v:lower() == "episode"
			   and n1
			   and n1.kind == "number"
			   and not info.episode
			then
				info.episode = tonumber(n1.value)
				info._episode_anchor_idx = i + 1
				info.season = info.season or 1
				info._episode_score = info._episode_score + (60 * w)
				state = "episode_title"
				number_context = "episode"
				consumed = true
				tokens[i]._consumed = true
				tokens[i+1]._consumed = true
			end
			
			------------------------------------------------
			-- CONTEXTUAL NUMBER ROLES
			------------------------------------------------
			if role == "movie_index" then
				info._movie_score = info._movie_score + (120 * w)
				consumed = true

			elseif role == "episode" then
				info.episode = tonumber(v)
				info._episode_anchor_idx = i
				info.season = info.season or 1
				info._episode_score = info._episode_score + (70 * w)
				state = "episode_title"
				consumed = true

			elseif role == "season" then
				info.season = tonumber(v)
				info._episode_score = info._episode_score + (40 * w)
				consumed = true

			elseif role == "part" then
				info.part = tonumber(v)
				info._episode_score = info._episode_score + (30 * w)
				consumed = true

			elseif role == "cour" then
				info.cour = tonumber(v)
				info._episode_score = info._episode_score + (30 * w)
				consumed = true
			end

            ------------------------------------------------
            -- EPISODE RANGE: 01-13 / 01~13
            ------------------------------------------------
            if not consumed
               and info.episode
               and not info.episode_end
               and info._episode_anchor_idx
               and t.kind == "number"
               and i > info._episode_anchor_idx
               and has_range_separator_between_indices(info._episode_anchor_idx, i)
               and state ~= "metadata"
            then
                local ep_end = tonumber(v)
                if ep_end
                   and ep_end >= info.episode
                   and ep_end <= 1000
                   and not looks_like_resolution(ep_end)
                   and not looks_like_year(ep_end)
                then
                    info.episode_end = ep_end
                    info._episode_score = info._episode_score + (20 * w)
                    consumed = true
                end
            end

            ------------------------------------------------
            -- ALT EPISODE NUMBER: 01 (14)
            ------------------------------------------------
            if not consumed
               and info.episode
               and not info.episode_alt
               and t.kind == "number"
               and tokens[i-1] and tokens[i-1].value == "("
               and tokens[i+1] and tokens[i+1].value == ")"
            then
                local alt = tonumber(v)
                if alt and alt >= 1 and alt <= 2000 then
                    info.episode_alt = alt
                    consumed = true
                end
            end

            ------------------------------------------------
            -- LOOSE EPISODE NUMBER (GUARDED)
            ------------------------------------------------
            local num = tonumber(v)
            local prev_direct = tokens[i-1]
            local next_direct = tokens[i+1]
            local prev_token = prev_non_separator(i)
            local next_token = next_non_separator(i)
            local next_is_year =
                next_token
                and next_token.kind == "number"
                and looks_like_year(tonumber(next_token.value))

            local next_is_resolution =
                n1 and n1.value and n1.value:match("^%d+p$")
            local numeric_title_pattern =
                prev_direct and prev_direct.kind == "word"
                and next_direct and next_direct.kind ~= "separator"
            local prev_is_no_dot =
                tokens[i-1] and tokens[i-1].value == "."
                and tokens[i-2] and tokens[i-2].kind == "word"
                and tokens[i-2].value:lower() == "no"
            local hyphenated_title_number =
                (i <= 3)
                and tokens[i+1] and tokens[i+1].value == "-"
                and tokens[i+2] and tokens[i+2].kind == "word"
            local compound_title_number =
                (i <= 3)
                and tokens[i+1] and tokens[i+1].value == "-"
                and tokens[i+2] and tokens[i+2].kind == "number"
                and tokens[i+3] and tokens[i+3].value == "-"
            local prev_is_decimal = tokens[i-1] and tokens[i-1].value == "." and tokens[i-2] and tokens[i-2].kind == "number"
            local next_is_decimal = tokens[i+1] and tokens[i+1].value == "." and tokens[i+2] and tokens[i+2].kind == "number"
            if not consumed
			   and role == "unknown"
			   and t.kind=="number"
			   and not (patterns and patterns.movie_index == tonumber(v))
			   and not info.episode
			   and num
			   and num >= 1
			   and num < 200
			   and not looks_like_resolution(num)
			   and not looks_like_year(num)
			   and not next_is_year
			   and not numeric_title_pattern
			   and not prev_is_no_dot
			   and not hyphenated_title_number
			   and not compound_title_number
			   and not prev_is_decimal
			   and not next_is_decimal
			   and not next_is_resolution
			   and number_context == nil
			   and state ~= "metadata"
			   and (#title_parts >= 2 or total_tokens > 6)
			then
				info.episode = num
				info._episode_anchor_idx = i
				info.season = info.season or 1
				state = "episode_title"
				number_context = "episode"
				consumed = true
			end

            --------------------------------------------------------
            -- AIRDATE (YYYY MM DD)
            --------------------------------------------------------
            if not consumed
               and t.kind == "number"
               and n1 and n1.kind == "number"
               and n2 and n2.kind == "number"
            then
                local y = tonumber(v)
                local m = tonumber(n1.value)
                local d = tonumber(n2.value)

                if is_valid_year(y) and m <= 12 and d <= 31 then
                    info.airdate = string.format("%04d-%02d-%02d", y, m, d)
                    info._episode_score = info._episode_score + (70 * w)
                    state = "metadata"
                    consumed = true
                end
            end

            --------------------------------------------------------
            -- YEAR (Movie Boundary)
            --------------------------------------------------------
            if not consumed and not info.year and t.kind == "number" then
                local num = tonumber(v)
                if is_valid_year(num) then
                    info.year = num
                    info._movie_score = info._movie_score + (80 * w)
					
					-- Strong movie indicator: Title + Year pattern
					if not info.episode and not info.season then
						info._movie_score = info._movie_score + 120
						state = "metadata"
						number_context = "year_lock"
					end

                    consumed = true
                end
            end

            --------------------------------------------------------
            -- FORMAT LOCK
            --------------------------------------------------------
            if META_LOCK[v:lower()] then
                info._movie_score = info._movie_score + (40 * w)
                state = "metadata"
            end

            --------------------------------------------------------
            -- METADATA COLLECTION
            --------------------------------------------------------
            if t.keyword then
                metadata_push_unique(t.keyword, v)
            end

            --------------------------------------------------------
            -- LANGUAGE TAG STRIPPING
            --------------------------------------------------------
            if t.kind == "word"
               and LANGUAGE_TAGS[t.value:upper()]
            then
                metadata_push_unique("language", v)
                consumed = true
            end

            --------------------------------------------------------
            -- SCENE-TAG NORMALIZATION
            --------------------------------------------------------
            if t.kind == "word"
               and SCENE_TAGS[t.value:upper()]
            then
                metadata_push_unique("scene_tags", v)

                info._movie_score = info._movie_score + (10 * w)
                consumed = true
            end

            --------------------------------------------------------
            -- SAFE TITLE / EPISODE TITLE CAPTURE
            --------------------------------------------------------
            if not consumed
			   and not t.keyword
			   and not LANGUAGE_TAGS[t.value:upper()]
			   and not SCENE_TAGS[t.value:upper()]
			   and not is_release_group(tokens, i)
			then
				local word = v:lower()

				-- Force arc words into TITLE even after dash
				if ARC_TITLE_WORDS[word] and tokens[i+1] and tokens[i+1].value == "-" then
					table.insert(title_parts, v)

				elseif state == "title" and t.kind == "word" then
					local next_token = tokens[i+1]
					local next_next = tokens[i+2]

					-- Hyphen-safe compound capture
					if next_token
					   and next_token.kind == "separator"
					   and next_token.value == "-"
					   and next_next
					   and next_next.kind == "word"
					then
						table.insert(title_parts, v .. "-" .. next_next.value)
						consumed = true
					else
						table.insert(title_parts, v)
					end

				elseif state == "title" and t.kind == "number" then
                    local n = tonumber(v)
                    local next_sig = next_non_separator(i)
                    local next_sig_is_year =
                        next_sig
                        and next_sig.kind == "number"
                        and looks_like_year(tonumber(next_sig.value))

                    -- Keep sequel-style title numbers: "John Wick 3 2019 ..."
                    if next_sig_is_year and n and n >= 0 and n < 1000 then
                        table.insert(title_parts, v)
                    end

				elseif state == "episode_title" and t.kind == "word" then
                    local wl = v:lower()
                    local allow_episode_title_token =
                        (all_unknown_enclosed and t.enclosed)
                        or ((not all_unknown_enclosed) and (not t.enclosed or t._title_bracket))

                    if allow_episode_title_token
                       and not (patterns and patterns.movie_boundary and MOVIE_SUBTITLE_STOPWORDS[wl])
                    then
                        table.insert(ep_title_parts, v)
                    end
                end
			end
        end
		
		-- Clear contextual number lock after consuming its number
		if consumed
		   and t.kind == "number"
		   and (number_context == "part" or number_context == "cour")
		then
			number_context = nil
		end
		::continue::
    end

    -- Habari-like enclosed gating fallback:
    -- when unknown tokens are enclosed, prefer enclosed title tokens before episode anchor.
    if #title_parts == 0 and all_unknown_enclosed and info._episode_anchor_idx then
        for j = 1, info._episode_anchor_idx - 1 do
            local tk = tokens[j]
            if tk
               and tk.enclosed
               and tk.kind ~= "separator"
               and tk.category ~= "opening_bracket"
               and tk.category ~= "closing_bracket"
               and not tk.keyword
               and not is_release_group(tokens, j)
            then
                table.insert(title_parts, tk.value)
            end
        end
    end
	
	------------------------------------------------------------
	-- DETERMINE SOURCE TYPE
	------------------------------------------------------------
	local source_type = nil
	if info.metadata.source then
		for _, s in ipairs(info.metadata.source) do
			local s_lower = s:lower()
			if s_lower:find("web") or s_lower:find("hdtv") then
				source_type = "tv"
			elseif s_lower:find("ova") then
				source_type = "ova"
			elseif s_lower:find("special") then
				source_type = "special"
			elseif s_lower:find("movie") or s_lower:find("film") then
				source_type = "movie"
			end
		end
	end
	
	-- Title-based source override
	if info.title then
		local lt = info.title:lower()
		if lt:find("ova") then
			source_type = "ova"
		elseif lt:find("special") then
			source_type = "special"
		elseif lt:find("movie") or lt:find("film") then
			source_type = "movie"
		end
	end
	source_type = source_type or "tv" -- default fallback
	
	------------------------------------------------------------
	-- DURATION-BASED SCORING
	------------------------------------------------------------
	if duration > 0 then
		local th = DURATION_THRESHOLDS[source_type]
		if th then
			if duration >= th.min and duration <= th.max then
				if th.type == "episode" then
					info._episode_score = info._episode_score + 60
				else
					info._movie_score = info._movie_score + 60
				end
			elseif duration > th.max then
				info._movie_score = info._movie_score + 30
			elseif duration < th.min then
				info._episode_score = info._episode_score + 20
			end
		end
	end

    ------------------------------------------------------------
	-- RATIO-BASED TYPE DECISION + DURATION
	------------------------------------------------------------
	local ep = info._episode_score
	local mv = info._movie_score
	local total = ep + mv

	-- duration check
	if duration > 0 then
		if duration <= EPISODE_MAX then
			ep = ep + 50  -- small boost
		elseif duration >= MOVIE_MIN then
			mv = mv + 50
		end
	end

	if total == 0 then
		info.type = "unknown"
	else
		local ratio = ep / (ep + mv)

		-- Strong episode signals
		if info.episode and info.season then
			info.type = "episode"
		-- Strong movie signals
		elseif info.year and mv > ep * 1.3 then
			info.type = "movie"
		else
			-- Adaptive ratio threshold
			if (ep + mv) > 100 then
				info.type = (ratio >= 0.50) and "episode" or "movie"
			elseif (ep + mv) > 50 then
				info.type = (ratio >= 0.60) and "episode" or "movie"
			else
				info.type = (ratio >= 0.65) and "episode" or "movie"
			end
		end
	end
	
	-- Force type for extremes
	if duration < 15*60 then info.type = "episode" end
	if duration > 120*60 then info.type = "movie" end

    ------------------------------------------------------------
    -- FINALIZE STRINGS
    ------------------------------------------------------------
    if #title_parts > 0 then
        info.title = table.concat(title_parts, " ")
    end
	
	-- Normalize Japanese season wording (San no Shou ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Season 3)
	if info.title and not info.season then
		local js = extract_japanese_season_phrase(info.title)
		if js then
			info.season = js
			-- strip "San no Shou" from title
			info.title = info.title:gsub("%a+%s+no%s+[Ss]hou", "")
			info.title = info.title:gsub("%s+", " "):gsub("%s+$","")
		end
	end

    if #ep_title_parts > 0 then
        info.episode_title = table.concat(ep_title_parts, " ")
    end
	
	------------------------------------------------------------
	-- REMOVE EPISODE TITLE IF SAME AS SERIES TITLE
	------------------------------------------------------------
	if info.title and info.episode_title then
		if norm(info.title) == norm(info.episode_title) then
			info.episode_title = nil
		end
	end
	

    return info
end


-- Source-based duration thresholds (minutes)
local NORMALIZE_DURATION_THRESHOLDS = {
    tv = {episode_max = 45},          -- Episodes usually ÃƒÂ¢Ã¢â‚¬Â°Ã‚Â¤ 45 min
    ova = {episode_max = 60},          -- OVAs 40ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“60 min, treat >60 as movie
    special = {episode_max = 60},      -- Specials 40ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“60 min, treat >60 as movie
    movie = {episode_max = 120},       -- Movies usually > 60 min
}

------------------------------------------------------------
-- TITLE CLEANER
------------------------------------------------------------
local function clean_title(title)

    if not title then return nil end

    local function strip_suffix(pattern)
        local changed = true
        while changed do
            local next_title, count = title:gsub(pattern, "")
            title = next_title
            changed = count > 0
        end
    end

    -- remove underscores (keep periods in canonical titles like 3.0 or R.O.D)
    title = title:gsub("_+", " ")

    -- remove years
    title = title:gsub("%s+19%d%d%s*", "")
    title = title:gsub("%s+20%d%d%s*", "")

    -- remove repeated "Season X"
    --title = title:gsub("%s+[Ss]eason%s+%d+", "")

    -- strip trailing release tags that frequently leak into parsed titles
    strip_suffix("%s+[Oo][Pp]%d+[A-Za-z]?$")
    strip_suffix("%s+[Ee][Dd]%d+[A-Za-z]?$")
    strip_suffix("%s+[Ss][Pp]%d+[A-Za-z]?$")
    strip_suffix("%s+[Oo][Vv][Aa]%d*%.?%d*$")
    strip_suffix("%s+[Pp][Vv]$")
    strip_suffix("%s+[Vv]ol%.?$")
    strip_suffix("%s+[Vv]ol%.?%s*%d+[Vv]?%d*$")
    strip_suffix("%s+[Bb][Dd]$")
    strip_suffix("%s+[Dd][Vv][Dd]$")
    strip_suffix("%s+[Aa]udio$")
    strip_suffix("%s+[Bb]lu%-?[Rr]ay$")

    -- restore a few common punctuated series names after token normalization
    title = title:gsub("%f[%w]R O D%f[%W]", "R.O.D")
    title = title:gsub("%f[%w]D C II%f[%W]", "D.C.II")

    -- remove duplicate spaces
    title = title:gsub("%s+", " ")

    -- trim
    title = title:gsub("^%s+", "")
    title = title:gsub("%s+$", "")

    return title
end

------------------------------------------------------------
-- NORMALIZE
------------------------------------------------------------
local function normalize(p, chosen)
    if not p or not p.title then
        return nil
    end

    ------------------------------------------------
    -- Duration
    ------------------------------------------------
    local duration = mp.get_property_number("duration", 0)
    local duration_min = (duration > 0) and math.floor(duration / 60 + 0.5) or nil

    ------------------------------------------------
    -- Determine source type
    ------------------------------------------------
    local source_type = "tv"
    if p.metadata and p.metadata.source and p.metadata.source[1] then
        source_type = p.metadata.source[1]:lower()
    end

    if not NORMALIZE_DURATION_THRESHOLDS[source_type] then
        source_type = "tv"
    end

    local th = NORMALIZE_DURATION_THRESHOLDS[source_type]

    ------------------------------------------------
    -- Determine final type (without mutating p)
    ------------------------------------------------
    local final_type = p.type

    if duration_min and th then
        if p.type == "episode" and duration_min > th.episode_max and p.year then
            final_type = "movie"
        elseif p.type == "movie" and duration_min <= th.episode_max and not p.year then
            final_type = "episode"
        end
    end

    ------------------------------------------------
    -- Clean title first
    ------------------------------------------------
    local title = clean_title(p.title)

    local function normalized_contains(haystack, needle)
        if not haystack or not needle then return false end
        local nh = norm(haystack)
        local nn = norm(needle)
        return nn ~= "" and nh:find(nn, 1, true) ~= nil
    end

    local function with_year(base)
        if not p.year then return base end
        local y = tostring(p.year)
        if not y:match("^%d%d%d%d$") then return base end

        local yl = y:lower()
        local bl = (base or ""):lower()

        if bl:find("(" .. yl .. ")", 1, true) then
            return base
        end

        if bl:find("%f[%d]" .. yl .. "%f[%D]") then
            return base
        end

        return (base or "") .. " (" .. y .. ")"
    end

    ------------------------------------------------
    -- MOVIES WITH INDEX (highest priority)
    ------------------------------------------------
    if p.movie_index then
        local idx = tostring(p.movie_index)
        local lower_title = title:lower()
        local base = title

        if lower_title:find("%f[%w]movies%f[%W]") then
            if not lower_title:find("%f[%d]" .. idx .. "%f[%D]") then
                base = base .. " " .. idx
            end
        elseif lower_title:find("%f[%w]movie%f[%W]") or lower_title:find("%f[%w]film%f[%W]") then
            if not lower_title:find("%f[%d]" .. idx .. "%f[%D]") then
                base = base .. " " .. idx
            end
        else
            local fname = (p.filename or ""):lower()
            if fname:find("%f[%w]movies%f[%W]") then
                base = string.format("%s Movies %s", base, idx)
            else
                base = string.format("%s Movie %s", base, idx)
            end
        end

        if p.episode_title and p.episode_title ~= "" then
            local ep = clean_title(p.episode_title)
            if ep and ep ~= "" and not normalized_contains(base, ep) then
                base = base .. ": " .. ep
            end
        end

        return with_year(base)
    end
	
	------------------------------------------------
    -- EPISODES
    ------------------------------------------------
    if final_type == "episode" and p.episode then

        local season = p.season or 1
        local se_ep = string.format("S%02dE%02d", season, p.episode)
        if p.episode_end and p.episode_end >= p.episode then
            se_ep = string.format("S%02dE%02d-E%02d", season, p.episode, p.episode_end)
        end

        local base = title

        if p.part and not chosen then
            base = base .. " Part " .. p.part .. " - " .. se_ep
        elseif p.cour and not chosen then
            base = base .. " Cour " .. p.cour .. " - " .. se_ep
        else
            base = base .. " - " .. se_ep
        end

        if p.episode_title and p.episode_title ~= "" then
            base = base .. " - " .. p.episode_title
        end

        return base
    end
    ------------------------------------------------
    -- MOVIES
    ------------------------------------------------
    if final_type == "movie" then
        local base = title

        if p.episode_title and p.episode_title ~= "" then
            local ep = clean_title(p.episode_title)
            local lower_base = base:lower()
            if ep
               and ep ~= ""
               and not normalized_contains(base, ep)
               and (lower_base:find("%f[%w]movie%f[%W]")
                    or lower_base:find("%f[%w]film%f[%W]")
                    or lower_base:find("%f[%w]gekijouban%f[%W]")
                    or lower_base:find("%f[%w]gekijoban%f[%W]"))
            then
                base = base .. ": " .. ep
            end
        end

        return with_year(base)
    end

    ------------------------------------------------
    -- FALLBACK
    ------------------------------------------------
    if p.season and p.season_end and p.season_end >= p.season then
        return string.format("%s - S%02d-S%02d", title, p.season, p.season_end)
    end

    return title
end

------------------------------------------------------------
-- STRONG TITLE MATCH GUARD
------------------------------------------------------------
local function strong_title_match(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end

    local na = norm(a)
    local nb = norm(b)

    if na == nb then return true end

    -- allow Fire Force vs Enen no Shouboutai
    if na:find(nb, 2, true) or nb:find(na, 2, true) then
        return true
    end

    local hits, total = 0, 0
    for w in nb:gmatch("%S+") do
        total = total + 1
        if na:find(w, 1, true) then
            hits = hits + 1
        end
    end

    return total > 0 and (hits / total) >= 0.4
end

local TITLE_MATCH_STOPWORDS = {
    ["the"] = true,
    ["a"] = true,
    ["an"] = true,
    ["no"] = true,
    ["season"] = true,
    ["part"] = true,
    ["cour"] = true,
    ["movie"] = true,
    ["episode"] = true,
}

-- Stricter matcher used for external API results to reduce false positives.
local function provider_strong_title_match(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end

    local na = norm(a)
    local nb = norm(b)

    if na == "" or nb == "" then
        return false
    end

    if na == nb then
        return true
    end

    local min_len = math.min(#na, #nb)
    if min_len >= 10 and (na:find(nb, 1, true) or nb:find(na, 1, true)) then
        return true
    end

    local hits, total = 0, 0
    for w in nb:gmatch("%S+") do
        local is_number = w:match("^%d+$") ~= nil
        local allow = is_number or (#w >= 3 and not TITLE_MATCH_STOPWORDS[w])
        if allow then
            total = total + 1
            if na:find(w, 1, true) then
                hits = hits + 1
            end
        end
    end

    if total == 0 then
        return strong_title_match(a, b)
    end

    return hits >= 2 and (hits / total) >= 0.55
end
------------------------------------------------------------
-- BUILD CORRECTION KEY
------------------------------------------------------------
local function build_correction_key(filename)
    if not filename or filename == "" then return nil end
    return norm(filename)
end

------------------------------------------------------------
-- MAL SEASON EXTRACTION
------------------------------------------------------------
local function extract_season(title)
    if not title then return nil end
    local t = title:lower()

    local n =
        t:match("season%s+(%d+)") or
        t:match("(%d+)%a%a%s+season") or
        t:match("(%d+)[a-z][a-z]?%s+season")

    if n then return tonumber(n) end

    if t:find("final season") then
        return "final"
    end

    return nil
end

------------------------------------------------------------
-- URL ENCODE
------------------------------------------------------------
local function urlencode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    return str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

------------------------------------------------------------
-- SAFE SUBPROCESS WRAPPER
------------------------------------------------------------
local CURL_USER_AGENT = "kahari-parser/1.1"
local CURL_COMMON_ARGS = {
    "--silent",
    "--show-error",
    "--fail",
    "--location",
    "--connect-timeout", "3",
    "--max-time", "8",
    "--retry", "2",
    "--retry-delay", "1",
    "-A", CURL_USER_AGENT,
    "-H", "Accept: application/json"
}

local function list_extend(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end
    for i = 1, #src do
        dst[#dst + 1] = src[i]
    end
end

local function parse_json_safe(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local ok, parsed = pcall(utils.parse_json, raw)
    if not ok or type(parsed) ~= "table" then
        return nil
    end
    return parsed
end

local function append_if_string(list, value)
    if type(value) == "string" and value ~= "" then
        list[#list + 1] = value
    end
end

local function collect_anilist_titles(media)
    local out = {}
    if type(media) ~= "table" then
        return out
    end

    if type(media.title) == "table" then
        append_if_string(out, media.title.english)
        append_if_string(out, media.title.romaji)
        append_if_string(out, media.title.native)
    end

    if type(media.synonyms) == "table" then
        for _, s in ipairs(media.synonyms) do
            append_if_string(out, s)
        end
    end

    return out
end

local function collect_mal_titles(c)
    local out = {}
    if type(c) ~= "table" then
        return out
    end
    append_if_string(out, c.title)
    append_if_string(out, c.title_english)
    append_if_string(out, c.title_japanese)
    return out
end

local function score_single_title_variant(candidate_title, wanted_title)
    if type(candidate_title) ~= "string" or type(wanted_title) ~= "string" then
        return -math.huge
    end

    local candidate_norm = norm(candidate_title)
    local wanted_norm = norm(wanted_title)
    if candidate_norm == "" or wanted_norm == "" then
        return -math.huge
    end

    local score = 0

    if provider_strong_title_match(candidate_title, wanted_title) then
        score = score + 150
    else
        score = score - 120
    end

    local hits, total = 0, 0
    for w in wanted_norm:gmatch("%S+") do
        total = total + 1
        if candidate_norm:find(w, 1, true) then
            hits = hits + 1
        end
    end

    if total == 0 or hits == 0 then
        score = score - 60
    elseif hits == 1 then
        score = score - 20
    else
        score = score + 40
    end

    if candidate_norm == wanted_norm then
        score = score + 150
    elseif candidate_norm:find(wanted_norm, 1, true) or wanted_norm:find(candidate_norm, 1, true) then
        score = score + 50
    end

    return score
end

local function score_best_title_match(titles, wanted_title)
    local best_score = -math.huge
    local best_title = nil

    for _, candidate in ipairs(titles or {}) do
        local s = score_single_title_variant(candidate, wanted_title)
        if s > best_score then
            best_score = s
            best_title = candidate
        end
    end

    return best_score, best_title
end

local function inspect_title_tags(titles)
    local info = {
        seasons = {},
        has_final_season = false,
        part = nil,
        cour = nil,
        has_part_tag = false,
        has_cour_tag = false,
    }

    for _, t in ipairs(titles or {}) do
        local nt = norm(t)
        if nt ~= "" then
            local season_value = extract_season(nt)
            if season_value == "final" then
                info.has_final_season = true
            elseif type(season_value) == "number" then
                info.seasons[season_value] = true
            end

            local pnum = tonumber(nt:match("part%s*(%d+)"))
            if pnum then
                info.has_part_tag = true
                if not info.part then
                    info.part = pnum
                end
            end

            local cnum = tonumber(nt:match("cour%s*(%d+)"))
            if cnum then
                info.has_cour_tag = true
                if not info.cour then
                    info.cour = cnum
                end
            end
        end
    end

    return info
end

local function normalize_space(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function push_unique_query(list, value)
    local cleaned = normalize_space(value)
    if cleaned == "" then
        return
    end

    local nk = norm(cleaned)
    for _, existing in ipairs(list) do
        if norm(existing) == nk then
            return
        end
    end

    list[#list + 1] = cleaned
end

-- Build progressively broader AniList queries: enriched first, then safer fallbacks.
local function build_anilist_search_queries(title, season, part, cour)
    local queries = {}
    local base = normalize_space(title)

    if base == "" then
        return queries
    end

    local enriched = base
    local eff_season = get_effective_season(title, season)

    if eff_season and type(eff_season) == "number" and eff_season > 1
        and not base:lower():find("no%s+shou")
        and not base:lower():find("season")
    then
        enriched = enriched .. " Season " .. eff_season
    end

    if part and type(part) == "number" then
        enriched = enriched .. " Part " .. part
    end

    if cour and type(cour) == "number" then
        enriched = enriched .. " Cour " .. cour
    end

    push_unique_query(queries, enriched)
    push_unique_query(queries, base)

    if eff_season and type(eff_season) == "number" and eff_season > 1 then
        push_unique_query(queries, base .. " Season " .. eff_season)
    end

    return queries
end

-- Build progressively broader MAL/Jikan queries: enriched first, then safer fallbacks.
local function build_mal_search_queries(title, season, part, cour)
    local queries = {}
    local base = normalize_space(title)

    if base == "" then
        return queries
    end

    local enriched = base
    local eff_season = get_effective_season(title, season)

    if eff_season and type(eff_season) == "number" and eff_season > 1
        and not base:lower():find("no%s+shou")
        and not base:lower():find("season")
    then
        enriched = enriched .. " " .. ordinal(eff_season) .. " Season"
    end

    if part and type(part) == "number" then
        enriched = enriched .. " Part " .. part
    end

    if cour and type(cour) == "number" then
        enriched = enriched .. " Cour " .. cour
    end

    push_unique_query(queries, enriched)
    push_unique_query(queries, base)

    if eff_season and type(eff_season) == "number" and eff_season > 1 then
        push_unique_query(queries, base .. " Season " .. eff_season)
    end

    return queries
end

local function async_curl(extra_args, callback)
    local args = { "curl" }
    list_extend(args, CURL_COMMON_ARGS)
    list_extend(args, extra_args)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(success, result)

        if not success or type(result) ~= "table" or result.status ~= 0 then
            callback(nil, result and result.stderr or nil)
            return
        end

        local stdout = result.stdout or ""
        if stdout == "" then
            callback(nil, result.stderr or nil)
            return
        end

        callback(stdout, nil)
    end)
end

------------------------------------------------------------
-- AniList SCORING HELPERS
------------------------------------------------------------
-- Score one AniList media candidate against parsed filename intent.
local function score_anilist_candidate(media, wanted_title, wanted_season, wanted_part, wanted_cour, wanted_episode, wanted_year)
    if type(media) ~= "table" then
        return -math.huge
    end

    if wanted_episode and media.format == "MOVIE" then
        return -math.huge
    end

    local titles = collect_anilist_titles(media)
    local score = score_best_title_match(titles, wanted_title)
    if score < 0 then
        return -math.huge
    end

    local tags = inspect_title_tags(titles)

    if media.format == "TV" then
        score = score + 50
    elseif media.format == "TV_SHORT" then
        score = score + 30
    elseif media.format == "ONA" or media.format == "OVA" then
        score = score + 10
    elseif media.format == "SPECIAL" then
        score = score - 10
    elseif media.format == "MOVIE" then
        score = score - 20
    end

    if media.episodes and wanted_episode then
        if media.episodes >= wanted_episode then
            score = score + 30
        else
            score = score - 50
        end
    end

    if type(media.popularity) == "number" then
        score = score + math.min(media.popularity / 200000, 10)
    end

    if type(wanted_year) == "number" and type(media.seasonYear) == "number" then
        local dy = math.abs(media.seasonYear - wanted_year)
        if dy <= 1 then
            score = score + 15
        elseif dy >= 3 then
            score = score - 20
        end
    end

    if wanted_season then
        if wanted_season == "final" then
            if tags.has_final_season then
                score = score + 300
            elseif next(tags.seasons) ~= nil then
                return -math.huge
            else
                score = score - 80
            end
        elseif tags.seasons[wanted_season] then
            score = score + 200
        elseif next(tags.seasons) ~= nil then
            return -math.huge
        elseif wanted_season > 1 then
            score = score - 30
        end
    end

    if wanted_part then
        if tags.has_part_tag and tags.part and tags.part ~= wanted_part then
            return -math.huge
        end
        if tags.has_part_tag and tags.part == wanted_part then
            score = score + 200
        elseif not tags.has_part_tag then
            score = score - 25
        end
    end

    if wanted_cour then
        if tags.has_cour_tag and tags.cour and tags.cour ~= wanted_cour then
            return -math.huge
        end
        if tags.has_cour_tag and tags.cour == wanted_cour then
            score = score + 200
        elseif not tags.has_cour_tag then
            score = score - 20
        end
    end

    return score
end
local function pick_anilist_title(media)
    if type(media) ~= "table" or type(media.title) ~= "table" then
        return nil
    end
    return media.title.english or media.title.romaji or media.title.native
end

local function strip_episode_prefix(raw)
    if type(raw) ~= "string" then return nil end
    local cleaned = raw
        :gsub("^%s*[Ee][Pp]?[Ii]?[Ss]?[Oo]?[Dd]?[Ee]?%s*%d+%s*[:%-]?%s*", "")
        :gsub("^%s*#%d+%s*[:%-]?%s*", "")
        :gsub("^%s*%d+%s*[:%-]%s*", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if cleaned == "" then return nil end
    return cleaned
end

local function find_streaming_episode_title(items, wanted_episode)
    if type(items) ~= "table" or type(wanted_episode) ~= "number" then return nil end

    local indexed = items[wanted_episode]
    if indexed and indexed.title then
        local direct = strip_episode_prefix(indexed.title)
        if direct then return direct end
    end

    for _, item in ipairs(items) do
        local raw = item and item.title
        if type(raw) == "string" then
            local n = raw:match("^%s*[Ee][Pp]?[Ii]?[Ss]?[Oo]?[Dd]?[Ee]?%s*(%d+)")
                or raw:match("^%s*#(%d+)")
                or raw:match("^%s*(%d+)%s*[:%-]")
            if n and tonumber(n) == wanted_episode then
                local cleaned = strip_episode_prefix(raw)
                if cleaned then return cleaned end
            end
        end
    end

    return nil
end

------------------------------------------------------------
-- AniList ASYNC
------------------------------------------------------------
-- AniList lookup with multi-query fallback; returns highest-confidence parsed result.
local function anilist_async(title, season, part, cour, episode, year, callback)
    local clean_title = title
    local title_key = norm(clean_title or "")
    local key = ("ani:%s:%s:%s:%s:%s:%s"):format(
        title_key,
        tostring(season or ""),
        tostring(part or ""),
        tostring(cour or ""),
        tostring(episode or ""),
        tostring(year or "")
    )

    if not title or title == "" then
        callback(nil)
        return
    end

    local cached = cache_get(key)
    if cached then
        callback(cached)
        return
    end

    local search_queries = build_anilist_search_queries(title, season, part, cour)
    if #search_queries == 0 then
        callback(nil)
        return
    end

    local query = [[
    query ($search: String) {
      Page(perPage: 8) {
        media(search: $search, type: ANIME) {
          id
          format
          status
          episodes
          seasonYear
          popularity
          title {
            romaji
            english
            native
          }
          synonyms
          streamingEpisodes {
            title
          }
        }
      }
    }]]

    local best, best_score, best_query = nil, -math.huge, nil

    -- Finalize once all query variants are evaluated.
    local function finalize_anilist()
        if not best or best_score < 55 then
            callback(nil)
            return
        end

        local parsed = {
            title = pick_anilist_title(best),
            episode_title = nil,
            confidence = 0,
            _provider = "anilist",
            _api_score = best_score,
            _season_year = best.seasonYear,
            _search_query = best_query,
        }

        if episode and best.streamingEpisodes then
            parsed.episode_title = find_streaming_episode_title(best.streamingEpisodes, episode)
        end

        parsed.confidence = calculate_confidence(parsed)

        if best_score > 320 then
            parsed.confidence = parsed.confidence + 20
        elseif best_score > 220 then
            parsed.confidence = parsed.confidence + 10
        end

        cache_put(key, parsed)
        callback(parsed)
    end

    -- Query variants sequentially to avoid bursty API calls.
    local function run_query(idx)
        if idx > #search_queries then
            finalize_anilist()
            return
        end

        local current_query = search_queries[idx]
        debug_match("AniList query: %s", current_query)
        local body = utils.format_json({
            query = query,
            variables = { search = current_query }
        })

        async_curl({
            "-X", "POST",
            "https://graphql.anilist.co",
            "-H", "Content-Type: application/json",
            "-d", body
        }, function(stdout)
            local data = parse_json_safe(stdout)
            if data
               and type(data.data) == "table"
               and type(data.data.Page) == "table"
               and type(data.data.Page.media) == "table"
            then
                for _, media in ipairs(data.data.Page.media) do
                    local score = score_anilist_candidate(media, title, season, part, cour, episode, year)

                    if norm(current_query) == norm(title) then
                        score = score + 20
                    end

                    if score > best_score then
                        best = media
                        best_score = score
                        best_query = current_query
                    end
                end
            end

            if best_score >= 360 then
                finalize_anilist()
                return
            end

            run_query(idx + 1)
        end)
    end

    run_query(1)
end
------------------------------------------------------------
-- MAL SEASON SCORER
------------------------------------------------------------
local SCORE = {
    SEASON_MATCH = 200,
    ORDINAL_MATCH = 250,
    SEASON_TEXT_MATCH = 150,
    FINAL_MATCH = 300,
    PART_MATCH = 200,
}

local function is_invalid_type(c)
    local type_name = (c and c.type or ""):upper()
    if type_name ~= "" and type_name ~= "TV" then
        return true
    end

    local t = norm(c and c.title or "")
    return t:find("movie") or t:find("ova") or t:find("special")
end

-- Score one MAL/Jikan candidate against parsed filename intent.
local function score_mal_candidate(c, wanted_title, wanted_season, highest_numeric_season, wanted_part, wanted_cour)
    if is_invalid_type(c) then
        return -math.huge
    end

    local titles = collect_mal_titles(c)
    local score = score_best_title_match(titles, wanted_title)
    if score < 0 then
        return -math.huge
    end

    local tags = inspect_title_tags(titles)

    if wanted_season then
        if wanted_season == "final" then
            if tags.has_final_season then
                score = score + SCORE.FINAL_MATCH
            elseif next(tags.seasons) ~= nil and highest_numeric_season and tags.seasons[highest_numeric_season] then
                score = score + 40
            elseif next(tags.seasons) ~= nil then
                return -math.huge
            else
                score = score - 80
            end
        elseif tags.seasons[wanted_season] then
            score = score + SCORE.SEASON_MATCH

            local ord = ordinal(wanted_season):lower()
            for _, title_text in ipairs(titles) do
                local nt = norm(title_text)
                if nt:find(ord, 1, true) then
                    score = score + SCORE.ORDINAL_MATCH
                    break
                end
            end

            for _, title_text in ipairs(titles) do
                local nt = norm(title_text)
                if nt:find("season%s+" .. wanted_season) then
                    score = score + SCORE.SEASON_TEXT_MATCH
                    break
                end
            end
        elseif next(tags.seasons) ~= nil then
            return -math.huge
        elseif wanted_season > 1 then
            score = score - 30
        end
    end

    if wanted_part then
        if tags.has_part_tag and tags.part and tags.part ~= wanted_part then
            return -math.huge
        end
        if tags.has_part_tag and tags.part == wanted_part then
            score = score + SCORE.PART_MATCH
        elseif not tags.has_part_tag then
            score = score - 25
        end
    end

    if wanted_cour then
        if tags.has_cour_tag and tags.cour and tags.cour ~= wanted_cour then
            return -math.huge
        end
        if tags.has_cour_tag and tags.cour == wanted_cour then
            score = score + SCORE.PART_MATCH
        elseif not tags.has_cour_tag then
            score = score - 20
        end
    end

    for _, title_text in ipairs(titles) do
        if provider_strong_title_match(title_text, wanted_title) then
            score = score + math.min((c.members or 0) / 50000, 10)
            break
        end
    end

    return score
end
------------------------------------------------------------
-- MAL ASYNC
------------------------------------------------------------
-- MAL lookup with multi-query fallback; returns highest-confidence parsed result.
local function mal_async(title, season, part, cour, episode, year, callback)
    local clean_title = title
    local title_key = norm(clean_title or "")
    local key = ("mal:%s:%s:%s:%s:%s:%s"):format(
        title_key,
        tostring(season or ""),
        tostring(part or ""),
        tostring(cour or ""),
        tostring(episode or ""),
        tostring(year or "")
    )

    if not title or title == "" then
        callback(nil)
        return
    end

    local cached = cache_get(key)
    if cached then
        callback(cached)
        return
    end

    local search_queries = build_mal_search_queries(title, season, part, cour)
    if #search_queries == 0 then
        callback(nil)
        return
    end

    local best, best_score, best_query = nil, -math.huge, nil

    local function extract_mal_year(item)
        if type(item) ~= "table" then
            return nil
        end
        if type(item.year) == "number" then
            return item.year
        end
        if type(item.aired) == "table"
            and type(item.aired.prop) == "table"
            and type(item.aired.prop.from) == "table"
            and type(item.aired.prop.from.year) == "number"
        then
            return item.aired.prop.from.year
        end
        return nil
    end

    -- Score all entries for one query variant and keep global best.
    local function score_dataset(entries, current_query)
        if type(entries) ~= "table" then
            return
        end

        local highest_numeric_season = 1
        for _, c in ipairs(entries) do
            for _, t in ipairs(collect_mal_titles(c)) do
                local s = extract_season(t)
                if type(s) == "number" and s > highest_numeric_season then
                    highest_numeric_season = s
                end
            end
        end

        local effective_season = season
        if type(season) == "number" and season == highest_numeric_season + 1 then
            effective_season = "final"
        end

        for _, c in ipairs(entries) do
            local s = score_mal_candidate(c, clean_title, effective_season, highest_numeric_season, part, cour)

            local cy = extract_mal_year(c)
            if type(year) == "number" and type(cy) == "number" then
                local dy = math.abs(cy - year)
                if dy <= 1 then
                    s = s + 15
                elseif dy >= 3 then
                    s = s - 20
                end
            end

            if norm(current_query) == norm(title) then
                s = s + 20
            end

            if s > best_score then
                best = c
                best_score = s
                best_query = current_query
            end
        end
    end

    -- Finalize once all query variants are evaluated.
    local function finalize_mal()
        if not best or best_score < 55 then
            callback(nil)
            return
        end

        local has_strong_match = false
        for _, t in ipairs(collect_mal_titles(best)) do
            if provider_strong_title_match(t, clean_title) then
                has_strong_match = true
                break
            end
        end

        if not has_strong_match then
            callback(nil)
            return
        end

        local parsed = {
            title = best.title_english or best.title or best.title_japanese,
            episode_title = nil,
            confidence = 0,
            _provider = "mal",
            _api_score = best_score,
            _season_year = extract_mal_year(best),
            _search_query = best_query,
        }

        if best.episodes == 1 then
            parsed._mal_single_episode = true
        end

        if not episode then
            parsed.confidence = calculate_confidence(parsed)
            if best_score > 320 then
                parsed.confidence = parsed.confidence + 20
            elseif best_score > 220 then
                parsed.confidence = parsed.confidence + 10
            end
            cache_put(key, parsed)
            callback(parsed)
            return
        end

        if not best.mal_id then
            cache_put(key, parsed)
            callback(parsed)
            return
        end

        local page = math.floor((episode - 1) / 100) + 1
        local idx = ((episode - 1) % 100) + 1
        local ep_url = "https://api.jikan.moe/v4/anime/" .. best.mal_id .. "/episodes?page=" .. page

        async_curl({ ep_url }, function(ep_stdout)
            local ed = parse_json_safe(ep_stdout)
            if ed and type(ed.data) == "table" and ed.data[idx] then
                local ep = ed.data[idx]
                parsed.episode_title = ep.title_english or ep.title or ep.title_japanese
            end

            parsed.confidence = calculate_confidence(parsed)

            if best_score > 320 then
                parsed.confidence = parsed.confidence + 25
            end

            if best.episodes and episode <= best.episodes then
                parsed.confidence = parsed.confidence + 20
            end

            if season and not extract_season(best.title or "") then
                parsed.confidence = parsed.confidence - 15
            end

            cache_put(key, parsed)
            callback(parsed)
        end)
    end

    -- Query variants sequentially to avoid bursty API calls.
    local function run_query(idx)
        if idx > #search_queries then
            finalize_mal()
            return
        end

        local q = search_queries[idx]
        debug_match("MAL query: %s", q)
        local url = "https://api.jikan.moe/v4/anime?q="
            .. urlencode(q)
            .. "&type=tv&limit=12"

        async_curl({ url }, function(stdout)
            local data = parse_json_safe(stdout)
            if data and type(data.data) == "table" then
                score_dataset(data.data, q)
            end

            if best_score >= 360 then
                finalize_mal()
                return
            end

            run_query(idx + 1)
        end)
    end

    run_query(1)
end
------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------
function Parser:new(filename)
    local original_filename = filename or ""
    local normalized_filename = normalize_filename_for_parse(original_filename)
    local raw = tokenize(normalized_filename)
    local tokens = {}

    for i = 1, #raw do
        local t = classify(raw[i])
        assignKeyword(t)
        tokens[i] = t
    end
    annotate_enclosed_groups(tokens)

    -- Start with structural filename patterns (e.g., "2nd Season - 09").
    local patterns = detect_structural_patterns(normalized_filename)
    local movie_boundary = detect_movie_boundary(tokens)
    if movie_boundary then
        patterns.movie_boundary = movie_boundary.boundary
        patterns.movie_index = movie_boundary.movie_number
    end

    if not next(patterns) then
        patterns = nil
    end

    local ctx = parseContext(tokens, patterns)
    ctx.file_extension = extract_file_extension(original_filename) or ctx.file_extension

    -- Early filename movie hard-lock
    if original_filename:lower():match("%f[%w]movie%f[%W]") then
        ctx._movie_score = ctx._movie_score + 150
    end

    local self = setmetatable(ctx, Parser)
    self.filename = original_filename

    return self
end

------------------------------------------------------------
-- LOAD MEDIA TITLE
------------------------------------------------------------
local function load_media_title()
    local path = mp.get_property("filename/no-ext") or ""

    local p = Parser:new(path)
	local chosen
    if not p.title then return end
	
    -- Avoid stripping explicit season labels like "2nd Season" or "Season 2".
    local lower_title = p.title:lower()
    local has_ordinal_season =
        lower_title:match("%d+st%s+season$") ~= nil
        or lower_title:match("%d+nd%s+season$") ~= nil
        or lower_title:match("%d+rd%s+season$") ~= nil
        or lower_title:match("%d+th%s+season$") ~= nil

    local has_explicit_season_label =
        has_ordinal_season
        or lower_title:match("%d+%s+season$") ~= nil
        or lower_title:match("season%s+%d+$") ~= nil
        or lower_title:match("final%s+season$") ~= nil

    if not has_explicit_season_label then
        p.title = p.title:gsub("%s+[Ss]eason$", "")
    end
	
	local function apply_final()
        local final = normalize(p, chosen)
        if final then
            mp.set_property("force-media-title", final)
        end
    end
	
	apply_final()
	
	--mp.set_property("force-media-title", p.title)
	
	local ani_result, mal_result
	local ani_done = false
	local mal_done = false
	local resolved = false

	local TIMEOUT_SECONDS = 4.0
    -- Convert provider result into a comparable vote for final arbitration.
    local function result_vote(result)
        if not result then
            return -math.huge
        end

        local score = tonumber(result.confidence or 0) or 0

        if type(result._api_score) == "number" then
            score = score + math.min(result._api_score / 15, 30)
        end

        if result.title and provider_strong_title_match(result.title, p.title) then
            score = score + 35
        else
            score = score - 70
        end

        if type(p.season) == "number" and p.season > 1 and result.title then
            local rs = extract_season(result.title)
            if type(rs) == "number" then
                if rs == p.season then
                    score = score + 18
                else
                    score = score - 40
                end
            end
        end

        if p.year and result._season_year then
            local yr = tonumber(result._season_year)
            local py = tonumber(p.year)
            if yr and py then
                local dy = math.abs(yr - py)
                if dy <= 1 then
                    score = score + 14
                elseif dy >= 3 then
                    score = score - 18
                end
            end
        end

        if p.episode then
            if result.episode_title and result.episode_title ~= "" then
                score = score + 10
            else
                score = score - 4
            end
        end

        return score
    end

    -- Decide whether to trust API results over parsed filename title.
    local function finalize(force)
        if resolved then return end

        if not force then
            if not ani_done or not mal_done then
                return
            end
        end

        if not ani_result and not mal_result then
            resolved = true
            return
        end

        resolved = true

        local ani_vote = result_vote(ani_result)
        local mal_vote = result_vote(mal_result)

        if ani_result and mal_result and ani_result.title and mal_result.title
           and norm(ani_result.title) == norm(mal_result.title)
        then
            ani_vote = ani_vote + 15
            mal_vote = mal_vote + 15
        end

        if ani_result and mal_result and p.episode then
            if ani_result.episode_title and not mal_result.episode_title then
                ani_vote = ani_vote + 8
            elseif mal_result.episode_title and not ani_result.episode_title then
                mal_vote = mal_vote + 8
            end
        end

        if ani_vote == -math.huge and mal_vote == -math.huge then
            return
        end

        local best_vote = math.max(ani_vote, mal_vote)
        if best_vote < 20 then
            debug_match("skip API override: low confidence votes ani=%.1f mal=%.1f", tonumber(ani_vote or 0), tonumber(mal_vote or 0))
            return
        end
        if ani_vote > mal_vote + 6 then
            chosen = ani_result
        elseif mal_vote > ani_vote + 6 then
            chosen = mal_result
        else
            if ani_result and mal_result then
                local ani_has_ep = ani_result.episode_title and ani_result.episode_title ~= ""
                local mal_has_ep = mal_result.episode_title and mal_result.episode_title ~= ""
                if ani_has_ep and not mal_has_ep then
                    chosen = ani_result
                elseif mal_has_ep and not ani_has_ep then
                    chosen = mal_result
                else
                    chosen = ani_result or mal_result
                end
            else
                chosen = ani_result or mal_result
            end
        end

        if chosen then
            debug_match("winner=%s ani_vote=%.1f mal_vote=%.1f title=%s", tostring(chosen._provider or "unknown"), tonumber(ani_vote or 0), tonumber(mal_vote or 0), tostring(chosen.title or ""))
            p.title = chosen.title or p.title
            p.episode_title = chosen.episode_title or p.episode_title
            apply_final()
        end
    end
    -- this prevents mpv from hanging forever waiting on one API.
	mp.add_timeout(TIMEOUT_SECONDS, function()
		finalize(true)  -- force resolution
	end)

	anilist_async(p.title, p.season, p.part, p.cour, p.episode, p.year, function(a)
		ani_result = a
		ani_done = true
		finalize(false)
	end)

	mal_async(p.title, p.season, p.part, p.cour, p.episode, p.year, function(m)
		mal_result = m
		mal_done = true
		finalize(false)
	end)
	
end

mp.register_event("file-loaded", load_media_title)

