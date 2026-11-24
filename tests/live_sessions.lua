-- Live session test outside the game: qualifying, then a race (the situation where the
-- order was wrong in version 0.2). Fake `ac`/`ui` functions; checks the order and laps
-- of the classification against the known positions of the fake cars.
--   luajit tests/live_sessions.lua
package.path = 'apps/lua/ACtionFinder/?.lua;' .. package.path

local V = {}
V.__index = V
V.__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end
function vec2(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V) end
function vec3(x, y, z) return { x = x, y = y, z = z, set = function() end } end
function rgbm(r, g, b, m) return {} end

local N = 12
local sim = { isReplayActive = false, carsCount = N, focusedCar = 0, trackLengthM = 3700,
  currentSessionIndex = 1, sessionsCount = 3, raceSessionType = 2, isSessionStarted = true }
local cars, truth = {}, {}      -- truth[i] = real progress in laps
local callbacks = {}
for i = 0, N - 1 do
  cars[i] = { index = i, splinePosition = 0, lapCount = 0, speedKmh = 150, isActive = true,
    isInPitlane = false, bestLapTimeMs = 90000 + i * 137, previousLapTimeMs = 91000, distanceDrivenSessionKm = 0 }
end
ac = {
  getSim = function() return sim end,
  getCar = function(i) return cars[i] end,
  getDriverName = function(i) return 'Driver ' .. i end,
  focusCar = function(i) sim.focusedCar = i end,
  getFolder = function(id) return '/fake' end,
  FolderID = {},
  INIConfig = { load = function() return nil end },
  onSessionStart = function(cb) callbacks.session = cb end,
  onCarJumped = function(car, cb) callbacks.jumped = cb end,
  onReplay = function(cb) end,
  onClientConnected = function(cb) end,
  onClientDisconnected = function(cb) end,
}
local function noop() end
ui = setmetatable({ getCursor = function() return vec2(0, 0) end, availableSpaceX = function() return 600 end,
  availableSpaceY = function() return 300 end, textLineHeightWithSpacing = function() return 18 end,
  slider = function(l, v) return v, false end, childWindow = function(id, s, b, fn) fn() end,
  tabBar = function(id, fn) fn() end, tabItem = function(l, fn) fn() end, StyleColor = { Text = 0 } },
  { __index = function() return function() return false end end })

local now = 0
os.preciseClock = function() return now end
script = {}
dofile('apps/lua/ACtionFinder/ACtionFinder.lua')
local function upvalue(fn, name)
  for i = 1, 300 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then return nil end
    if n == name then return v end
  end
end
local cls = upvalue(script.update, 'cls')

-- Moves every car; the game's lap count follows `lag` updates after the line.
local pendingLap = {}
local function drive(speeds, lag, useEvent)
  for i = 0, N - 1 do
    truth[i] = truth[i] + speeds[i]
    local p = truth[i]
    cars[i].splinePosition = p % 1
    local completed = math.max(0, math.floor(p))
    if completed ~= cars[i].lapCount then
      pendingLap[i] = (pendingLap[i] or 0) + 1
      if pendingLap[i] > lag then cars[i].lapCount, pendingLap[i] = completed, 0 end
    end
    cars[i].distanceDrivenSessionKm = math.max(0, p + 0.03) * 3.7
  end
  now = now + 0.1
  script.update(0.1)
end

local failures = 0
local function check(label, expectLapOf)
  local rows = cls.rows
  local ok = true
  for k = 2, #rows do
    if truth[rows[k - 1].index] < truth[rows[k].index] then ok = false end
  end
  local lapsOk = true
  for _, r in ipairs(rows) do
    if r.lap ~= math.max(1, math.floor(truth[r.index]) + 1) then lapsOk = false end
  end
  print(string.format('%-45s order %s, laps %s (leader %s lap %d)', label, ok and 'OK' or 'WRONG',
    lapsOk and 'OK' or 'WRONG', rows[1].name, rows[1].lap))
  if not ok or not lapsOk then failures = failures + 1 end
end

-- Qualifying: every car did a different number of laps.
for i = 0, N - 1 do truth[i] = 3 + (i * 0.73) % 6 end
local speeds = {}
for i = 0, N - 1 do speeds[i] = 0.0011 + i * 0.00002 end
for _ = 1, 600 do drive(speeds, 2) end
check('qualifying, 60 s')

-- A car is sent back to the pits (teleport), with and without the event.
truth[5] = math.floor(truth[5]) + 0.97
for _ = 1, 50 do drive(speeds, 2) end
check('qualifying, car 5 teleported to the pits')

-- Session change to the race: lap counts go to 0, cars on the grid behind the line.
sim.currentSessionIndex, sim.raceSessionType, sim.isSessionStarted = 2, 3, false
for i = 0, N - 1 do
  truth[i] = -(0.002 + i * 0.003)     -- grid: 7, 11, 15 ... metres behind the line
  cars[i].lapCount, pendingLap[i] = 0, 0
end
local zero = {}
for i = 0, N - 1 do zero[i] = 0 end
for _ = 1, 20 do drive(zero, 3) end
check('race, on the grid')
sim.isSessionStarted = true
for i = 0, N - 1 do speeds[i] = 0.0011 - i * 0.00003 end
for _ = 1, 3000 do drive(speeds, 3) end
check('race, 5 minutes (lap count 0.3 s late)')
for _ = 1, 6000 do drive(speeds, 3) end
check('race, 15 minutes')
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
os.exit(failures == 0 and 0 or 1)
