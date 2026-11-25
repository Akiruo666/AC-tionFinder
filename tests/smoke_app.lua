-- Smoke test: runs the app outside the game with fake `ac`, `ui` and `io` functions,
-- to catch Lua errors (nil calls, typos) in every tab. It does not test what the game
-- really does.
--   luajit tests/smoke_app.lua <file.acreplay>
local replayPath = assert(arg[1], 'usage: luajit tests/smoke_app.lua <file.acreplay>')
package.path = 'apps/lua/ACtionFinder/?.lua;' .. package.path

-- vec2 / rgbm
local V = {}
V.__index = V
V.__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end
function vec2(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V) end
function rgbm(r, g, b, m) return { r = r, g = g, b = b, mult = m } end
local V3 = {}
V3.__index = V3
function V3:set(x, y, z) self.x, self.y, self.z = x, y, z end
function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V3) end
-- Fake AI line: the angle around a centre point of the test track, as 0..1.
CENTRE_X, CENTRE_Z = 0, 0

local sim = { isReplayActive = true, replayCurrentFrame = 1000, replayFrames = 7107, replayFrameMs = 30,
  replayPlaybackRate = 1, carsCount = 6, focusedCar = 2, trackLengthM = 2500 }
local cars = {}
for i = 0, 5 do
  cars[i] = { index = i, splinePosition = (0.95 - i * 0.01) % 1, lapCount = 0, speedKmh = 150, isActive = true,
    isInPitlane = false, bestLapTimeMs = 0, previousLapTimeMs = 0, distanceDrivenSessionKm = 0 }
end
local names = { [0] = 'Akiruo', 'Maxim Shaymiev', 'Bernt Grøndal', 'Jonathan Olson', 'Renaud Kuppens - Bas Leinders', 'Other' }
local calls = {}
ac = {
  getSim = function() return sim end,
  getCar = function(i) return cars[i] end,
  getDriverName = function(i) return names[i] end,
  focusCar = function(i) calls[#calls + 1] = 'focus ' .. i; sim.focusedCar = i end,
  setReplayPosition = function(f, c) calls[#calls + 1] = 'jump ' .. f; sim.replayCurrentFrame = f end,
  hasTrackSpline = function() return true end,
  worldCoordinateToTrackProgress = function(v)
    return (math.atan2(v.z - CENTRE_Z, v.x - CENTRE_X) / (2 * math.pi)) % 1
  end,
  getCarID = function(i) return 'dw_gillet_vertigo' end,
  getCarSkinID = function(i) return 'skin' .. i end,
  storage = function(layout)
    for k in pairs(layout) do if k:match('^tower') then layout[k] = true end end   -- all tower columns on
    return layout
  end,
  getSession = function(i) return { laps = 15, isTimedRace = false, startTime = 0 } end,
  getDriverNumber = function(i) return i + 1 end,
  isWindowOpen = function(id) return true end,
  setWindowOpen = function(id, open) calls[#calls + 1] = (open and 'open ' or 'close ') .. id end,
  getPatchVersion = function() return '0.2.x' end,
  getPatchVersionCode = function() return 3000 end,
  getReplayFilename = function() return nil end,
  onReplay = function(cb) end,
  getFolder = function(id) return '/fake/' .. tostring(id) end,
  FolderID = { Replays = 'replay', Cfg = 'cfg', ContentCars = 'cars' },
  INIConfig = { load = function(p)
    return { get = function(self, s, k, d) if k == 'FILENAME' then return { replayPath } end return { '1' } end }
  end },
}
io.loadAsync = function(path, cb)
  local fh = io.open(path, 'rb'); local d = fh:read('*a'); fh:close(); cb(nil, d)
end
io.fileExists = function(p) local fh = io.open(p, 'rb'); if fh then fh:close() return true end return false end
io.fileSize = function(p) return 15391155 end
os.preciseClock = os.clock
os.openFileDialog = function() end

local clickRow = nil
local function noop() end
ui = setmetatable({
  getCursor = function() return vec2(10, 20) end,
  measureText = function(t) return vec2(#t * 7, 14) end,
  textLineHeight = function() return 14 end,
  MouseButton = { Right = 1 },
  availableSpaceX = function() return 600 end,
  availableSpaceY = function() return 300 end,
  textLineHeightWithSpacing = function() return 18 end,
  button = function(label) return (label == '+10 s' and STEP == 5) end,
  radioButton = function() return false end,
  invisibleButton = function(id) return id == clickRow end,
  itemHovered = function() return true end,
  slider = function(label, v) return v, false end,
  childWindow = function(id, size, border, fn) fn() end,
  tabBar = function(id, fn) fn() end,
  tabItem = function(label, fn) fn() end,
  StyleColor = { Text = 0 },
}, { __index = function() return noop end })

script = {}
dofile('apps/lua/ACtionFinder/ACtionFinder.lua')

for step = 1, 80 do
  STEP = step
  for i = 0, 5 do
    local c = cars[i]
    c.splinePosition = c.splinePosition + 0.004 - i * 0.0001
    if c.splinePosition >= 1 then c.splinePosition = c.splinePosition - 1 end
    if step > 20 and c.splinePosition < 0.5 then c.lapCount = 1 end   -- lap count comes late
    c.distanceDrivenSessionKm = step * 0.01
  end
  sim.replayCurrentFrame = sim.replayCurrentFrame + 3
  clickRow = step == 10 and '##row4' or nil
  local t = os.clock(); while os.clock() - t < 0.105 do end   -- let the classification update
  sim.isMakingScreenshot = (step == 30 or step == 31)
  script.update(0.1)
  script.windowMain(0.1)
  script.windowTower(0.1)
end
-- print the classification (found through the upvalues of script.update)
local function upvalue(fn, name)
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then return nil end
    if n == name then return v end
  end
end
local cls = upvalue(script.update, 'cls')
for _, r in ipairs(cls.rows) do
  print(string.format('%d %-30s lap %d progress %.3f ahead %s s / %s m leader %s s level %s', r.pos, r.name, r.lap,
    r.progress, tostring(r.aheadS and string.format('%.2f', r.aheadS)), tostring(r.aheadM and string.format('%.1f', r.aheadM)),
    tostring(r.leaderS and string.format('%.2f', r.leaderS)), r.level and 'yes' or 'no'))
end

print('calls: ' .. table.concat(calls, ', '))
local lapData = upvalue(upvalue(script.update, 'runLapJob'), 'lapData')
print('lap data: ' .. lapData.state .. ' ' .. tostring(lapData.message) .. string.format(' %.0f%%', lapData.percent))
if lapData.state == 'ready' then
  for i = 0, 5 do
    local p = lapData.progress[i]
    print(string.format('car %d progress at 0:30 %.3f, 2:00 %.3f, end %.3f', i, p[333], p[1333], p[lapData.count - 1]))
  end
end

