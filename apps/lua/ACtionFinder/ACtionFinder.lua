-- AC-tionFinder, proof of concept (see docs/SPEC.md, section 2 step 1).
--
-- Tabs:
--  * Classification: every car at the current moment, ordered by lap + spline position,
--    with estimated gaps to the car ahead and to the leader. Click a row to follow that car.
--  * Jump test: tests ac.setReplayPosition (jump in the replay) together with ac.focusCar.
--  * Replay file: finds the replay that plays, reads it and lists its cars (reading speed
--    and whether the car order in the file matches the car order in the game).
--  * CSP check: which CSP functions and fields this CSP version has, and live car fields.
--
-- The gaps here are estimates from the game's own car data (SPEC 5.1). The exact gaps
-- from the replay analysis come in a later step.

local ffi = require('ffi')
local sim = ac.getSim()

local okReplayFile, ReplayFile = pcall(require, 'src/replayfile')
if not okReplayFile then ReplayFile = nil end
local okNames, Names = pcall(require, 'src/names')
if not okNames then Names = nil end

-------------------------------------------------------------------------------- helpers

-- Reads a field without failing when this CSP version does not have it.
local function field(obj, name)
  if obj == nil then return nil end
  local ok, value = pcall(function() return obj[name] end)
  if ok then return value end
  return nil
end

local function hasFunction(tbl, name)
  return type(tbl) == 'table' and type(tbl[name]) == 'function'
end

local function cspVersion()
  local v = hasFunction(ac, 'getPatchVersion') and select(2, pcall(ac.getPatchVersion)) or nil
  local code = hasFunction(ac, 'getPatchVersionCode') and select(2, pcall(ac.getPatchVersionCode)) or nil
  return string.format('CSP %s (build %s)', tostring(v or '?'), tostring(code or '?'))
end

local function clock()
  if hasFunction(os, 'preciseClock') then return os.preciseClock() end
  return os.clock()
end

local function hex(h, alpha)
  local r, g, b = h:match('#(%x%x)(%x%x)(%x%x)')
  return rgbm(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, alpha or 1)
end

local function fileName(path)
  return path and (path:match('([^/\\]+)$') or path) or ''
end

-- 75.3 -> "1:15.3", 8.25 -> "8.3"
local function fmtTime(s)
  if s == nil then return '-' end
  local neg = s < 0
  s = math.abs(s)
  local m = math.floor(s / 60)
  local text = m > 0 and string.format('%d:%04.1f', m, s - m * 60) or string.format('%.1f', s)
  return (neg and '-' or '') .. text
end

-- Gap in seconds: "+0.42", "+12.3", "+1:02.3"
local function fmtGap(s)
  if s == nil then return '-' end
  if s < 10 then return string.format('+%.2f', s) end
  if s < 60 then return string.format('+%.1f', s) end
  return '+' .. fmtTime(s)
end

local function fmtLaps(n)
  return n == 1 and '+1 lap' or string.format('+%d laps', n)
end

-------------------------------------------------------------------------------- settings

local settings = {
  closeS = 1.0,      -- gap that counts as a real fight (yellow up to here)
  battleS = 2.0,     -- still in battle (grey up to here)
  feet = false,      -- distances in feet instead of metres
  view = 'track',    -- 'track': order on the track with gaps; 'times': ordered by best lap
  towerInitials = false,  -- tower: initials instead of full names
  -- tower: header and extra columns (right click on the tower)
  towerHeader = true,
  towerLeaderGap = false,
  towerDistance = false,
  towerLap = false,
  towerLastLap = false,
  towerBestLap = false,
  towerSpeed = false,
  towerNumber = false,
}

local STORED_KEYS = { 'feet', 'towerInitials', 'towerHeader', 'towerLeaderGap', 'towerDistance', 'towerLap',
  'towerLastLap', 'towerBestLap', 'towerSpeed', 'towerNumber' }

-- Settings kept between sessions (Documents\Assetto Corsa\cfg\extension\state\lua).
local stored = nil
do
  local layout = {}
  for _, key in ipairs(STORED_KEYS) do layout[key] = settings[key] end
  local ok, s = pcall(ac.storage, layout)
  if ok and s ~= nil then
    stored = s
    for _, key in ipairs(STORED_KEYS) do
      pcall(function()
        local v = stored[key]
        if type(v) == 'boolean' then settings[key] = v end
      end)
    end
  end
end

local function setSetting(key, value)
  settings[key] = value
  if stored then pcall(function() stored[key] = value end) end
end

local function fmtDist(m)
  if m == nil then return '-' end
  if settings.feet then return string.format('%.0f ft', m * 3.28084) end
  return string.format('%.0f m', m)
end

-------------------------------------------------------------------------------- colours (SPEC 5.4)

local LEVELS = {
  red = { strong = hex('#e53935'), light = hex('#ffcdd2') },
  orange = { strong = hex('#fb8c00'), light = hex('#ffe0b2') },
  yellow = { strong = hex('#fdd835'), light = hex('#fff9c4') },
  grey = { strong = hex('#9e9e9e'), light = hex('#eeeeee') },
}
local DARK_TEXT = rgbm(0.08, 0.08, 0.08, 1)
local WHITE = rgbm(1, 1, 1, 1)
local DIM = rgbm(0.65, 0.65, 0.65, 1)
local WARN = rgbm(1, 0.65, 0.25, 1)
local GOOD = rgbm(0.45, 0.85, 0.45, 1)

local SIDE_BY_SIDE_M = 4

-- Coloured text that wraps at the window edge (for long messages).
local function textWrappedColored(text, colour)
  ui.pushStyleColor(ui.StyleColor.Text, colour)
  ui.textWrapped(text)
  ui.popStyleColor()
end

local function gapLevel(gapS, gapM)
  if gapM ~= nil and math.abs(gapM) < SIDE_BY_SIDE_M then return LEVELS.red end
  if gapS == nil then return nil end
  if gapS < 0.2 then return LEVELS.red end
  if gapS < 0.5 then return LEVELS.orange end
  if gapS <= settings.closeS then return LEVELS.yellow end
  if gapS <= settings.battleS then return LEVELS.grey end
  return nil
end

-------------------------------------------------------------------------------- replay state

local function replayActive()
  return field(sim, 'isReplayActive') and true or false
end

local function frameMs()
  local ms = field(sim, 'replayFrameMs')
  if type(ms) == 'number' and ms > 0 then return ms end
  return nil
end

-- Time in the replay in seconds, or nil when this CSP version does not tell.
local function replayTime()
  local frame, ms = field(sim, 'replayCurrentFrame'), frameMs()
  if type(frame) == 'number' and ms then return frame * ms / 1000 end
  local t = field(sim, 'replayCurrentTime')
  if type(t) == 'number' then return t end
  return nil
end

local function replayDuration()
  local frames, ms = field(sim, 'replayFrames'), frameMs()
  if type(frames) == 'number' and ms then return frames * ms / 1000 end
  return nil
end

local notice = nil   -- last message about something that went wrong, shown on top

-------------------------------------------------------------------------------- focus

