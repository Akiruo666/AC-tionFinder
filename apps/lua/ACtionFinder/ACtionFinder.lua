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

local sim = ac.getSim()

local okReplayFile, ReplayFile = pcall(require, 'src/replayfile')
if not okReplayFile then ReplayFile = nil end

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
}

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

-- Progress = laps + spline position. The lap count from the game can change a moment
-- before or after the spline position wraps around, and in some replays it never changes
-- (network cars). So the progress is unwrapped per car: a jump of about one lap between
-- two updates is a crossing of the line and adds or removes a lap.
local tracking = {}        -- car index -> { raw = last raw progress, offset = laps added }
local lastTrackFrame = nil

local function resetTracking()
  tracking = {}
  lastTrackFrame = nil
end

if hasFunction(ac, 'onReplay') then
  pcall(ac.onReplay, function(event)
    if event == 'jump' or event == 'start' or event == 'stop' then resetTracking() end
  end)
end

local function carProgress(car, index, lengthM)
  local spline = field(car, 'splinePosition') or 0
  local laps = field(car, 'lapCount') or 0
  local raw = laps + spline
  -- On the grid, cars behind the line have a spline position near 1 before lap 1.
  if laps == 0 and spline > 0.5 and lengthM > 0 then
    local km = field(car, 'distanceDrivenSessionKm')
    if type(km) == 'number' and km * 1000 < spline * lengthM * 0.5 then raw = spline - 1 end
  end
  local t = tracking[index]
  if not t then
    t = { raw = raw, offset = 0 }
    tracking[index] = t
  else
    local d = raw - t.raw
    if d < -0.5 then t.offset = t.offset + 1 elseif d > 0.5 then t.offset = t.offset - 1 end
    t.raw = raw
  end
  return raw + t.offset
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

local cls = { rows = {}, lengthM = 0, updated = -1 }

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
      local row = {
        index = i,
        name = driverName(i),
        progress = carProgress(car, i, lengthM),
        speedKmh = field(car, 'speedKmh') or 0,
        pit = field(car, 'isInPitlane') == true,
        refLapMs = (best > 0 and best) or (prev > 0 and prev) or nil,
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
  if not (name:match('^%a:') or name:match('^[/\\][/\\]')) then path = REPLAY_DIR .. '/' .. name end
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

local function readReplay()
  if not ReplayFile then
    rf.status, rf.statusGood = 'The module src/replayfile.lua could not be loaded: ' .. tostring(select(2,
      pcall(require, 'src/replayfile'))), false
    return
  end
  if not rf.path then
    rf.status, rf.statusGood = 'No replay file found. Use "Open file...".', false
    return
  end
  local path = rf.path
  rf.info, rf.loading = nil, true
  rf.status, rf.statusGood = 'Reading ' .. fileName(path) .. ' ...', nil
  local t0 = clock()
  local function done(err, data)
    rf.loading = false
    local t1 = clock()
    if err or type(data) ~= 'string' then
      rf.status, rf.statusGood = 'Could not read the file: ' .. tostring(err or 'no data'), false
      return
    end
    local info, perr = ReplayFile.readHeader(data)
    local t2 = clock()
    if not info then
      rf.status, rf.statusGood = 'Not a replay this app can read: ' .. tostring(perr), false
    else
      info.sizeMB = #data / 1e6
      info.loadMs = (t1 - t0) * 1000
      info.parseMs = (t2 - t1) * 1000
      rf.info = info
      rf.status, rf.statusGood = string.format('Read %.1f MB in %.0f ms (car list in %.1f ms).', info.sizeMB,
        info.loadMs, info.parseMs), true
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

-------------------------------------------------------------------------------- update

local wasReplay = false

function script.update(dt)
  local replay = replayActive()
  if replay ~= wasReplay then
    wasReplay = replay
    resetTracking()
    if replay and rf.source ~= 'chosen by hand' then findReplay() end
  end
  checkJump()
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
    ui.textColored('No replay is playing. The classification works live too; the tests need a replay.', DIM)
  end
  if notice then
    textWrappedColored(notice, WARN)
    ui.sameLine()
    if ui.button('OK##notice') then notice = nil end
  end
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
  if cls.lengthM <= 0 then
    ui.textColored('This track has no AI line length (sim.trackLengthM): gaps cannot be estimated.', WARN)
  end
  if ui.radioButton('Metres', not settings.feet) then settings.feet = false end
  ui.sameLine()
  if ui.radioButton('Feet', settings.feet) then settings.feet = true end
  ui.sameLine(0, 30)
  ui.textColored('Click a row to follow that car.', DIM)

  local start = ui.getCursor()
  for _, c in ipairs(COLUMNS) do
    ui.setCursor(vec2(start.x + c.x, start.y))
    ui.textColored(c.title, DIM)
  end
  ui.separator()

  ui.childWindow('##classification', vec2(0, ui.availableSpaceY()), false, function()
    local focused = focusedCar()
    local width = ui.availableSpaceX()
    local h = ui.textLineHeightWithSpacing()
    for _, row in ipairs(cls.rows) do
      local p = ui.getCursor()
      local level = row.level
      if level then ui.drawRectFilled(p, vec2(p.x + width, p.y + h), level.light) end
      local cells = rowCells(row)
      local colour = level and DARK_TEXT or WHITE
      for k, c in ipairs(COLUMNS) do
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
    if #cls.rows == 0 then ui.textColored('No cars.', DIM) end
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
    local titles = { '#', 'Driver in file', 'Driver in game', 'Frames', 'Laps', 'Position data' }
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
  ui.textColored('  module src/replayfile.lua: ' .. (ReplayFile and 'loaded' or 'NOT loaded'), ReplayFile and WHITE or WARN)
  ui.text('Sim fields:')
  for _, n in ipairs({ 'isReplayActive', 'replayCurrentFrame', 'replayFrames', 'replayFrameMs', 'replayPlaybackRate',
    'carsCount', 'focusedCar', 'trackLengthM' }) do
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

function script.windowMain(dt)
  statusLine()
  ui.tabBar('##tabs', function()
    ui.tabItem('Classification', drawClassification)
    ui.tabItem('Jump test', drawJumpTest)
    ui.tabItem('Replay file', drawReplayFile)
    ui.tabItem('CSP check', drawCspCheck)
  end)
end
