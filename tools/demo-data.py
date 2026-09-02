#!/usr/bin/env python3
# Writes a synthetic ~45-day history for the currently resolved plugins into a
# state directory, ending at each plugin's real current totals. Dev/preview only.

import json
import math
import os
import random
import sys

DAY = 86400
H = 3600


def main():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    d = os.path.join(base, "kairos.plugin-analytics")
    resolved = json.load(open(os.path.join(d, "resolved.json")))
    summary = json.load(open(os.path.join(d, "summary.json")))
    totals = {p["id"]: p["totals"] for p in summary["plugins"]}
    now = summary["asOf"]
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 45
    random.seed(7)
    start = now - days * DAY
    ids = [p["id"] for p in resolved["plugins"]]

    # Hourly increments drawn from a diurnal, slowly growing rate, then rescaled so
    # every plugin lands exactly on its real current totals. Monotonic by construction.
    hours = list(range(int(start), int(now) + 1, H))
    per = {}
    for i, pid in enumerate(ids):
        t = totals.get(pid, {})
        end_v = max(1, int(t.get("views") or 50))
        end_c = max(0, int(t.get("copies") or end_v // 6))
        end_h = max(0, int(t.get("hearts") or 0))
        launch = random.uniform(0.05, 0.45)
        peak = random.uniform(0.6, 1.2)
        incs = []
        for ht in hours:
            frac = (ht - start) / float(now - start)
            x = max(0.0, (frac - launch) / (1 - launch))
            growth = 0.0 if x <= 0 else (0.35 + 0.65 * x) * (1.8 if x < 0.12 else 1.0)
            hod = (ht // H) % 24
            diurnal = 1 + 0.55 * math.sin((hod - 9) / 24.0 * 2 * math.pi)
            lam = max(0.0, growth * diurnal * peak)
            incs.append(max(0, int(round(random.expovariate(1.0 / lam) if lam > 0 else 0))))
        total_inc = sum(incs) or 1
        scale = end_v / float(total_inc)
        views, acc, carry = [], 0, 0.0
        for inc in incs:
            carry += inc * scale
            step = int(carry)
            carry -= step
            acc += step
            views.append(acc)
        views[-1] = end_v
        p_c = end_c / float(end_v)
        copies, hearts = [], []
        cc = hh = 0
        for k, v in enumerate(views):
            dv = v - (views[k - 1] if k else 0)
            cc += sum(1 for _ in range(dv) if random.random() < p_c)
            hh += sum(1 for _ in range(dv) if random.random() < (end_h / float(end_v)))
            copies.append(min(cc, end_c))
            hearts.append(min(hh, end_h))
        copies[-1], hearts[-1] = end_c, end_h
        per[pid] = (views, copies, hearts, end_v, int(t.get("rank") or 1000))

    rows = []
    for k, ht in enumerate(hours):
        hod = (ht // H) % 24
        dow = (ht // DAY) % 7
        skip = (dow == 3 and 1 <= hod <= 6) or (days * 0.55 * DAY < (ht - start) < days * 0.55 * DAY + 2 * DAY)
        if skip and k != len(hours) - 1:
            continue
        p = {}
        for pid in ids:
            views, copies, hearts, end_v, end_rank = per[pid]
            v = views[k]
            rank = int(end_rank + (2200 - end_rank) * (1 - v / float(end_v)) ** 0.7)
            p[pid] = [v, copies[k], hearts[k], max(1, rank)]
        rows.append({"v": 1, "t": int(ht), "nr": 2200, "p": p})
    with open(os.path.join(d, "hourly.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
    # Drop any earlier rollup so the rebuild is from scratch.
    for name in ("daily.jsonl",):
        try:
            os.unlink(os.path.join(d, name))
        except OSError:
            pass
    meta = json.load(open(os.path.join(d, "meta.json")))
    meta.pop("seam", None)
    json.dump(meta, open(os.path.join(d, "meta.json"), "w"))
    print("wrote %d synthetic hourly rows for %d plugins into %s" % (len(rows), len(ids), d))


if __name__ == "__main__":
    main()