local function focusCar(index)
  if not hasFunction(ac, 'focusCar') then
    notice = 'This CSP version has no ac.focusCar, so the app cannot follow a car (' .. cspVersion() .. ').'
    return false
  end
  local ok, err = pcall(ac.focusCar, index)
  if not ok then
    notice = 'ac.focusCar failed: ' .. tostring(err)
    return false
  end
  return true
end

local function focusedCar()
  local f = field(sim, 'focusedCar')
  if type(f) == 'number' and f >= 0 then return f end
  return nil
end

local function driverName(index)
  if hasFunction(ac, 'getDriverName') then
    local ok, name = pcall(ac.getDriverName, index)
    if ok and name and name ~= '' then return name end
  end
  return 'Car ' .. tostring(index + 1)
end

-------------------------------------------------------------------------------- live classification (SPEC 5.1)

-- Progress = laps + spline position. Every car has its own lap counter here:
--  * it starts from the game's lap count (-1 for a car on the grid behind the line);
--  * it counts crossings of the line itself (spline position from > 0.8 to < 0.2, or back),
--    because the game's lap count changes a moment before or after the spline wraps, and
--    in replays it never changes for online cars;
--  * live, it takes the game's lap count again whenever they differ away from the line
--    (after a teleport to the pits, a new session, a counting error);
--  * it is cleared on a new session, a replay start/stop/jump, a car teleport and when a
--    driver connects or disconnects (their car slot is reused).
local tracking = {}        -- car index -> { laps = own lap counter, spline = last spline }
local lastTrackFrame = nil

-- A car that teleports (back to the pits, a reset) lands somewhere else on the lap,
-- often just before the line, and would jump to the top. Until it is out of the pits
-- and driving again, it keeps the progress it had on the track (`pitHold`).
local lastOnTrack = {}     -- car index -> progress at the last update on the track
local pitHold = {}         -- car index -> progress kept while back in the pits
local lastPos = {}         -- car index -> { x, y, z } at the last update
local TELEPORT_M = 80      -- more than this between two updates (0.1 s) is a teleport

local function resetTracking()
  tracking = {}
  lastTrackFrame = nil
  lastOnTrack, pitHold, lastPos = {}, {}, {}
end

local function markTeleport(index)
  if pitHold[index] == nil and lastOnTrack[index] ~= nil then pitHold[index] = lastOnTrack[index] end
end

local function resetCar(index)
  if type(index) == 'number' then tracking[index] = nil end
end

local function carTeleported(index)
  if type(index) ~= 'number' then return end
  markTeleport(index)
  tracking[index] = nil
end

-- Events that make the counted laps invalid. Every call is guarded: older CSP versions
-- may lack some of them (the CSP check tab lists which ones are there).
local events = {}
local function listen(name, ...)
  if not hasFunction(ac, name) then events[name] = false return end
  local ok = pcall(ac[name], ...)
  events[name] = ok
end
listen('onReplay', function(event)
  if event == 'jump' or event == 'start' or event == 'stop' then resetTracking() end
end)
listen('onSessionStart', function() resetTracking() end)
listen('onCarJumped', -1, carTeleported)
local function newDriver(index)
  if type(index) ~= 'number' then return end
  tracking[index], lastOnTrack[index], pitHold[index], lastPos[index] = nil, nil, nil, nil
end
listen('onClientConnected', newDriver)
listen('onClientDisconnected', newDriver)

-- Session change without the event (older CSP): watch the session index and type.
local session = { index = nil, kind = nil, changes = 0 }
local function checkSession()
  local index, kind = field(sim, 'currentSessionIndex'), field(sim, 'raceSessionType')
  if index ~= session.index or kind ~= session.kind then
    if session.index ~= nil or session.kind ~= nil then session.changes = session.changes + 1 end
    session.index, session.kind = index, kind
    resetTracking()
  end
end

local SESSION_NAMES = { [0] = 'Session', 'Practice', 'Qualifying', 'Race', 'Hotlap', 'Time attack', 'Drift', 'Drag' }
local function isRaceSession()
  return session.kind == 3
end
local function sessionName()
  return SESSION_NAMES[session.kind or 0] or 'Session'
end

-- Laps from the replay file (filled by the lap job further down): per car the progress
-- over the race (laps + fraction along the AI line) at every `step`-th frame. With it,
-- the lap of every car is known right after a jump, also for online cars whose lap count
-- is not in the replay.
local lapData = { state = 'none', percent = 0, message = nil, step = 3, count = 0, progress = {} }

-- Race progress of a car at the current replay frame from the replay file, or nil.
local function fileProgress(index)
  if lapData.state ~= 'ready' or not replayActive() then return nil end
  local prog = lapData.progress[index]
  local frame = field(sim, 'replayCurrentFrame')
  if not prog or type(frame) ~= 'number' or lapData.count < 2 then return nil end
  local k = frame / lapData.step
  local k0 = math.max(0, math.min(lapData.count - 2, math.floor(k)))
  local w = math.max(0, math.min(1, k - k0))
  local a, b = prog[k0], prog[k0 + 1]
  if a ~= a then return nil end            -- NaN: the car was not on track yet
  if b ~= b then b = a end
  return a + (b - a) * w
end

local function carProgress(car, index, lengthM)
  local spline = field(car, 'splinePosition') or 0
  local fp = fileProgress(index)
  if fp then
    -- lap from the file, exact position within the lap from the game
    return math.floor(fp - spline + 0.5) + spline
  end
  -- The game's lap count, -1 for a car on the grid behind the line before lap 1.
  local gameLaps = field(car, 'lapCount') or 0
  if gameLaps == 0 and spline > 0.5 then
    if isRaceSession() and field(sim, 'isSessionStarted') == false then
      gameLaps = -1
    elseif lengthM > 0 then
      local km = field(car, 'distanceDrivenSessionKm')
      if type(km) == 'number' and km * 1000 < spline * lengthM * 0.5 then gameLaps = -1 end
    end
  end
  local t = tracking[index]
  if not t then
    t = { laps = gameLaps, spline = spline }
    tracking[index] = t
  else
    if t.spline > 0.8 and spline < 0.2 then t.laps = t.laps + 1
    elseif t.spline < 0.2 and spline > 0.8 then t.laps = t.laps - 1 end
    t.spline = spline
    -- Live the game's count is right away from the line. (In a replay it is not.)
    if not replayActive() and t.laps ~= gameLaps and spline > 0.1 and spline < 0.9 then t.laps = gameLaps end
  end
  return t.laps + spline
end

-- Estimated time for the car behind to cover `dp` laps of progress.
local function estimateSeconds(dp, row, lengthM)
  if lengthM <= 0 then return nil end
  local metres = dp * lengthM
  if metres < 400 or not row.refLapMs then
    if row.speedKmh < 15 then return nil end
    return metres / (row.speedKmh / 3.6)
  end
  return dp * row.refLapMs / 1000
end

local cls = { rows = {}, timeRows = {}, lengthM = 0, updated = -1 }

