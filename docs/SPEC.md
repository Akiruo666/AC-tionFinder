# AC-tionFinder – handover specification

An in-game app for Assetto Corsa (Custom Shaders Patch Lua app) that, while a
replay plays, shows a live classification with time gaps and finds the
overtakes and battles of the replay so you can jump to them.

It is the in-game successor of the Windows program **AC Overtake Finder**
(repository `Akiruo666/OvertakeFinder`, Python/Tkinter). Everything below was
worked out and tested there; this document is what a new session needs to
rebuild it in Lua without reading that whole conversation. The Python files
named here are the reference implementation: read them when a detail is
unclear.

---

## 1. Goal and scope

**In the app**
1. **Live classification** of every car at the current replay moment (all cars,
   not only the followed one).
2. **Overtakes list** and **battles list** after the replay has been analysed,
   with a click that jumps to that moment and focuses the right car.
3. **Best moment / previous red / next red** buttons for screenshots.
4. Settings for the battle detection (same defaults as below).

**Not in the app** (stays in the Windows program, or is dropped)
- Cutting/saving a new replay, the camera plan file.
- Track map and charts.
- Reading the track's 3D model (`.kn5`) for off-track / pit lane checks: too
  heavy in Lua; the tyre-dirt fallback is used instead (see 6.4).

**User preferences learned so far**
- The user (Dutch speaking) uses it for replays and screenshots: close cars,
  side by side moments and overtakes make the best material.
- Gaps are shown in **time**, with metres or feet next to it (unit switch).
- Colours: yellow / orange / red for close gaps, rows coloured by the gap to
  the car ahead.
- Long details belong in collapsed sections (closed at start).

---

## 2. Recommended order of work

1. **Proof of concept**
   - find and read the replay that is playing (section 3);
   - live classification from the game's own car data (section 5.1), no analysis yet;
   - test whether CSP can **jump in a replay** (set the replay frame/time) and
     **focus a car** (`ac.focusCar`, already used by the old app). Find the
     exact API in the CSP Lua SDK (`lua/ac_common.lua` / `ac_*.lua` definitions
     shipped with CSP, or the CSP wiki) and note the minimum CSP version.
2. **Replay reader in Lua** (section 4), spread over frames, with progress.
3. **Gap measurement** (section 6) → exact live gaps for the classification.
4. **Overtakes** (section 7) and **battles** (section 8) with their lists.
5. Settings, sorting, filters, polish.

Measure the reading speed early: online race replays are 50–100 MB, 30 cars,
~55,000 frames (27 minutes).

---

## 3. Finding the replay that plays

Taken from the existing app `lua_app/OvertakeFocus/OvertakeFocus.lua` in the
OvertakeFinder repository (works today):

- Replay folder: `ac.getFolder(ac.FolderID.Replays)`.
- The replay that is playing: `cfg/race.ini` (`ac.getFolder(ac.FolderID.Cfg) .. '/race.ini'`),
  section `[REPLAY]`, key `FILENAME`, only when `ACTIVE` is not `0`. FILENAME can
  be a bare name, a path relative to the replay folder (e.g. `temp\name.acreplay`)
  or a full path.
- Replay active: `ac.getSim().isReplayActive`.
- Replay time: `sim.replayCurrentFrame * sim.replayFrameMs / 1000`, or
  `sim.replayCurrentTime` on other CSP versions (read the fields with a pcall,
  they differ between versions).
- Files are read with `io.load(path)` (whole file as a Lua string).

The game does not tell the app the replay's file name in any other way, so
race.ini is the source. Content Manager may rename files; fall back to letting
the user pick a file (`os.openFileDialog` was used in the old app).

---

## 4. The .acreplay format (version 16)

Reference: `acreplay.py`. Community source: abchouhan/acreplay-parser. Little
endian; a *string* is `uint32 length` + UTF-8 bytes.

```
uint32  version                         (16 in all files seen)
float64 recording interval in ms        (30.0 so far → 33.3 frames/s)
str     weather, track, track layout
uint32  num_cars, recording_index, num_frames, num_track_objects
byte[(4 + 12 * num_track_objects) * num_frames]      sun / track object data (skip)
per car:
  str    car model, driver, nation, team, skin
  uint32 frame_count, num_wings
  byte[20]
  frame_count frames; frame stride = 256 + 20 + 4 * num_wings bytes
         (the very last frame has no 20-byte gap)
  uint32 lap_count, then lap_count × (uint32 lap_time_ms, uint32 flag)
trailer (CSP data, ignore)
```

The frame size depends on `num_wings` per car and the header on
`num_track_objects`, so nothing is a fixed size: walk the file.

