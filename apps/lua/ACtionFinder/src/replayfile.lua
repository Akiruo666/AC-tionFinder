-- Reader for .acreplay files (format version 16), see docs/SPEC.md section 4.
--
-- This module only uses LuaJIT and its FFI, so it can be tested outside the game:
--   luajit tests/test_replayfile.lua <file.acreplay>
--
-- For now it reads the header and the car list (names, frame counts, laps) and checks
-- whether a car has position data. Reading all frames comes in the next step.

local ffi = require('ffi')

local M = {}

M.CAR_FRAME_SIZE = 256
M.FRAME_GAP = 20
M.SUPPORTED_VERSION = 16

-- Offsets inside the 256-byte car frame.
M.OFF_POSITION = 0      -- 3 x float32, metres (x, y = up, z)
M.OFF_VELOCITY = 164    -- 3 x float16, m/s
M.OFF_LAP_TIME = 220    -- uint32 ms, time in the current lap
M.OFF_TIRE_DIRT = 235   -- 4 x uint8
M.OFF_BRAKE = 245       -- uint8
M.OFF_LAP = 246         -- uint8, 0 = first lap

local u8p = ffi.typeof('const uint8_t*')
local u32p = ffi.typeof('const uint32_t*')
local f32p = ffi.typeof('const float*')
local f64p = ffi.typeof('const double*')

-- Reader over a Lua string. The string must stay referenced while the reader is used
-- (the reader keeps it in `self.data`).
local Reader = {}
Reader.__index = Reader

