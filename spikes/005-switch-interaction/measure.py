import subprocess, sys
PROBE = "/Users/mambo/Projects/BatteryPlus/spikes/002-glyph-fidelity/glyph_probe"
LEFT, RIGHT, MIDROW = 38, 110, 53     # switch track inside the captured region (px)

def row(path, y):
    out = subprocess.run([PROBE, path, "--threshold", "0.9", "--row", str(y)],
                         capture_output=True, text=True).stdout
    line = [l for l in out.splitlines() if l.startswith("row")][0]
    v = {}
    for t in line.split(":", 1)[1].split():
        if ":" in t:
            k, val = t.split(":"); v[int(k)] = float(val)
    return v

def knob(path):
    v = row(path, MIDROW)
    if not v: return None
    xs = [x for x in range(LEFT, RIGHT) if x in v]
    if not xs: return None
    hi = max(v[x] for x in xs)
    white = [x for x in xs if v[x] > hi - 0.06]
    if not white: return None
    centre = (min(white) + max(white)) / 2
    return (centre - LEFT) / (RIGHT - LEFT), hi

for path in sys.argv[1:]:
    r = knob(path)
    name = path.split("/")[-1]
    print(f"  {name:>12}: " + (f"knob at {r[0]:.2f} of the track (peak {r[1]:.2f})" if r else "nothing found"))