**Offsets inside the 256-byte car frame**

| Offset | Type | Meaning |
|---|---|---|
| 0 | 3 × float32 | position x, y (up), z in metres |
| 164 | 3 × float16 | velocity m/s (speed = 3.6·√(x²+y²+z²) km/h; ignore NaN / > 1500) |
| 170 | float16 | rpm |
| 212 | float16 | steer (deg) |
| 220 | uint32 | time in the current lap (ms) |
| 224 | uint32 | last lap (ms) |
| 228 | uint32 | best lap (ms) |
| 234 | uint8 | gear (0 = R, 1 = N, 2 = 1st) |
| 235 | 4 × uint8 | tyre dirt per wheel (> 0 on all four = all wheels off the tarmac) |
| 244 | uint8 | gas |
| 245 | uint8 | brake |
| 246 | uint8 | lap number, 0 = first lap |

In Lua (LuaJIT): read the file once with `io.load`, then use `ffi.cast` on the
string's bytes (`ffi.cast('const uint8_t*', s)`) and read floats/ints through
`ffi.cast('const float*', ptr + offset)` etc. Float16 needs a small decoder.
Only keep what is needed per car: positions (x, y, z), speed, lap index, lap
timer, brake, min tyre dirt. Store in flat FFI arrays (`ffi.new('float[?]', n)`),
not Lua tables of tables, to keep memory and GC low.

**Pitfalls seen in real files**
- **Cars without data.** Online replays list cars whose every position is
  (0,0,0); treat them as "no position data" and leave them out.
- **Unusable lap fields.** Network cars have a lap field that stays 0 and an
  empty lap timer, so their lap is unknown (show `-`). If the lap number never
  changes but the lap timer restarts (jumps back > 1 s), count laps from the
  timer (`_usable_laps`).
- **Per-car frame count.** `frame_count` differs per car; the replay length is
  the smallest one.
- **Teleports.** Jumps > 15 m between two frames (pit reset, glitch) are not
  counted as driving distance.

---

## 5. Live classification

### 5.1 Before the analysis is done (estimate)
Order cars by distance along the lap. CSP gives per car a spline position
(normalised 0–1 progress along the AI line, `car.splinePosition`) and lap
count. Progress = laps + spline; the gap in metres ≈ Δprogress × track length,
and the time gap ≈ metres / speed of the car behind (rough in corners; mark it
as an estimate).

### 5.2 After the analysis (exact)
Use the measured time gaps (section 6) at the current replay frame.

### 5.3 Columns
Position, driver, lap, **gap to the car ahead** (time, coloured), gap to the
car ahead in m/ft, **gap to the leader** in time, speed.

- **Time gap to the leader** = how long ago the leader was at this car's spot;
  the same method as 6.1, but searching the leader's history (the pair search
  only covers cars within a few hundred metres, so do this one separately).
- **Lapped car**: show `+1 lap` (`+N laps`).
- A click on a row focuses that car.

### 5.4 Colours
Shared by the classification rows and the lists:

| Gap | Level | Strong colour | Light (row background) |
|---|---|---|---|
| side by side, or < 0.2 s | red | `#e53935` | `#ffcdd2` |
| < 0.5 s | orange | `#fb8c00` | `#ffe0b2` |
| ≤ close_s (1.0 s) | yellow | `#fdd835` | `#fff9c4` |
| ≤ battle_s (2.0 s) | grey (still in battle) | `#9e9e9e` | `#eeeeee` |
| above | none | | |

Yellow goes up to the *close* setting, so colours and battle detection agree.

---

## 6. Measuring the gap between two cars

Reference: `battles.py` (`_pair_series`, `_match`, `_refine`, `_lead_changes`).
This is the core; it is accurate with and without a racing line.

### 6.1 Time gap
The gap is measured the way race timing does it: **how long ago the car in
front was at the spot where the car behind is now**.

For a pair (a, b) at frame f:
1. Search car a's own recorded path for the point nearest to b's position at f
   (3D distance) → frame t (with sub-frame precision: project b onto the
   segments t-1..t and t..t+1).
2. `gap = (f - t) * interval`. Positive: a is ahead. Negative: b is ahead
   (a gets there later). This works without knowing who is in front.
