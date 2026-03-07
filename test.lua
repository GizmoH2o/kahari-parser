local json = require("json")
local parser = require("kahari_parser")

local file = io.open("anime_filename_dataset.json", "r")
local dataset = json.decode(file:read("*all"))

for _, case in ipairs(dataset.cases) do
    local result = parser.parse(case.filename)
    print(case.filename, result.title, result.episode)
end
