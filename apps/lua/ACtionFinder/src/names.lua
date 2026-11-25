-- Driver names for the tower: initials, unique per car.
-- Pure Lua, so it can be tested outside the game: luajit tests/test_names.lua

local M = {}

-- UTF-8 characters of a string (Lua patterns work on bytes).
local UTF8_CHAR = '[%z\1-\127\194-\244][\128-\191]*'

local function firstChar(word)
  return word:match(UTF8_CHAR) or ''
end

local function isLetterStart(word)
  local b = word:byte(1)
  if not b then return false end
  if b >= 0xC0 then return true end          -- non-ASCII letter (é, ø, Č ...)
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- Only the first driver of a shared car ("Renaud Kuppens - Bas Leinders").
local function firstDriver(name)
  for _, sep in ipairs({ ' - ', ' / ', ' & ', ' + ', ' | ' }) do
    local i = name:find(sep, 1, true)
    if i then name = name:sub(1, i - 1) end
  end
  return name
end

-- Words of a name: split on spaces, dots, underscores and hyphens, and on a capital
-- after a small letter ("YoungsterBen" -> "Youngster", "Ben"). Words that do not start
-- with a letter (numbers, "*", "[TAG]"...) are left out.
local function words(name)
  name = name:gsub('%[.-%]', ' '):gsub('%(.-%)', ' ')
  name = name:gsub('(%l)(%u)', '%1 %2')
  local out = {}
  for w in name:gmatch('[^%s%._%-]+') do
    if isLetterStart(w) then out[#out + 1] = w end
  end
  return out
end

-- Initials of one name: "Pieter van den Broek" -> "PVDB", "Grimbor" -> "GRI".
function M.initials(name)
  local list = words(firstDriver(name or ''))
  if #list == 0 then return nil end
  if #list == 1 then
    local w, out, n = list[1], {}, 0
    for c in w:gmatch(UTF8_CHAR) do
      n = n + 1
      out[n] = c
      if n == 3 then break end
    end
    return table.concat(out):upper()
  end
  local out = {}
  for i, w in ipairs(list) do out[i] = firstChar(w) end
  return table.concat(out):upper()
end

-- Initials for a set of cars: `drivers` maps car index -> name. Cars with the same
-- initials get a number, in car index order ("PS", "PS2"), so a car keeps its label
-- when the order on track changes. Returns car index -> label.
function M.uniqueInitials(drivers)
  local indices = {}
  for index in pairs(drivers) do indices[#indices + 1] = index end
  table.sort(indices)
  local out, seen = {}, {}
  for _, index in ipairs(indices) do
    local base = M.initials(drivers[index]) or ('#' .. tostring(index + 1))
    local n = (seen[base] or 0) + 1
    seen[base] = n
    out[index] = n == 1 and base or (base .. n)
  end
  return out
end

return M