local function newReader(data)
  return setmetatable({ data = data, ptr = ffi.cast(u8p, data), pos = 0, size = #data }, Reader)
end

function Reader:need(n)
  if self.pos + n > self.size then
    error(string.format('The file ended unexpectedly at offset %d.', self.pos), 0)
  end
end

function Reader:u32()
  self:need(4)
  local v = ffi.cast(u32p, self.ptr + self.pos)[0]
  self.pos = self.pos + 4
  return tonumber(v)
end

function Reader:f64()
  self:need(8)
  local v = ffi.cast(f64p, self.ptr + self.pos)[0]
  self.pos = self.pos + 8
  return tonumber(v)
end

function Reader:skip(n)
  if n < 0 then error(string.format('Negative skip at offset %d.', self.pos), 0) end
  self:need(n)
  self.pos = self.pos + n
end

function Reader:string(maxLen)
  local n = self:u32()
  if n > (maxLen or 512) then
    error(string.format('Implausible string length %d at offset %d.', n, self.pos - 4), 0)
  end
  self:need(n)
  local s = ffi.string(self.ptr + self.pos, n)
  self.pos = self.pos + n
  return s
end

-- True when the car has a position other than (0,0,0) in some of up to `samples`
-- frames spread over the recording (online replays list cars without any data).
local function hasPositions(ptr, base, stride, count, samples)
  local step = math.max(1, math.floor(count / samples))
  for f = 0, count - 1, step do
    local p = ffi.cast(f32p, ptr + base + f * stride + M.OFF_POSITION)
    if p[0] ~= 0 or p[1] ~= 0 or p[2] ~= 0 then return true end
  end
  return false
end

local function parse(data)
  local r = newReader(data)
  local info = {}
  info.version = r:u32()
  info.intervalMs = r:f64()
  if not (info.intervalMs >= 1 and info.intervalMs <= 1000) then
    error(string.format('Recording interval %s ms is not plausible.', tostring(info.intervalMs)), 0)
  end
  info.weather, info.track, info.layout = r:string(), r:string(), r:string()
  info.numCars, info.recordingIndex, info.numFrames, info.numTrackObjects = r:u32(), r:u32(), r:u32(), r:u32()
  if info.numCars < 1 or info.numCars > 256 then
    error(string.format('Car count %d is not plausible.', info.numCars), 0)
  end
  if info.numFrames < 1 or info.numFrames > 5000000 or info.numTrackObjects > 100000 then
    error(string.format('Frame/object count (%d/%d) is not plausible.', info.numFrames, info.numTrackObjects), 0)
  end
  r:skip((4 + 12 * info.numTrackObjects) * info.numFrames)

  info.cars = {}
  local minFrames = nil
  for index = 0, info.numCars - 1 do
    local car = { index = index }
    car.model, car.driver, car.nation, car.team, car.skin = r:string(), r:string(), r:string(), r:string(), r:string()
    car.frameCount = r:u32()
    car.wings = r:u32()
    if car.frameCount < 2 or car.frameCount > 5000000 or car.wings > 64 then
      error(string.format('Car %d: frame count %d / wings %d not plausible.', index, car.frameCount, car.wings), 0)
    end
    r:skip(M.FRAME_GAP)
    car.base = r.pos
    car.stride = M.CAR_FRAME_SIZE + M.FRAME_GAP + 4 * car.wings
    r:skip((car.frameCount - 1) * car.stride + M.CAR_FRAME_SIZE + 4 * car.wings)
    local lapCount = r:u32()
    if lapCount > 1000 then
      error(string.format('Car %d: lap list length %d not plausible.', index, lapCount), 0)
    end
    car.laps = {}
    for k = 1, lapCount do
      car.laps[k] = r:u32()
      r:u32()             -- flag
    end
    car.hasPositions = hasPositions(r.ptr, car.base, car.stride, car.frameCount, 400)
    if not minFrames or car.frameCount < minFrames then minFrames = car.frameCount end
    info.cars[#info.cars + 1] = car
  end
  info.frames = minFrames            -- the replay is as long as its shortest car
  info.durationS = minFrames * info.intervalMs / 1000
  info.trailerBytes = r.size - r.pos
  return info
end

-- Copies the position of every car at every `step`-th frame into FFI float arrays, so
-- the file data (hundreds of MB) can be released afterwards.
-- Returns { step, count = samples per car, cars = { [carIndex] = { x, y, z } or nil } }.
-- Cars without position data get nil. A sample at (0,0,0) means "not on track".
function M.readPositions(data, info, step)
  step = step or 3
  local ptr = ffi.cast(u8p, data)
  local count = math.floor((info.frames - 1) / step) + 1
  local out = { step = step, count = count, cars = {} }
  for _, car in ipairs(info.cars) do
    if car.hasPositions then
      local x, y, z = ffi.new('float[?]', count), ffi.new('float[?]', count), ffi.new('float[?]', count)
      for k = 0, count - 1 do
        local p = ffi.cast(f32p, ptr + car.base + k * step * car.stride + M.OFF_POSITION)
        x[k], y[k], z[k] = p[0], p[1], p[2]
      end
      out.cars[car.index] = { x = x, y = y, z = z }
    end
  end
  return out
end

-- Turns the track progress (0..1 along the AI line, -1 = unknown) of the samples of one
-- car into progress over the whole race: laps + fraction, written into `out` (a double
-- array). Only a real crossing of the line changes the lap: from above 0.8 to below 0.2
-- (or back when reversing). A teleport (to the pits, a reset) jumps elsewhere on the lap
-- and does not count. A car that starts within `gridM` metres before the line is on the grid
-- (progress just below 0). Unknown samples get the last known value; `known` (uint8
-- array, may be nil) gets 1 for known samples.
function M.unwrapProgress(raw, count, out, known, lengthM, gridM)
  local laps, prev = 0, nil
  local gridFraction = (lengthM and lengthM > 0) and (gridM or 250) / lengthM or 0
  local last = 0 / 0
  for k = 0, count - 1 do
    local p = raw[k]
    if p >= 0 then
      if prev == nil then
        if p > 1 - gridFraction then laps = -1 end
      else
        if prev > 0.8 and p < 0.2 then laps = laps + 1
        elseif prev < 0.2 and p > 0.8 then laps = laps - 1 end
      end
      prev = p
      last = laps + p
      if known then known[k] = 1 end
    elseif known then
      known[k] = 0
    end
    out[k] = last
  end
end

-- Sample at which the field starts moving (SPEC 8.2, same rule as battles.py: the first
-- sample where any car drives at least `minKmh`). `sampleS` is the time between two
-- samples. Returns nil when no car ever moves.
function M.findStart(positions, sampleS, minKmh)
  local limit = (minKmh or 15) / 3.6 * sampleS
  limit = limit * limit
  for k = 1, positions.count - 1 do
    for _, c in pairs(positions.cars) do
      local x0, z0 = c.x[k - 1], c.z[k - 1]
      local x1, z1 = c.x[k], c.z[k]
      if (x0 ~= 0 or z0 ~= 0) and (x1 ~= 0 or z1 ~= 0) then
        local dx, dy, dz = x1 - x0, c.y[k] - c.y[k - 1], z1 - z0
        local d = dx * dx + dy * dy + dz * dz
        -- moving, but not a teleport (> 15 m between two samples)
        if d >= limit and d < 225 then return k end
      end
    end
  end
  return nil
end

-- Reads the header and car list of a replay held in a Lua string.
-- Returns info, or nil and an error message.
function M.readHeader(data)
  if type(data) ~= 'string' or #data < 16 then return nil, 'The file is empty or too small.' end
  local ok, result = pcall(parse, data)
  if not ok then return nil, tostring(result) end
  if result.version ~= M.SUPPORTED_VERSION then
    result.warning = string.format('Format version %d has not been tested (only %d has).',
      result.version, M.SUPPORTED_VERSION)
  end
  return result
end

return M