local function updateClassification()
  local lengthM = field(sim, 'trackLengthM') or 0
  cls.lengthM = lengthM

  -- A jump in the replay that ac.onReplay did not report: start the unwrapping again.
  local frame = field(sim, 'replayCurrentFrame')
  if replayActive() and type(frame) == 'number' then
    if lastTrackFrame and math.abs(frame - lastTrackFrame) > 150 then resetTracking() end
    lastTrackFrame = frame
  end

  local rows = {}
  local count = field(sim, 'carsCount') or 0
  for i = 0, count - 1 do
    local ok, car = pcall(ac.getCar, i)
    if ok and car and field(car, 'isActive') ~= false then
      local best = field(car, 'bestLapTimeMs') or 0
      local prev = field(car, 'previousLapTimeMs') or 0
      local progress = carProgress(car, i, lengthM)
      local speedKmh = field(car, 'speedKmh') or 0
      local pitField = field(car, 'isInPitlane')
      local inPit = pitField == true or field(car, 'isInPit') == true

      -- teleport seen from the position (also in replays, where the event may not come)
      local pos = field(car, 'position')
      if pos then
        local lp = lastPos[i]
        if lp then
          local dx, dy, dz = pos.x - lp.x, pos.y - lp.y, pos.z - lp.z
          if dx * dx + dy * dy + dz * dz > TELEPORT_M * TELEPORT_M then markTeleport(i) end
        end
        lastPos[i] = { x = pos.x, y = pos.y, z = pos.z }
      end
      -- keep the progress from before the teleport until the car is out of the pits
      local hold = pitHold[i]
      if hold ~= nil and not inPit and speedKmh > 30 then
        pitHold[i], hold = nil, nil
      end
      if hold ~= nil and progress > hold then progress = hold end
      if hold == nil and not inPit then lastOnTrack[i] = progress end

      local row = {
        index = i,
        name = driverName(i),
        progress = progress,
        speedKmh = speedKmh,
        pit = inPit or hold ~= nil,
        refLapMs = (best > 0 and best) or (prev > 0 and prev) or nil,
        bestMs = best > 0 and best or nil,
        lastMs = prev > 0 and prev or nil,
        lapCount = field(car, 'lapCount') or 0,
      }
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    if a.progress ~= b.progress then return a.progress > b.progress end
    return a.index < b.index
  end)

  local leader = rows[1]
  for k, row in ipairs(rows) do
    row.pos = k
    row.lap = math.max(1, math.floor(row.progress) + 1)
    if k > 1 then
      local ahead = rows[k - 1]
      local dp = ahead.progress - row.progress
      if dp >= 1 then
        row.aheadLaps = math.floor(dp)
      else
        row.aheadM = lengthM > 0 and dp * lengthM or nil
        row.aheadS = estimateSeconds(dp, row, lengthM)
      end
      local dl = leader.progress - row.progress
      if dl >= 1 then
        row.leaderLaps = math.floor(dl)
      else
        row.leaderS = estimateSeconds(dl, row, lengthM)
      end
      row.level = (not row.aheadLaps) and gapLevel(row.aheadS, row.aheadM) or nil
    end
  end
  cls.rows = rows

  -- The same cars ordered by best lap (cars without a lap time last).
  local times = {}
  for k, row in ipairs(rows) do times[k] = row end
  table.sort(times, function(a, b)
    if (a.bestMs ~= nil) ~= (b.bestMs ~= nil) then return a.bestMs ~= nil end
    if a.bestMs and a.bestMs ~= b.bestMs then return a.bestMs < b.bestMs end
    return a.pos < b.pos
  end)
  for k, row in ipairs(times) do
    row.timePos = k
    row.bestAheadMs = (k > 1 and row.bestMs and times[k - 1].bestMs) and row.bestMs - times[k - 1].bestMs or nil
    row.bestLeaderMs = (k > 1 and row.bestMs and times[1].bestMs) and row.bestMs - times[1].bestMs or nil
  end
  cls.timeRows = times
end

-------------------------------------------------------------------------------- jump test

local jump = { pending = nil, result = nil, resultGood = nil, lastTarget = nil }

-- Jumps to a replay frame, then follows `carIndex` (if given). The result is checked
-- in script.update: did the replay frame really move there?
local function jumpToFrame(frame, carIndex)
  if not replayActive() then
    jump.result, jump.resultGood = 'No replay is playing.', false
    return false
  end
  if not hasFunction(ac, 'setReplayPosition') then
    jump.result = 'This CSP version has no ac.setReplayPosition: jumping in the replay is not possible ('
      .. cspVersion() .. ').'
    jump.resultGood = false
    return false
  end
  local frames = field(sim, 'replayFrames')
  frame = math.floor(frame + 0.5)
  if type(frames) == 'number' and frames > 0 then frame = math.min(frame, frames - 1) end
  frame = math.max(0, frame)
  local ok, err = pcall(ac.setReplayPosition, frame, 0)
  if not ok then
    jump.result, jump.resultGood = 'ac.setReplayPosition failed: ' .. tostring(err), false
    return false
  end
  resetTracking()
  jump.lastTarget = frame
  jump.pending = { target = frame, from = field(sim, 'replayCurrentFrame'), at = clock(), car = carIndex }
  if carIndex then focusCar(carIndex) end
  return true
end

local function jumpToTime(seconds, carIndex)
  local ms = frameMs()
  if not ms then
    jump.result, jump.resultGood = 'This CSP version does not tell the replay frame length (sim.replayFrameMs).', false
    return false
  end
  return jumpToFrame(seconds * 1000 / ms, carIndex)
end

local function checkJump()
  local p = jump.pending
  if not p then return end
  local now = field(sim, 'replayCurrentFrame')
  local elapsed = clock() - p.at
  local ms = frameMs() or 30
  local rate = math.abs(field(sim, 'replayPlaybackRate') or 1)
  -- while playing, the replay moves on after the jump: allow for that
  local tolerance = 5 + elapsed * 1000 / ms * math.max(rate, 1) * 1.5
  if type(now) == 'number' and math.abs(now - p.target) <= tolerance and elapsed > 0.1 then
    local text = string.format('Jump worked: frame %s -> %d (now %d, %.2f s after the call).',
      tostring(p.from), p.target, now, elapsed)
    if p.car then
      local f = focusedCar()
      if f == p.car then
        text = text .. ' Following ' .. driverName(p.car) .. '.'
      else
        -- the jump may have reset the camera: focus once more
        focusCar(p.car)
        text = text .. string.format(' The followed car was %s after the jump, so %s was focused again.',
          f and driverName(f) or 'none', driverName(p.car))
      end
    end
    jump.result, jump.resultGood, jump.pending = text, true, nil
  elseif elapsed > 1.5 then
    jump.result = string.format('Jump did not move the replay: asked frame %d, the replay is at frame %s '
      .. '(was %s). Try again with the replay paused, and tell which one works.', p.target, tostring(now),
      tostring(p.from))
    jump.resultGood, jump.pending = false, nil
  end
end

-------------------------------------------------------------------------------- replay file test

local REPLAY_DIR = ac.getFolder(ac.FolderID.Replays)
local RACE_INI = ac.getFolder(ac.FolderID.Cfg) .. '/race.ini'

local rf = { path = nil, source = nil, status = nil, statusGood = nil, info = nil, loading = false }

local function fileExists(path)
  if hasFunction(io, 'fileExists') then
    local ok, r = pcall(io.fileExists, path)
    if ok then return r end
  end
  if hasFunction(io, 'exists') then
    local ok, r = pcall(io.exists, path)
    if ok then return r end
  end
  return true   -- cannot tell: try to read it
