-- Prints what src/replayfile.lua reads from a replay, in the same layout as
-- tests/compare_python.py, so both outputs can be compared with diff.
--   luajit tests/test_replayfile.lua <file.acreplay>
package.path = 'apps/lua/ACtionFinder/?.lua;' .. package.path
local ReplayFile = require('src/replayfile')

local path = assert(arg[1], 'usage: luajit tests/test_replayfile.lua <file.acreplay>')
local fh = assert(io.open(path, 'rb'))
local t0 = os.clock()
local data = fh:read('*a')
fh:close()
local t1 = os.clock()
local info, err = ReplayFile.readHeader(data)
local t2 = os.clock()
if not info then print('ERROR: ' .. err) os.exit(1) end
print(string.format('version %d interval %.3f track %s layout %s weather %s', info.version, info.intervalMs,
  info.track, info.layout, info.weather))
print(string.format('cars %d frames %d', info.numCars, info.frames))
for _, c in ipairs(info.cars) do
  print(string.format('%d|%s|%s|%s|frames %d|wings %d|stride %d|laps %d|positions %s', c.index, c.driver,
    c.model, c.skin, c.frameCount, c.wings, c.stride, #c.laps, tostring(c.hasPositions)))
end
io.stderr:write(string.format('read %.0f ms, header %.1f ms, %.1f MB\n', (t1 - t0) * 1000, (t2 - t1) * 1000,
  #data / 1e6))
