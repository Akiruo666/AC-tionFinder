# AC-tionFinder

In-game app for Assetto Corsa (Custom Shaders Patch, Lua) for watching replays:

- a **live classification** of every car with the time gap (and metres/feet) to the car ahead and to the leader, coloured yellow / orange / red when cars are close;
- after the replay has been analysed, the **overtakes** and **battles** of the replay, with a click to jump to that moment and follow the right car, and *Best moment* / *Next red* buttons for screenshots.

It is the in-game successor of the Windows program [AC Overtake Finder](https://github.com/Akiruo666/OvertakeFinder), without the replay cutting, track map and charts.

Status: **proof of concept** (version 0.1). The design and the algorithms are described in [docs/SPEC.md](docs/SPEC.md).

## Install

Copy the folder `apps/lua/ACtionFinder` of this repository to `assettocorsa/apps/lua/ACtionFinder`
(the `apps` folder of this repository goes into the Assetto Corsa root folder). Start a replay and
open *AC-tionFinder* from the app bar on the right.

## What the proof of concept does

- **Classification**, in replays and live (the status line says which: replay, or the live
  session type). Two views:
  - *On track* (default): every car at the current moment, ordered by lap + spline position, with
    the estimated gap to the car ahead (time and metres/feet) and to the leader, rows coloured by
    the gap to the car ahead;
  - *Lap times*: ordered by best lap, like the practice and qualifying classification.

  Click a row (for example the name) to follow that car. The lap count is reset on a new
  session, a car teleport (back to the pits) and a driver connecting or disconnecting.
- **Tower** (separate window *AC-tionFinder Tower* in the app bar): a minimal classification like
  on TV: position, the skin's livery icon, the name (full name or initials, right click to switch)
  and the gap to the car ahead, coloured when cars are close. Click a row to follow that car. It
  hides itself while CSP makes a screenshot (photo mode).
- **Jump test**: jumps in the replay with `ac.setReplayPosition` (buttons, slider) and keeps
  following the same car, or jumps back 10 s and follows another car. It shows whether the jump worked.
- **Replay file**: finds the replay that plays (`ac.getReplayFilename()`, else `cfg/race.ini`),
  reads it (speed test) and lists its cars, with a check that car N in the file is car N in the game.
- **CSP check**: which CSP functions and fields this CSP version has. Send a screenshot of this
  tab when something does not work.

## Tests outside the game

```bash
luajit tests/test_replayfile.lua <file.acreplay>
python3 tests/compare_python.py <OvertakeFinder checkout> <file.acreplay>
luajit tests/smoke_app.lua <file.acreplay>
luajit tests/live_sessions.lua
luajit tests/test_names.lua
```

The first two print the same car list (Lua reader against the Python reader of AC Overtake
Finder). The smoke test runs the app with fake game functions to catch Lua errors; it does not
show what the game really does. `live_sessions.lua` plays qualifying followed by a race with fake
cars (lap counts reset to 0, grid, a late lap count, a teleport) and checks order and laps.