end

-- FILENAME in race.ini can be a bare name, a path relative to the replay folder
-- (e.g. "temp\name.acreplay") or a full path.
local function resolveReplayPath(name)
  local path = name
  if not (name:match('^%a:') or name:match('^[/\\]')) then path = REPLAY_DIR .. '/' .. name end
  if not fileExists(path) and not path:lower():match('%.acreplay$') and fileExists(path .. '.acreplay') then
    path = path .. '.acreplay'
  end
  return path
end

local function raceIniReplay()
  local ok, ini = pcall(ac.INIConfig.load, RACE_INI)
  if not ok or not ini then return nil end
  local function get(key)
    local v = ini:get('REPLAY', key, '')
    if type(v) == 'table' then v = v[1] end
    return v ~= nil and tostring(v) or ''
  end
  local name = get('FILENAME')
  if name == '' or get('ACTIVE') == '0' then return nil end
  return name
end

local function findReplay()
  if hasFunction(ac, 'getReplayFilename') then
    local ok, name = pcall(ac.getReplayFilename)
    if ok and type(name) == 'string' and name ~= '' then
      rf.path, rf.source = name, 'ac.getReplayFilename()'
      return
    end
  end
  local name = raceIniReplay()
  if name then
    rf.path, rf.source = resolveReplayPath(name), 'race.ini [REPLAY] FILENAME = ' .. name
    return
  end
  rf.path, rf.source = nil, nil
end

-- Lap job: turns the sampled positions of every car into progress along the AI line
-- (ac.worldCoordinateToTrackProgress) and unwraps it over the laps. Runs in slices of a
-- few milliseconds per frame (script.update).
local lapJob = nil
local LAP_JOB_BUDGET_S = 0.004

