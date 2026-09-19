#!/usr/bin/env python3
"""diff_smc.py <before-snapshot> <after-snapshot> [pattern]

Shows which SMC keys changed between two snapshots, ignoring the battery telemetry that drifts on
its own every few seconds (capacity, current, voltage, temperature, adapter state).

This is how the charge-limit *write* question gets answered without guessing: snapshot, change the
limit by any means (Apple's "Charge to Full Now" or the System Settings slider), snapshot again,
diff — the key(s) macOS actually writes are the ones that moved.

`pattern` (optional, case-insensitive) restricts the output, e.g. 'BfSC|BL|CH'.
"""
import re
import sys

# keys that drift on their own: battery/adapter telemetry, temperatures, and the SMC's own counters
NOISE = re.compile(
    r"^(B0(AC|AP|AT|AV|FC|NC|RM|TE|CT|CS|QD|QS|IV|I[0-9]|MS|MT|OC|OS|OV|PS|RC|RI|RS|RV|S[0-9]|SR|SS|TC|TF|TI|UC|DC|FG|FH|FI|FV|HM|BL|CA|CH|CI|CM)"
    r"|B[12]AT|BACC|BAAC|BAST|BTHC|BTHW|BR[0-9A-F]{2}|BT[0-9A-Z]{2}"
    r"|AC-|ADBA|ANWP|AOPb|CH0V|CHBV|CLK[MU]|ID[0-9A-Z]|II[0-9A-Z]|I[PMV][0-9A-Z]{2}"
    r"|MS[A-Z0-9]{2}|P[DPZ][0-9A-Z]{2}|SBA[A-Z0-9]|SMB[0-9]|T[CUHMGSDWZ][0-9A-Z]{2}"
    r"|T[a-z][0-9A-Z]{2}|[TfF][a-zA-Z0-9]{3}|[a-z][a-zA-Z0-9]{3})$"
)

CHARGE_HINT = re.compile(r"BfSC|BL|CH|B0C|BCLM|LIMIT", re.IGNORECASE)


def load(path):
    keys = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                keys[parts[0]] = (parts[1], parts[2])
    return keys


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    before, after = load(sys.argv[1]), load(sys.argv[2])
    only = re.compile(sys.argv[3], re.IGNORECASE) if len(sys.argv) > 3 else None

    changed = [k for k in sorted(set(before) | set(after)) if before.get(k) != after.get(k)]
    interesting = [k for k in changed if not NOISE.match(k)]
    if only:
        interesting = [k for k in interesting if only.search(k)]

    print(f"{len(before)} keys before, {len(after)} after, {len(changed)} changed, "
          f"{len(interesting)} after filtering telemetry")
    if not interesting:
        print("no non-telemetry key changed")
        return 0

    for key in interesting:
        b = before.get(key, ("", "(absent)"))
        a = after.get(key, ("", "(absent)"))
        flag = "   <-- charge-limit candidate" if CHARGE_HINT.search(key) else ""
        print(f"  {key:<6} {b[1]:<14} -> {a[1]:<14}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