3. `along` = distance driven by a between t and f (metres along the road, from
   a's cumulative driven distance) → the gap in metres.
4. `lateral` = distance from b to a's path; if it is > 12 m the match is not
   valid (other route, pit lane next to the track) → gap unknown.
5. **Side by side** = |along| < 4 m (the car centres overlap).

**Making it fast**
- Sample every 3rd frame (90 ms).
- **Rough distance first.** Skip pairs further apart than 250 m along the lap
  (450 m without a racing line, because the estimate drifts). Use the skip to
  jump ahead: two cars close in at most ~60 m/s, so skip
  `(|e| - 250) / (60 · 0.09)` samples.
- **First search.** Guess t from progress (binary search on a running maximum
  of a's progress for b's progress), then search ±50 frames (±130 without a
  racing line).
- **Following searches.** Once matched, the next search starts at
  `t + 3` ± 8 frames; if the minimum lies on the edge, widen to ±32 once.
- A match on frame 0 or the last frame is invalid (a was never / not yet there).
- No gap when either car is slower than 15 km/h (stopped, pit stop) or in the
  pit lane.

Store per pair and sample: gap (or nil), side (bool), lap difference q, along.
For 30 cars that is 435 pairs × ~18,000 samples: use FFI arrays, and run the
work in slices per frame (coroutine) with a progress percentage.

### 6.2 Progress along the lap (to find candidates and laps)
With a racing line: the AI line `content/tracks/<track>/[<layout>/]ai/fast_lane.ai`.

```
int32 version (7), int32 point_count, int32, int32
point_count × (float32 x, y, z, distance, int32 index)      20 bytes each
point_count × 18 float32 "details" (index 6/7 = distance to left/right edge)
```

Project every car frame on the line (`trackdata.track_car`): search near the
previous index, refine on the two segments, unwrap over laps (a car within
250 m behind the line at the start is on the grid → negative progress). Reject
a line where less than 60 % of the moving samples lie within 30 m of it (other
layout). The lap difference of a pair is `q = round(Δprogress / lap length)`.

CSP may offer a cheaper way (`ac.worldCoordinateToTrackProgress` or similar):
check the SDK; if it exists for arbitrary points, use it.

Without a racing line: progress = distance driven + grid offset (less exact;
lapped battles are then not detected).

### 6.3 Lead changes
From `along` with a dead band: a car leads once it is 3 m in front; the lead
change is placed at the last zero crossing before that. Unknown samples reset
the state. This is more reliable than progress-based overtakes without a
racing line (see 7).

### 6.4 Off track, contact, pit lane (without the .kn5 model)
- **Off track:** all four tyres dirty (min tyre dirt > 0) for ≥ 5 frames within 3 s.
- **Contact:** sudden speed loss within 7 frames (~0.2 s): ≥ 12 km/h without
  brake (brake < 40) or ≥ 30 km/h regardless, from ≥ 40 km/h; one event per
  second.
- **Pit lane:** not known from the file without the model; a pit stop ends a
  battle because the car stops (< 15 km/h). Live, CSP may know
  `car.isInPitlane`; use it for the live view if available.

---

## 7. Overtakes

Reference: `overtakes.py`. Per pair, follow `e = Δprogress - q·L` (q = nearest
lap multiple). An overtake is when e goes from clearly negative to clearly
positive (dead band 3 m), placed at the last zero crossing, only between cars
that were within 60 m. q ≠ 0 → **lapping**. Notes: lapping, overtaker off
track, passed car off track, contact (within ±3 s).

**Known weakness:** without a racing line the progress estimate drifts (a car
on the outside of a hairpin drives more metres) and false overtakes appear. In
the app, prefer the lead changes of 6.3 (they are measured on the road), or
keep an overtake only when a lead change confirms it within 3 s.

---

## 8. Battles

Reference: `battles.py` (`find_battles`, `_pair_battles`, `_phases`,
`_group_runs`, `_summarise`, `_start_end`).

### 8.1 Settings (defaults)

| Setting | Default | Meaning |
|---|---|---|
| close_s | 1.0 s | gap that counts as a real fight |
| battle_s | 2.0 s | the battle goes on while the gap stays within this (pause) |
| max_pause_s | 20 s | longest pause before the battle has ended |
| min_close_s | 5 s | least close time in total |
| min_s | 0 s | smallest gap that counts (0: side by side counts) |
| show_lapping | on | keep battles with a lapped car (marked) |

### 8.2 The start
At the start the whole field is close. The start is its own entry, from the
moment the field moves until **no group of 4 or more cars is within battle_s
of each other** (checked from 5 s after the start), or at the latest until the
**leader finished lap 1** (120 s without lap data). Normal battles are only
searched after it. The user decided against a fixed 30 s limit.

**Show above the list** from when battles are searched and why, e.g.
"Battles are searched from 2:11.6 on. At the start (1:00.8) the field drives
too close together: it stayed together until the leader finished lap 1 at
2:11.6." (or "at 0:48.3 it had broken up …"). Clicking it jumps there.

### 8.3 Battle of two cars (duel)
1. It starts at the first sample with min_s ≤ |gap| ≤ close_s.
2. It goes on while |gap| ≤ battle_s. Samples above close_s are pause; a pause
   longer than max_pause_s ends it.
3. It also ends when the gap goes over battle_s, or is unknown for more than 1 s.
4. It runs from the first to the last close sample, and counts only with
   ≥ min_close_s close time in total.

**Phases:** split into close / pause runs. Pauses shorter than 1.5 s belong to
the close phase around them. Per phase: min/max gap and side-by-side time.

**Numbers per battle**
- close time, red time (gap < 0.2 s or side by side), side-by-side time;
- min and mean gap (over the close samples);
- lead changes (6.3, including ±3 s around the battle);
- best moment (first side by side, else the smallest gap);
- start of every red stretch (for "next red");
- notes: lapping, contact, off track.

**Score** (per minute, so long battles are not on top only for being long):
`(close + 2·red + 3·side) / max(0.5, duration in minutes) + 10 · lead changes`.

### 8.4 Trains (groups of 3+ cars)
In a tight field (online TCR race, 30 cars) everybody is close to somebody;
joining pairs transitively produced one 17-minute "battle". Rules that work:
- A **train** is a stretch where the **same** 3 or more cars are linked by
  running duels (connected components of the duels active at that moment). A
  car joining or leaving starts a new train. It needs ≥ min_close_s.
- Duels stay the basis. A train lists every duel that runs during it.
- A duel that lies ≥ 50 % inside one train is only shown under it; longer
  duels also get their own row (same tick/selection).
- Duels that only partly overlap a train get the note "train with A, B, C +N"
  (each name once); the exact stretches go in the details.
- Selecting a duel inside a train focuses only those two cars.

### 8.5 List
- **Rows:** the start first, then trains and duels together, sorted by score
  (other sorts: time, length, close time). A train opens into its duels, and a
  duel opens into its phases.
- **Columns:** time from–to, length, cars, lap(s), close time, gap min/mean,
  side by side, lead changes, score, notes.
- **Filter** on a driver.
- **Settings changes** re-run only the detection, not the measurement (keep
  the measured gaps).
- **Click** on a row: jump to the start of the battle or phase and focus the
  chaser.
- **Buttons:** "Best moment", "< Previous red" and "Next red >" (the last
  wraps around).
- **Camera in a battle:** follow the chaser of the closest pair. Switch only
  when another car is the chaser for 1 s, and at most every 3 s.

---

## 9. Test results from the Windows program (for comparison)

The small test replay in the OvertakeFinder repository
(`AC_051126-161001_R_dw_gillet_vertigo_td_trackhill_.acreplay`: 6 cars,
3:33, 2 laps, no racing line in the test setup):
- Start 0:14.7–0:33.8 (the field broke up).
- Train Henk Gillis / Renaud Kuppens / Akiruo 0:33.9–0:48.5 with side by side
  at 0:36.0, where Akiruo gets past Renaud and then Henk (0:36.8).
- Renaud Kuppens vs Bernt Grøndal 0:52.4–2:16.9: never closer than 13 m.
  Without a racing line, the progress-based overtakes at 1:27.8 / 1:31.5 are
  false.
- The measured gaps are the same with and without a racing line.

Use it as a regression check for the Lua port: `python battles.py <replay>` in
the OvertakeFinder repository prints the full list.

---

## 10. CSP Lua app basics (from the existing app)

- **Folder:** `assettocorsa/apps/lua/<AppName>/` with `<AppName>.lua` and `manifest.ini`.
- **manifest.ini:** `[ABOUT]` (NAME, AUTHOR, VERSION, DESCRIPTION), `[CORE] LAZY = NONE`,
  `[WINDOW_...]` with ID, NAME, FUNCTION_MAIN, SIZE.
- **UI:** immediate mode (`ui.text`, `ui.button`, tables …), drawn every frame
  in `windowMain`. Keep every frame cheap: do the heavy work in slices
  (`script.update` / coroutines) and only draw from the results.
- **Useful calls:**
  - `ac.getSim()` for the replay state and time;
  - `ac.getCar(i)` for the live car data;
  - `ac.focusCar(i)` to follow a car;
  - `ac.INIConfig.load` to read race.ini;
  - `io.load` and `io.scanDir` to read files;
  - `JSON.parse` for JSON.

  Guard calls that may not exist with `pcall`, and show a clear message with
  the CSP version when something is missing.

---

## 11. CSP API found in the Lua SDK (checked against the user's SDK files)

From `extension/internal/lua-sdk/ac_apps/lib.lua` of the user's CSP install:

| Need | API |
|---|---|
| Jump in the replay | `ac.setReplayPosition(frameIndex, playCounter)`: 0-based frame, `playCounter` 0–1 is the transition between frames |
| Replay state | `sim.isReplayActive`, `sim.replayCurrentFrame` (0-based), `sim.replayFrames`, `sim.replayFrameMs`, `sim.replayPlaybackRate` |
| Replay file | `ac.getReplayFilename()`: full file name when AC was launched in replay mode, else `nil` (then use race.ini, section 3) |
| Replay jumped | `ac.onReplay(function(event) end)` with event `'start'`, `'stop'` or `'jump'` |
| Follow a car | `ac.focusCar(index)`, `sim.focusedCar` |
| Progress along the AI line | `ac.hasTrackSpline()`, `ac.worldCoordinateToTrackProgress(vec3)` (−1 without a spline), `ac.worldCoordinateToTrack(vec3)`, `sim.trackLengthM` |
| Car data | `car.splinePosition`, `car.lapCount`, `car.speedKmh`, `car.isInPitlane`, `car.isActive`, `car.distanceDrivenSessionKm`, `ac.getDriverName(i)` |
| Reading files | `io.loadAsync(path, cb)` (does not block the frame), `io.load`, `io.fileSize`, `io.fileExists` |
| Timing | `os.preciseClock()` |

**Tested in the game by the user (proof of concept 0.1, online TCR replay at Curitiba,
30 cars of which 15 with data, 55,383 frames, 537 MB):**
- `ac.setReplayPosition` jumps, and `ac.focusCar` follows the chosen car after the jump.
- `ac.getReplayFilename()` gives the full path of the replay.
- Reading the whole file with `io.loadAsync` took 176 ms, the car list 1 ms.
- Car N in the file is car N in the game (15 of 15 cars with data had the same driver).
- **`car.lapCount` does not count laps for online cars in a replay** (only the car that
  recorded the replay has laps; the others stay on lap 1). Counting line crossings while the
  replay plays breaks at every jump. So the lap of every car comes from the replay file:
  positions at every 3rd frame → `ac.worldCoordinateToTrackProgress` → unwrapped over the laps
  (`replayfile.unwrapProgress`); live, the lap is `round(fileProgress - splinePosition)` and the
  position within the lap is the game's `splinePosition`.

### 11.1 Live sessions (version 0.3)

Found by the user online: after the switch from qualifying to the race the order was wrong
(they finished 11th and the app showed them 1st or 2nd). Cause: the per-car lap correction was
never cleared live, so the drop of every lap count to 0 at the new session, and teleports to
the pits, left a different error per car. Now:
- every car has its own lap counter: it starts from the game's lap count (−1 on the grid
  behind the line: race not started, or almost no distance driven), counts line crossings
  itself (spline > 0.8 → < 0.2 and back), and live takes the game's count again when they
  differ away from the line (spline 0.1–0.9). In replays the game's count is not used for this.