local function startLapJob(info, positions)
  local frames = field(sim, 'replayFrames')
  if type(frames) == 'number' and frames > 0 and math.abs(frames - info.frames) > 2 then
    lapData.state = 'failed'
    lapData.message = string.format('The replay that plays has %d frames, the file %d: not the same replay, '
      .. 'so the laps from the file are not used.', frames, info.frames)
    return
  end
  if not hasFunction(ac, 'worldCoordinateToTrackProgress') then
    lapData.state, lapData.message = 'failed', 'This CSP version has no ac.worldCoordinateToTrackProgress ('
      .. cspVersion() .. ').'
    return
  end
  if hasFunction(ac, 'hasTrackSpline') and not ac.hasTrackSpline() then
    lapData.state, lapData.message = 'failed', 'This track has no AI line (fast_lane.ai): laps cannot be '
      .. 'taken from the replay file.'
    return
  end
  local lengthM = field(sim, 'trackLengthM') or 0
  local count = positions.count
  lapData.step, lapData.count = positions.step, count
  -- the moment the field starts moving, for the race time in the tower
  local okStart, startSample = pcall(ReplayFile.findStart, positions, positions.step * info.intervalMs / 1000, 15)
  lapData.startFrame = okStart and startSample and startSample * positions.step or nil
  lapData.state, lapData.percent, lapData.progress = 'computing', 0, {}
  local cars = {}
  for index, c in pairs(positions.cars) do cars[#cars + 1] = { index = index, pos = c } end
  table.sort(cars, function(a, b) return a.index < b.index end)

  lapJob = coroutine.create(function()
    local v = vec3()
    local raw = ffi.new('float[?]', count)
    local total = math.max(1, #cars * count)
    local doneSamples = 0
    for _, car in ipairs(cars) do
      local x, y, z = car.pos.x, car.pos.y, car.pos.z
      for k = 0, count - 1 do
        if x[k] == 0 and y[k] == 0 and z[k] == 0 then
          raw[k] = -1
        else
          v:set(x[k], y[k], z[k])
          raw[k] = ac.worldCoordinateToTrackProgress(v)
        end
        if k % 200 == 199 then
          lapData.percent = (doneSamples + k) / total * 100
          if clock() > lapData.deadline then coroutine.yield() end
        end
      end
      doneSamples = doneSamples + count
      local prog = ffi.new('double[?]', count)
      ReplayFile.unwrapProgress(raw, count, prog, nil, lengthM, 250)
      lapData.progress[car.index] = prog
    end
    lapData.percent = 100
    lapData.state = 'ready'
    lapData.message = string.format('Laps from the replay file (%d cars).', #cars)
  end)
end

local function runLapJob()
  if not lapJob then return end
  lapData.deadline = clock() + LAP_JOB_BUDGET_S
  local ok, err = coroutine.resume(lapJob)
  if not ok then
    lapData.state, lapData.message = 'failed', 'Computing the laps failed: ' .. tostring(err)
    lapJob = nil
  elseif coroutine.status(lapJob) == 'dead' then
    lapJob = nil
  end
end

local function readReplay()
  if not ReplayFile then
    rf.status, rf.statusGood = 'The module src/replayfile.lua could not be loaded: ' .. tostring(select(2,
      pcall(require, 'src/replayfile'))), false
    return
  end
  if not rf.path then
    rf.status, rf.statusGood = 'No replay file found. Use "Open file...".', false
    lapData.state, lapData.message = 'failed', 'The replay file was not found (Replay file tab: "Open file...").'
    return
  end
  local path = rf.path
  rf.info, rf.loading = nil, true
  lapData.state, lapData.percent, lapData.message, lapData.progress, lapData.startFrame = 'reading', 0, nil, {}, nil
  rf.status, rf.statusGood = 'Reading ' .. fileName(path) .. ' ...', nil
  local t0 = clock()
  local function done(err, data)
    rf.loading = false
    local t1 = clock()
    if err or type(data) ~= 'string' then
      rf.status, rf.statusGood = 'Could not read the file: ' .. tostring(err or 'no data'), false
      lapData.state, lapData.message = 'failed', 'The replay file could not be read: ' .. tostring(err or 'no data')
      return
    end
    local info, perr = ReplayFile.readHeader(data)
    local t2 = clock()
    if not info then
      rf.status, rf.statusGood = 'Not a replay this app can read: ' .. tostring(perr), false
      lapData.state, lapData.message = 'failed', 'The replay file could not be read: ' .. tostring(perr)
    else
      info.sizeMB = #data / 1e6
      info.loadMs = (t1 - t0) * 1000
      info.parseMs = (t2 - t1) * 1000
      local ok, positions = pcall(ReplayFile.readPositions, data, info, lapData.step)
      info.positionsMs = (clock() - t2) * 1000
      rf.info = info
      rf.status, rf.statusGood = string.format('Read %.1f MB in %.0f ms (car list in %.1f ms, positions in %.0f ms).',
        info.sizeMB, info.loadMs, info.parseMs, info.positionsMs), true
      if ok then
        startLapJob(info, positions)
      else
        lapData.state, lapData.message = 'failed', 'Reading the positions failed: ' .. tostring(positions)
      end
    end
    data = nil
    collectgarbage()
  end
  if hasFunction(io, 'loadAsync') then
    rf.async = true
    local ok, err = pcall(io.loadAsync, path, done)
    if not ok then done(err, nil) end
  else
    rf.async = false
    local ok, data = pcall(io.load, path)
    done(not ok and data or nil, ok and data or nil)
  end
end

local function openReplayDialog()
  if not hasFunction(os, 'openFileDialog') then
    rf.status, rf.statusGood = 'This CSP version has no os.openFileDialog.', false
    return
  end
  os.openFileDialog({
    title = 'Open replay',
    folder = REPLAY_DIR,
    fileTypes = { { name = 'Replays', mask = '*.acreplay' } },
    addAllFilesFileType = true,
  }, function(err, filename)
    if err then
      rf.status, rf.statusGood = 'Could not open the file dialog: ' .. tostring(err), false
    elseif filename and filename ~= '' then
      rf.path, rf.source = filename, 'chosen by hand'
      rf.info = nil
      readReplay()
    end
  end)
end

-------------------------------------------------------------------------------- tower data

-- Per car: label (full name or initials) and livery icon. Refreshed every 2 s, because
-- online a car slot can get another driver or skin.
local tower = { meta = {}, refreshed = -100, shotHidden = false, windowId = 'tower', windowResult = nil }
local CARS_DIR = ac.getFolder(ac.FolderID.ContentCars) or ''

local function safeCall(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- The skin's livery.png; if that file is not there, CSP's own livery icon of the car.
local function liveryImage(index)
  local carId, skin = safeCall(ac.getCarID, index), safeCall(ac.getCarSkinID, index)
  if type(carId) == 'string' and type(skin) == 'string' and CARS_DIR ~= '' then
    local path = CARS_DIR .. '/' .. carId .. '/skins/' .. skin .. '/livery.png'
    if fileExists(path) then return path, carId .. '/' .. skin end
  end
  return 'car' .. index .. '::special::livery', tostring(carId) .. '/' .. tostring(skin)
end

local function refreshTowerMeta()
  local count = field(sim, 'carsCount') or 0
  local drivers = {}
  for i = 0, count - 1 do drivers[i] = driverName(i) end
  local initials = Names and Names.uniqueInitials(drivers) or {}
  for i = 0, count - 1 do
    local m = tower.meta[i] or {}
    m.name = drivers[i]
    m.initials = initials[i] or drivers[i]
    m.number = safeCall(ac.getDriverNumber, i)
    local key = tostring(safeCall(ac.getCarID, i)) .. '/' .. tostring(safeCall(ac.getCarSkinID, i))
    if m.skinKey ~= key then m.image, m.skinKey = liveryImage(i) end
    tower.meta[i] = m
  end
end

-- The tower hides itself while CSP makes a screenshot (photo mode): the window is
-- closed for the shot and opened again afterwards.
local function hideTowerForScreenshot()
  local shooting = field(sim, 'isMakingScreenshot') == true
  if shooting and not tower.shotHidden then
    if hasFunction(ac, 'isWindowOpen') and hasFunction(ac, 'setWindowOpen') then
      local ok, open = pcall(ac.isWindowOpen, tower.windowId)
      if ok and open then
        local okClose, err = pcall(ac.setWindowOpen, tower.windowId, false)
        tower.windowResult = okClose and 'closed for a screenshot' or ('could not close: ' .. tostring(err))
        tower.shotHidden = okClose
      end
    end
  elseif not shooting and tower.shotHidden then
    pcall(ac.setWindowOpen, tower.windowId, true)
    tower.shotHidden = false
    tower.windowResult = 'opened again after the screenshot'
  end
end

local function updateTower()
  hideTowerForScreenshot()
  local now = clock()
  if now - tower.refreshed >= 2 then
    tower.refreshed = now
    local ok, err = pcall(refreshTowerMeta)
    if not ok then notice = 'Tower: ' .. tostring(err) end
  end
end

-------------------------------------------------------------------------------- update

local wasReplay = false

function script.update(dt)
  checkSession()
  local replay = replayActive()
  if replay ~= wasReplay then
    wasReplay = replay
    resetTracking()
    if replay then
      if rf.source ~= 'chosen by hand' then findReplay() end
      readReplay()                     -- laps from the file (SPEC 4)
    else
      lapJob, lapData.state, lapData.progress = nil, 'none', {}
    end
  end
  runLapJob()
  checkJump()
  updateTower()
  local now = clock()
  if now - cls.updated >= 0.1 then
    cls.updated = now
    local ok, err = pcall(updateClassification)
    if not ok then notice = 'Classification failed: ' .. tostring(err) end
  end
end

-------------------------------------------------------------------------------- UI

local function statusLine()
  if replayActive() then
    local t, d = replayTime(), replayDuration()
    ui.text(string.format('Replay %s / %s   frame %s / %s   speed %sx', fmtTime(t), fmtTime(d),
      tostring(field(sim, 'replayCurrentFrame') or '?'), tostring(field(sim, 'replayFrames') or '?'),
      tostring(field(sim, 'replayPlaybackRate') or '?')))
  else
    local count = field(sim, 'sessionsCount')
    ui.text(string.format('Live: %s%s', sessionName(), (session.index and type(count) == 'number' and count > 0)
      and string.format(' (session %d of %d)', session.index + 1, count) or ''))
  end
  if notice then
    textWrappedColored(notice, WARN)
    ui.sameLine()
    if ui.button('OK##notice') then notice = nil end
  end
end

-- 1:23.456
local function fmtLapTime(ms)
  if not ms then return '-' end
  local s = ms / 1000
  local m = math.floor(s / 60)
  return string.format('%d:%06.3f', m, s - m * 60)
end

local function fmtLapDelta(ms)
  if not ms then return '-' end
  return string.format('+%.3f', ms / 1000)
end

local TIME_COLUMNS = {
  { title = 'Pos', x = 4 },
  { title = 'Driver', x = 40 },
  { title = 'Best lap', x = 250 },
  { title = 'Gap ahead', x = 335 },
  { title = 'To P1', x = 415 },
  { title = 'Last lap', x = 495 },
  { title = 'Laps', x = 580 },
  { title = '', x = 625 },
}

local function timeRowCells(row)
  return {
    tostring(row.timePos),
    row.name,
    fmtLapTime(row.bestMs),
    row.timePos == 1 and (row.bestMs and 'Fastest' or '') or fmtLapDelta(row.bestAheadMs),
    row.timePos == 1 and '' or fmtLapDelta(row.bestLeaderMs),
    fmtLapTime(row.lastMs),
    tostring(row.lapCount),
    row.pit and 'PIT' or '',
  }
end

local COLUMNS = {
  { title = 'Pos', x = 4 },
  { title = 'Driver', x = 40 },
  { title = 'Lap', x = 250 },
  { title = 'Gap ahead', x = 290 },
  { title = 'Distance', x = 370 },
  { title = 'To leader', x = 440 },
  { title = 'Speed', x = 530 },
  { title = '', x = 600 },
}

local function rowCells(row)
  local ahead, dist, leader
  if row.pos == 1 then
    ahead, dist, leader = 'Leader', '', ''
  else
    ahead = row.aheadLaps and fmtLaps(row.aheadLaps) or fmtGap(row.aheadS)
    dist = row.aheadLaps and '' or fmtDist(row.aheadM)
    leader = row.leaderLaps and fmtLaps(row.leaderLaps) or fmtGap(row.leaderS)
  end
  return {
    tostring(row.pos),
    row.name,
    tostring(row.lap),
    ahead,
    dist,
    leader,
    string.format('%.0f km/h', row.speedKmh),
    row.pit and 'PIT' or '',
  }
end

local function drawClassification()
  ui.textColored('Estimated gaps (from the spline position): exact gaps come with the replay analysis.', DIM)
  if replayActive() then
    if lapData.state == 'ready' then
      ui.textColored(lapData.message, DIM)
    elseif lapData.state == 'reading' then
      ui.textColored('Laps: reading the replay file ...', DIM)
    elseif lapData.state == 'computing' then
      ui.textColored(string.format('Laps: reading the replay file ... %.0f %%', lapData.percent), DIM)
    else
      textWrappedColored('Laps from the game: online cars stay on lap 1 in a replay, so the order is wrong. '
        .. (lapData.message or ''), WARN)
    end
  end
  if cls.lengthM <= 0 then
    ui.textColored('This track has no AI line length (sim.trackLengthM): gaps cannot be estimated.', WARN)
  end
  if ui.radioButton('On track', settings.view == 'track') then settings.view = 'track' end
  if ui.itemHovered() then ui.setTooltip('Order on the track now, with the time and distance to the car ahead.') end
  ui.sameLine()
  if ui.radioButton('Lap times', settings.view == 'times') then settings.view = 'times' end
  if ui.itemHovered() then ui.setTooltip('Ordered by best lap, like the classification of practice and qualifying.') end
  local byTimes = settings.view == 'times'
  if not byTimes then
    ui.sameLine(0, 30)
    if ui.radioButton('Metres', not settings.feet) then setSetting('feet', false) end
    ui.sameLine()
    if ui.radioButton('Feet', settings.feet) then setSetting('feet', true) end
  end
  ui.sameLine(0, 30)
  ui.textColored('Tower:', DIM)
  ui.sameLine()
  if ui.radioButton('Names', not settings.towerInitials) then setSetting('towerInitials', false) end
  ui.sameLine()
  if ui.radioButton('Initials', settings.towerInitials) then setSetting('towerInitials', true) end
  ui.textColored('Click a row to follow that car. The tower is a separate window in the app bar.', DIM)
  if byTimes and replayActive() then
    ui.textColored('In replays the game often has no lap times for online cars.', DIM)
  end

  local columns = byTimes and TIME_COLUMNS or COLUMNS
  local rows = byTimes and cls.timeRows or cls.rows
  local cellsOf = byTimes and timeRowCells or rowCells
  local start = ui.getCursor()
  for _, c in ipairs(columns) do
    ui.setCursor(vec2(start.x + c.x, start.y))
    ui.textColored(c.title, DIM)
  end
  ui.separator()

  ui.childWindow('##classification', vec2(0, ui.availableSpaceY()), false, function()
    local focused = focusedCar()
    local width = ui.availableSpaceX()
    local h = ui.textLineHeightWithSpacing()
    for _, row in ipairs(rows) do
      local p = ui.getCursor()
      local level = (not byTimes) and row.level or nil
      if level then ui.drawRectFilled(p, vec2(p.x + width, p.y + h), level.light) end
      local cells = cellsOf(row)
      local colour = level and DARK_TEXT or WHITE
      for k, c in ipairs(columns) do
        ui.setCursor(vec2(p.x + c.x, p.y))
        local text = cells[k]
        if k == 1 and row.index == focused then text = '> ' .. text end
        ui.textColored(text, colour)
      end
      ui.setCursor(p)
      if ui.invisibleButton('##row' .. row.index, vec2(width, h)) then focusCar(row.index) end
      if ui.itemHovered() then
        ui.drawRect(p, vec2(p.x + width, p.y + h), WHITE)
        ui.setTooltip('Follow ' .. row.name)
      end
      if row.index == focused then
        ui.drawRect(p, vec2(p.x + width, p.y + h), level and level.strong or DIM)
      end
    end
    if #rows == 0 then ui.textColored('No cars.', DIM) end
  end)
end

local function drawJumpTest()
  if not replayActive() then
    ui.textColored('Start a replay to test jumping.', DIM)
    return
  end
  if not hasFunction(ac, 'setReplayPosition') then
    ui.textColored('This CSP version has no ac.setReplayPosition: jumping is not possible (' .. cspVersion() .. ').', WARN)
    return
  end
  local t, d = replayTime() or 0, replayDuration() or 0
  local followed = focusedCar()
  ui.text('Jump and keep following the same car' .. (followed and (' (' .. driverName(followed) .. ')') or '') .. ':')
  for _, step in ipairs({ -60, -10, -1, 1, 10, 60 }) do
    if ui.button(string.format('%+d s', step)) then jumpToTime(math.max(0, t + step), followed) end
    ui.sameLine()
  end
  if ui.button('Start') then jumpToFrame(0, followed) end
  ui.sameLine()
  if ui.button('Middle') then jumpToTime(d / 2, followed) end

  ui.text('Drag to jump:')
  ui.setNextItemWidth(ui.availableSpaceX())
  local value, changed = ui.slider('##position', t, 0, math.max(d, 1), fmtTime(t) .. ' / ' .. fmtTime(d))
  if changed then jumpToTime(value, nil) end

  ui.separator()
  ui.text('Jump back 10 s and follow another car (tests jump + focus together):')
  for _, row in ipairs(cls.rows) do
    if row.pos <= 6 then
      if ui.button(row.pos .. '. ' .. row.name .. '##jf' .. row.index) then
        jumpToTime(math.max(0, t - 10), row.index)
      end
      if row.pos % 3 ~= 0 then ui.sameLine() end
    end
  end
  ui.newLine()
  ui.separator()
  if jump.pending then
    ui.textColored('Checking the jump ...', DIM)
  elseif jump.result then
    textWrappedColored(jump.result, jump.resultGood and GOOD or WARN)
  end
end

local function drawReplayFile()
  if rf.source == nil and not rf.loading then findReplay() end
  ui.text('Replay file: ' .. (rf.path and fileName(rf.path) or 'not found'))
  if rf.path then
    ui.textColored('  ' .. rf.path, DIM)
    ui.textColored('  found by: ' .. tostring(rf.source), DIM)
    if hasFunction(io, 'fileSize') then
      local ok, size = pcall(io.fileSize, rf.path)
      if ok and type(size) == 'number' and size >= 0 then ui.textColored(string.format('  size: %.1f MB', size / 1e6), DIM) end
    end
  end
  if ui.button(rf.loading and 'Reading ...' or 'Read file (speed test)') and not rf.loading then readReplay() end
  ui.sameLine()
  if ui.button('Open file...') then openReplayDialog() end
  ui.sameLine()
  if ui.button('Search again') then rf.source = nil; rf.info = nil; findReplay() end
  if rf.status then textWrappedColored(rf.status, rf.statusGood == false and WARN or rf.statusGood and GOOD or DIM) end

  if lapData.message or lapData.state == 'computing' then
    local text = lapData.state == 'computing' and string.format('Laps: %.0f %%', lapData.percent) or lapData.message
    textWrappedColored(text, lapData.state == 'failed' and WARN or lapData.state == 'ready' and GOOD or DIM)
  end
  local info = rf.info
  if not info then return end
  ui.text(string.format('Format %d, %s ms per frame, %d frames (%s), track %s %s, %d cars.', info.version,
    tostring(info.intervalMs), info.frames, fmtTime(info.durationS), info.track, info.layout, info.numCars))
  if info.warning then ui.textColored(info.warning, WARN) end
  local frames = field(sim, 'replayFrames')
  if type(frames) == 'number' and frames > 0 and math.abs(frames - info.frames) > 2 then
    ui.textColored(string.format('The replay that plays has %d frames, this file %d: is it the same replay?',
      frames, info.frames), WARN)
  end

  -- Is car N in the file the same as car N in the game? (needed to focus the right car)
  local same, total = 0, 0
  for _, c in ipairs(info.cars) do
    if c.hasPositions then
      total = total + 1
      if driverName(c.index) == c.driver then same = same + 1 end
    end
  end
  ui.textColored(string.format('Car order: %d of %d cars have the same driver in the file and in the game.', same, total),
    same == total and GOOD or WARN)

  ui.childWindow('##cars', vec2(0, ui.availableSpaceY()), false, function()
    local p = ui.getCursor()
    local cols = { 0, 30, 230, 430, 500, 545 }
    local titles = { '#', 'Driver in file', 'Driver in game', 'Frames', 'Laps in file', 'Position data' }
    for k, x in ipairs(cols) do
      ui.setCursor(vec2(p.x + x, p.y))
      ui.textColored(titles[k], DIM)
    end
    for _, c in ipairs(info.cars) do
      p = ui.getCursor()
      local game = driverName(c.index)
      local cells = { tostring(c.index), c.driver, game, tostring(c.frameCount), tostring(#c.laps),
        c.hasPositions and 'yes' or 'none (left out)' }
      for k, x in ipairs(cols) do
        ui.setCursor(vec2(p.x + x, p.y))
        local colour = WHITE
        if k == 3 and game ~= c.driver then colour = WARN end
        if not c.hasPositions then colour = DIM end
        ui.textColored(cells[k], colour)
      end
    end
  end)
end

local function yesNo(v) return v and 'yes' or 'NO' end

local function drawCspCheck()
  ui.text(cspVersion())
  ui.text('Functions:')
  for _, n in ipairs({ 'setReplayPosition', 'focusCar', 'getReplayFilename', 'onReplay', 'getDriverName',
    'worldCoordinateToTrackProgress', 'hasTrackSpline' }) do
    ui.textColored('  ac.' .. n .. ': ' .. yesNo(hasFunction(ac, n)), hasFunction(ac, n) and WHITE or WARN)
  end
  for _, n in ipairs({ 'loadAsync', 'load', 'fileSize' }) do
    ui.textColored('  io.' .. n .. ': ' .. yesNo(hasFunction(io, n)), hasFunction(io, n) and WHITE or WARN)
  end
  ui.textColored('  os.openFileDialog: ' .. yesNo(hasFunction(os, 'openFileDialog')), WHITE)
  ui.text('Events used for resetting the lap count:')
  for _, n in ipairs({ 'onReplay', 'onSessionStart', 'onCarJumped', 'onClientConnected', 'onClientDisconnected' }) do
    ui.textColored('  ac.' .. n .. ': ' .. yesNo(events[n]), events[n] and WHITE or WARN)
  end
  ui.textColored(string.format('  session changes seen: %d', session.changes), DIM)
  ui.text('Tower:')
  ui.textColored('  module src/names.lua: ' .. (Names and 'loaded' or 'NOT loaded'), Names and WHITE or WARN)
  ui.textColored('  settings kept between sessions (ac.storage): ' .. yesNo(stored ~= nil), stored and WHITE or WARN)
  local okOpen, open = pcall(ac.isWindowOpen, tower.windowId)
  ui.textColored('  ac.isWindowOpen(\'' .. tower.windowId .. '\'): ' .. (okOpen and tostring(open) or 'not available'), DIM)
  ui.textColored('  hide for screenshots: ' .. tostring(tower.windowResult or 'no screenshot yet'), DIM)
  local f = focusedCar()
  if f and tower.meta[f] then ui.textColored('  livery of the followed car: ' .. tostring(tower.meta[f].image), DIM) end
  ui.textColored('  module src/replayfile.lua: ' .. (ReplayFile and 'loaded' or 'NOT loaded'), ReplayFile and WHITE or WARN)
  ui.text('Sim fields:')
  for _, n in ipairs({ 'isReplayActive', 'replayCurrentFrame', 'replayFrames', 'replayFrameMs', 'replayPlaybackRate',
    'carsCount', 'focusedCar', 'trackLengthM', 'currentSessionIndex', 'sessionsCount', 'raceSessionType',
    'isSessionStarted' }) do
    ui.textColored('  sim.' .. n .. ': ' .. tostring(field(sim, n)), DIM)
  end
  local f = focusedCar()
  if f then
    local ok, car = pcall(ac.getCar, f)
    if ok and car then
      ui.text('Followed car (' .. driverName(f) .. '), fields used for the classification:')
      for _, n in ipairs({ 'splinePosition', 'lapCount', 'distanceDrivenSessionKm', 'speedKmh', 'isInPitlane',
        'isActive', 'bestLapTimeMs', 'previousLapTimeMs', 'racePosition' }) do
        ui.textColored('  car.' .. n .. ': ' .. tostring(field(car, n)), DIM)
      end
    end
  end
end

-------------------------------------------------------------------------------- tower window

local TOWER_STRIPE = rgbm(1, 1, 1, 0.04)
local TOWER_HEADER_BG = rgbm(0, 0, 0, 0.45)
local LEADER_BG = hex('#1e88e5')          -- the leader stands out in bright blue

local function fmtLapsUpper(n)
  return n == 1 and '+1 LAP' or string.format('+%d LAPS', n)
end

-- 1:02:03 or 12:34
local function fmtClock(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h, m, sec = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, sec) end
  return string.format('%d:%02d', m, sec)
end

local function towerGap(row)
  if row.pos == 1 then return 'Leader' end
  if row.pit then return 'PIT' end
  if row.aheadLaps then return fmtLapsUpper(row.aheadLaps) end
  return fmtGap(row.aheadS)
end

-- Extra columns, chosen with a right click on the tower (right of the interval).
local TOWER_EXTRAS = {
  { key = 'towerLeaderGap', label = 'Gap to the leader', sample = '+1:02.3', text = function(row)
    if row.pos == 1 then return '' end
    if row.leaderLaps then return fmtLapsUpper(row.leaderLaps) end
    return fmtGap(row.leaderS)
  end },
  { key = 'towerDistance', label = 'Distance to the car ahead', sample = '9999 ft', text = function(row)
    if row.pos == 1 or row.aheadLaps then return '' end
    return fmtDist(row.aheadM)
  end },
  { key = 'towerLap', label = 'Lap', sample = 'L99', text = function(row) return 'L' .. row.lap end },
  { key = 'towerLastLap', label = 'Last lap', sample = '1:23.456', text = function(row) return fmtLapTime(row.lastMs) end },
  { key = 'towerBestLap', label = 'Best lap', sample = '1:23.456', text = function(row) return fmtLapTime(row.bestMs) end },
  { key = 'towerSpeed', label = 'Speed', sample = '999 km/h', text = function(row)
    if settings.feet then return string.format('%.0f mph', row.speedKmh / 1.609344) end
    return string.format('%.0f km/h', row.speedKmh)
  end },
  { key = 'towerNumber', label = 'Car number', sample = '#999', text = function(row, meta)
    return (type(meta.number) == 'number' and meta.number > 0) and ('#' .. meta.number) or ''
  end },
}

-- Header: lap of the leader (of the total when known) and the race time.
local function towerHeader(rows)
  local s = safeCall(ac.getSession, session.index or field(sim, 'currentSessionIndex') or 0)
  local live = not replayActive()
  local timed = live and s ~= nil and field(s, 'isTimedRace') == true
  local left, right
  if live and not isRaceSession() then
    left = sessionName():upper()
  elseif rows[1] then
    local total = (live and s ~= nil and not timed) and (field(s, 'laps') or 0) or 0
    left = total > 0 and string.format('LAP %d/%d', math.min(rows[1].lap, total), total)
      or string.format('LAP %d', rows[1].lap)
  end
  if not live then
    local f, ms = field(sim, 'replayCurrentFrame'), frameMs()
    if lapData.startFrame and type(f) == 'number' and ms then
      local t = (f - lapData.startFrame) * ms / 1000
      right = t < 0 and 'START' or fmtClock(t)
    end
  else
    local remaining = field(sim, 'sessionTimeLeft')
    if (timed or not isRaceSession()) and type(remaining) == 'number' and remaining > 0 then
      right = fmtClock(remaining / 1000) .. ' left'
    else
      local t = field(sim, 'currentSessionTime')
      if type(t) == 'number' and t ~= 0 then
        right = fmtClock(t / 1000)
      elseif s ~= nil then
        local start, now = field(s, 'startTime'), field(sim, 'time')
        if type(start) == 'number' and type(now) == 'number' and start > 0 then right = fmtClock((now - start) / 1000) end
      end
    end
  end
  return left, right
end

local function towerMenu()
  local keep = ui.SelectableFlags and ui.SelectableFlags.DontClosePopups or nil
  ui.textColored('Names', DIM)
  if ui.menuItem('Full names', not settings.towerInitials, keep) then setSetting('towerInitials', false) end
  if ui.menuItem('Initials', settings.towerInitials, keep) then setSetting('towerInitials', true) end
  ui.separator()
  ui.textColored('Show', DIM)
  if ui.menuItem('Lap and race time', settings.towerHeader, keep) then setSetting('towerHeader', not settings.towerHeader) end
  for _, e in ipairs(TOWER_EXTRAS) do
    if ui.menuItem(e.label, settings[e.key], keep) then setSetting(e.key, not settings[e.key]) end
  end
end

function script.windowTower(dt)
  if field(sim, 'isMakingScreenshot') == true then return end   -- not on the photo
  local rows = cls.rows
  local lineH = ui.textLineHeight()
  local h = math.floor(lineH + 8)
  local icon = h - 6
  local width = ui.availableSpaceX()
  local gapW = ui.measureText('+1 LAPS').x + 10
  local focused = focusedCar()

  -- extra columns, right to left from the window edge
  local extras, extrasW = {}, 0
  for _, e in ipairs(TOWER_EXTRAS) do
    if settings[e.key] then
      local w = ui.measureText(e.sample).x + 12
      extras[#extras + 1] = { def = e, w = w }
      extrasW = extrasW + w
    end
  end
  local gapRight = width - extrasW            -- right edge of the interval column

  if settings.towerHeader then
    local p = ui.getCursor()
    ui.drawRectFilled(p, vec2(p.x + width, p.y + h), TOWER_HEADER_BG)
    local left, right = towerHeader(rows)
    local ty = p.y + (h - lineH) / 2
    if left then ui.setCursor(vec2(p.x + 6, ty)); ui.textColored(left, WHITE) end
    if right then ui.setCursor(vec2(p.x + width - ui.measureText(right).x - 6, ty)); ui.textColored(right, WHITE) end
    ui.setCursor(vec2(p.x, p.y + h + 2))
  end

  if #rows == 0 then ui.textColored('No cars.', DIM) end
  for _, row in ipairs(rows) do
    local p = ui.getCursor()
    local level = row.level
    local leader = row.pos == 1
    if leader then
      ui.drawRectFilled(p, vec2(p.x + width, p.y + h), LEADER_BG)
    elseif level then
      ui.drawRectFilled(p, vec2(p.x + width, p.y + h), level.light)
    elseif row.pos % 2 == 0 then
      ui.drawRectFilled(p, vec2(p.x + width, p.y + h), TOWER_STRIPE)
    end
    local colour = (level and not leader) and DARK_TEXT or WHITE
    local ty = p.y + (h - lineH) / 2
    local meta = tower.meta[row.index] or {}

    local posText = tostring(row.pos)
    ui.setCursor(vec2(p.x + 26 - ui.measureText(posText).x, ty))
    ui.textColored(posText, colour)

    local ix = p.x + 32
    if meta.image then
      pcall(ui.drawImage, meta.image, vec2(ix, p.y + 3), vec2(ix + icon, p.y + 3 + icon))
    end

    local nx = ix + icon + 6
    local label = settings.towerInitials and (meta.initials or row.name) or row.name
    ui.pushClipRect(vec2(nx, p.y), vec2(p.x + gapRight - gapW, p.y + h))
    ui.setCursor(vec2(nx, ty))
    ui.textColored(label, colour)
    ui.popClipRect()

    local gap = towerGap(row)
    ui.setCursor(vec2(p.x + gapRight - ui.measureText(gap).x - 6, ty))
    ui.textColored(gap, colour)

    local x = p.x + gapRight
    for _, c in ipairs(extras) do
      local text = c.def.text(row, meta)
      x = x + c.w
      if text ~= '' then
        ui.setCursor(vec2(x - ui.measureText(text).x - 6, ty))
        ui.textColored(text, colour)
      end
    end

    ui.setCursor(p)
    if ui.invisibleButton('##tower' .. row.index, vec2(width, h)) then focusCar(row.index) end
    if ui.itemHovered() then
      ui.drawRect(p, vec2(p.x + width, p.y + h), WHITE)
      ui.setTooltip(row.name .. '\nClick: follow this car. Right click: what the tower shows.')
    end
    if row.index == focused then
      ui.drawRect(p, vec2(p.x + width, p.y + h), (level and not leader) and level.strong or WHITE, 0, nil, 2)
    end
  end

  -- one menu for the whole tower
  if ui.windowHovered() and ui.mouseClicked(ui.MouseButton and ui.MouseButton.Right or 1) then
    ui.openPopup('##towerMenu')
  end
  if ui.beginPopup('##towerMenu') then
    towerMenu()
    ui.endPopup()
  end
end

function script.windowMain(dt)
  statusLine()
  ui.tabBar('##tabs', function()
    ui.tabItem('Classification', drawClassification)
    ui.tabItem('Jump test', drawJumpTest)
    ui.tabItem('Replay file', drawReplayFile)
    ui.tabItem('CSP check', drawCspCheck)
  end)
end
