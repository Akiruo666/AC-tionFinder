"""Prints what the Python reader of AC Overtake Finder reads from a replay, in the
layout of tests/test_replayfile.lua.
    python tests/compare_python.py <path to OvertakeFinder checkout> <file.acreplay>
"""
import sys
sys.path.insert(0, sys.argv[1])
import acreplay

r = acreplay.load(sys.argv[2])
print("version %d interval %.3f track %s layout %s weather %s" % (r.version, r.interval_ms, r.track, r.layout, r.weather))
print("cars %d frames %d" % (len(r.cars), min(c.frame_count for c in r.cars)))
for c in r.cars:
    print("%d|%s|%s|%s|frames %d|wings %d|stride %d|laps %d|positions %s" % (
        c.index, c.driver, c.model, c.skin, c.frame_count, c.wings, c.stride, len(c.lap_times_ms),
        "true" if c.has_positions else "false"))
