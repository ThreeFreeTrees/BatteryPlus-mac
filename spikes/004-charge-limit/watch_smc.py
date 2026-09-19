#!/usr/bin/env python3
"""watch_smc.py — log SMC key changes live, ignoring drifting battery telemetry.

Catches the moment a Charge Limit change is made in System Settings and names every key macOS
actually writes — including transient ones, which a before/after snapshot can miss.

The loop: full snapshot (~2–3 s at ~3600 IOKit calls), diff against the previous snapshot,
print non-telemetry changes with a timestamp, repeat. Runs for `--seconds N` (default 180).
"""
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBE = HERE / "smc_probe"

NOISE = re.compile(
    r"^(B0(AC|AP|AT|AV|FC|NC|RM|TE|CT|CS|QD|QS|IV|I[0-9]|MS|MT|OC|OS|OV|PS|RC|RI|RS|RV|S[0-9]|SR|SS|TC|TF|TI|UC|DC|FG|FH|FI|FV|HM|BL|CA|CH|CI|CM)"
    r"|B[12]AT|BACC|BAAC|BAST|BTHC|BTHW|BR[0-9A-F]{2}|BT[0-9A-Z]{2}"
    r"|AC-|ADBA|ANWP|AOPb|CH0V|CHBV|CLK[MU]|ID[0-9A-Z]|II[0-9A-Z]|I[PMV][0-9A-Z]{2}"
    r"|MS[A-Z0-9]{2}|P[DPZ][0-9A-Z]{2}|SBA[A-Z0-9]|SMB[0-9]|T[CUHMGSDWZ][0-9A-Z]{2}"
    r"|T[a-z][0-9A-Z]{2}|[TfF][a-zA-Z0-9]{3}|[a-z][a-zA-Z0-9]{3})$"
)


def snapshot():
    out = subprocess.run([str(PROBE), "--snapshot", "/tmp/smc_watch_cur.txt"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    keys = {}
    for line in Path("/tmp/smc_watch_cur.txt").read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            keys[parts[0]] = (parts[1], parts[2])
    return keys


def main():
    seconds = 180
    if "--seconds" in sys.argv:
        i = sys.argv.index("--seconds")
        if i + 1 < len(sys.argv):
            seconds = int(sys.argv[i + 1])

    prev = snapshot()
    if prev is None:
        print("initial snapshot failed", file=sys.stderr)
        return 1
    print(f"watch started — {len(prev)} keys; moving the Charge Limit slider now will be logged here")
    start = time.time()
    seen = set()
    while time.time() - start < seconds:
        time.sleep(1)
        cur = snapshot()
        if cur is None:
            continue
        for key in sorted(set(prev) | set(cur)):
            if key in seen or NOISE.match(key):
                continue
            if prev.get(key) != cur.get(key):
                seen.add(key)
                old = prev.get(key, ("", "(absent)"))
                new = cur.get(key, ("", "(absent)"))
                print(f"{time.strftime('%H:%M:%S')}  {key:<6} {old[1]:<14} -> {new[1]}")
        prev = cur
    return 0


if __name__ == "__main__":
    sys.exit(main())