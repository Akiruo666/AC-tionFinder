-- Checks the initials of the tower (src/names.lua).
--   luajit tests/test_names.lua
package.path = 'apps/lua/ACtionFinder/?.lua;' .. package.path
local Names = require('src/names')

local cases = {
  { 'Philip Stuyck', 'PS' },
  { 'Pieter van den Broek', 'PVDB' },
  { 'Renaud Kuppens - Bas Leinders', 'RK' },
  { 'Grimbor', 'GRI' },
  { 'Jack', 'JAC' },
  { 'YoungsterBen', 'YB' },
  { 'Si Woodc*ck', 'SW' },
  { 'Bernt Grøndal', 'BG' },
  { 'Petr Čížek', 'PČ' },
  { 'Jean-Pierre Dupont', 'JPD' },
  { '[TCR] Oscar Rottink', 'OR' },
  { 'Matthew Williams 77', 'MW' },
  { '', nil },
  { '1234', nil },
}
local failures = 0
for _, c in ipairs(cases) do
  local got = Names.initials(c[1])
  local ok = got == c[2]
  if not ok then failures = failures + 1 end
  print(string.format('%-32s -> %-6s %s', c[1], tostring(got), ok and 'OK' or ('WRONG, expected ' .. tostring(c[2]))))
end

local labels = Names.uniqueInitials({ [0] = 'Philip Stuyck', [3] = 'Peter Smith', [1] = 'Paul Simons', [2] = 'Jack', [5] = '' })
local expect = { [0] = 'PS', [1] = 'PS2', [2] = 'JAC', [3] = 'PS3', [5] = '#6' }
for i, v in pairs(expect) do
  local ok = labels[i] == v
  if not ok then failures = failures + 1 end
  print(string.format('unique car %d -> %-6s %s', i, tostring(labels[i]), ok and 'OK' or ('WRONG, expected ' .. v)))
end
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