- it is cleared on `ac.onSessionStart`, a change of `sim.currentSessionIndex` /
  `sim.raceSessionType` (for CSP versions without the event), `ac.onReplay`,
  `ac.onCarJumped(-1, …)`, `ac.onClientConnected` and `ac.onClientDisconnected`.
- two views with a switch, default *On track* (order on the track, gaps in time and distance);
  *Lap times* orders by `car.bestLapTimeMs` (practice / qualifying classification).

### 11.2 Tower (version 0.4)

A second window (`[WINDOW_...] ID = tower`, `FUNCTION_MAIN = windowTower`) with only position,
livery icon, name and the gap to the car ahead (`+0.42`, `+1 LAP`, `PIT`), same data and colours
as the *On track* classification. Decisions with the user:
- the icon is the skin's `content/cars/<car>/skins/<skin>/livery.png`; when that file is missing,
  CSP's `carN::special::livery`;
- names: full name or initials (`src/names.lua`): first letter of every word, particles
  included (*Pieter van den Broek* → `PVDB`), one word → first three letters (`GRI`), only the
  first driver of a shared car, camel case splits (`YoungsterBen` → `YB`); equal initials get a
  number in car index order (`PS`, `PS2`), so a label stays with its car;
- both windows can be open; they are opened from the app bar (no switch button or hotkey);
- not on the photo: while `sim.isMakingScreenshot` the tower draws nothing and is closed with
  `ac.setWindowOpen('tower', false)`, then opened again (window ID to be confirmed in the game);
- never shows "finished" from the lap count alone (the mistake of the old BCast Python app,
  which froze the order once a car's lap count passed the race laps).
