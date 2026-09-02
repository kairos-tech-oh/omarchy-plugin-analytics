#!/usr/bin/env python3
# Fixture assertions for the counter maths in helper/collect.py.
# Runs offline against a synthetic history in a throwaway state directory.

import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("collect", os.path.join(HERE, "..", "helper", "collect.py"))
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)

H = 3600
D = 86400
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def approx(a, b, eps=1e-6):
    return abs(a - b) <= eps


def row(t, p, nr=2200):
    return {"v": 1, "t": t, "nr": nr, "p": p}


def write_rows(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")


def fresh_state():
    d = tempfile.mkdtemp(prefix="kpa-math-")
    os.environ["XDG_STATE_HOME"] = d
    sd = C.state_dir()
    return d, sd, C.paths(sd)


# ------------------------------------------------------------ integrate()

def test_integrate():
    # 10 hourly points, +5/hour, clean. gross+adj must equal v(b)-v(a).
    obs = [(i * H, 100 + 5 * i) for i in range(10)]
    segs = C.hourly_segments(obs, True)
    r = C.integrate(segs, 2 * H, 8 * H)
    check("clean window: gross+adj == v(b)-v(a)", approx(r["gross"] + r["adj"], 30), str(r))
    check("clean window: coverage == 1", approx(r["coverage"], 1.0))

    # Correction of -5000 on a 200k plugin is an adjustment, not a reset.
    obs = [(0, 200000), (H, 200100), (2 * H, 195100), (3 * H, 195200)]
    segs = C.hourly_segments(obs, True)
    r = C.integrate(segs, 0, 3 * H)
    check("-5000 correction lands in adj", approx(r["adj"], -5000) and not r["resets"], str(r))
    check("-5000 correction: net reconciles", approx(r["net"], 195200 - 200000))

    # Collapse to zero is a reset: contributes 0, listed, and net + jump reconciles.
    obs = [(0, 200000), (H, 200100), (2 * H, 0), (3 * H, 300)]
    segs = C.hourly_segments(obs, True)
    r = C.integrate(segs, 0, 3 * H)
    check("200000->0 is a reset", len(r["resets"]) == 1 and approx(r["net"], 400), str(r))
    jump = sum(x[3] - x[2] for x in r["resets"])
    check("reset: net + sum(resetJump) == v_end - v_start", approx(r["net"] + jump, 300 - 200000))

    # Hearts: a drop to a small number is NOT a reset (non-monotonic metric).
    obs = [(0, 3), (H, 2), (2 * H, 4)]
    segs = C.hourly_segments(obs, False)
    r = C.integrate(segs, 0, 2 * H)
    check("hearts 3->2->4 is signed, no reset", approx(r["net"], 1) and not r["resets"], str(r))

    # A 3-day gap with +600 across it prorates: 24h window gets 200, 1h gets ~8.33.
    obs = [(0, 1000), (72 * H, 1600), (73 * H, 1605)]
    segs = C.hourly_segments(obs, True)
    r24 = C.integrate(segs, 73 * H - D, 73 * H)
    r1 = C.integrate(segs, 72 * H - H, 72 * H)
    # (49h, 73h] overlaps the 72h step for 23h, then the +5 step in full.
    check("72h gap +600: trailing 24h gets 600*23/72+5", approx(r24["net"], 600 * 23 / 72.0 + 5, 1e-6), str(r24["net"]))
    check("72h gap +600: single hour inside gap gets ~8.33", approx(r1["net"], 600 / 72.0, 1e-6), str(r1["net"]))
    check("72h gap: coverage reflects the hole", r24["coverage"] < 0.2, str(r24["coverage"]))

    # Half-open adjacency: cur + prev == whole, no step shared.
    obs = [(i * H, 100 + 7 * i) for i in range(50)]
    segs = C.hourly_segments(obs, True)
    whole = C.integrate(segs, 10 * H, 40 * H)["net"]
    cur = C.integrate(segs, 25 * H, 40 * H)["net"]
    prev = C.integrate(segs, 10 * H, 25 * H)["net"]
    check("adjacent windows partition exactly", approx(cur + prev, whole))
    # And an odd boundary mid-step still partitions.
    whole = C.integrate(segs, 10 * H + 123, 40 * H + 456)["net"]
    cur = C.integrate(segs, 25 * H + 789, 40 * H + 456)["net"]
    prev = C.integrate(segs, 10 * H + 123, 25 * H + 789)["net"]
    check("mid-step boundaries partition exactly", approx(cur + prev, whole))


# ------------------------------------------------------ summary / buckets

def synth_history(days, start_t, gap_days=None, missing_days=None, reset_at=None):
    rows = []
    v = {"a": 1000, "b": 500}
    t = start_t
    end = start_t + days * D
    while t <= end:
        day_idx = (t - start_t) // D
        in_gap = gap_days and gap_days[0] <= day_idx < gap_days[1]
        if not in_gap:
            p = {}
            for pid in ("a", "b"):
                if missing_days and pid == "b" and missing_days[0] <= day_idx < missing_days[1]:
                    continue
                if reset_at and pid == "a" and t == reset_at:
                    v["a"] = 0
                inc = 3 if pid == "a" else 1
                v[pid] += inc
                p[pid] = [v[pid], v[pid] // 5, v[pid] // 50, 100]
            rows.append(row(t, p))
        t += H
    return rows


def resolved_for(ids):
    return {"ok": True, "author": "t", "count": len(ids), "checkedAt": 0,
            "plugins": [{"id": i, "name": i, "repo": "", "category": "", "addedAt": "", "matchedBy": "author"} for i in ids]}


def summary_for(p, rows, now):
    write_rows(p["hourly"], rows)
    with open(p["resolved"], "w") as f:
        json.dump(resolved_for(["a", "b"]), f)
    meta = C.load_meta(p)
    return C.build_summary(p, meta, resolved_for(["a", "b"]), now)


def test_summary_and_series():
    d, sd, p = fresh_state()
    try:
        start = 1_700_000_000 - (1_700_000_000 % D)
        rows = synth_history(10, start, gap_days=(4, 6), missing_days=(7, 8))
        now = rows[-1]["t"]
        s = summary_for(p, rows, now)
        w24 = s["windows"]["24h"]
        w7 = s["windows"]["7d"]
        check("asOf anchors to last snapshot", s["asOf"] == now)
        check("24h views for a == 72 (3/hour)", approx(w24["plugins"]["a"]["views"]["net"], 72), str(w24["plugins"]["a"]["views"]))
        check("24h has a previous period and changePct 0", w24["plugins"]["a"]["views"].get("changePct") == 0.0, str(w24["plugins"]["a"]["views"]))
        check("7d window is partial with since set", w7["agg"]["partial"] is False or w7["agg"]["since"] == start, str(w7["agg"]))
        # The 2-day gap lies inside 7d: coverage < 1, gapHours ~ 48 - tolerance.
        cov = w7["plugins"]["a"]["views"]
        check("7d coverage reflects the 2-day gap", 0.6 < cov["coverage"] < 0.8, str(cov))
        check("7d gapHours ~ 46", 44 <= cov["gapHours"] <= 48, str(cov["gapHours"]))
        # Plugin b was absent for day 7 but present at the end: status ok, never -100%.
        b7 = w7["plugins"]["b"]
        check("absent day for b is not zero or -100%", b7["status"] == "ok" and b7["views"]["net"] > 0, str(b7["views"]))
        # changePct is suppressed when the previous window is insufficiently covered.
        w30 = s["windows"]["30d"]
        check("30d partial: no changePct", "changePct" not in w30["agg"]["views"] and w30["agg"]["partial"], str(w30["agg"]["views"]))

        # Bucket sum identity for every window.
        class A: pass
        for name in ("24h", "7d", "30d", "all", "today"):
            args = A(); args.window = name; args.metric = "views"; args.plugin = ""
            import io, contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                C.cmd_series(args, sd, p)
            out = json.loads(buf.getvalue())
            total = sum(b["v"] for b in out["agg"])
            head = s["windows"][name]["agg"]["views"]["net"]
            check("sum(buckets) == headline [%s]" % name, approx(total, head, 0.5), "%s vs %s" % (total, head))
            if name == "7d":
                low = [b for b in out["agg"] if b["c"] < 0.5]
                check("7d buckets inside the gap are flagged interpolated", len(low) >= 40, str(len(low)))
                check("7d unit is 1h", out["unit"] == H)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# --------------------------------------------------------------- rollup

def test_rollup_invariance():
    d, sd, p = fresh_state()
    try:
        start = 1_700_000_000 - (1_700_000_000 % D)
        reset_t = start + 20 * D + 14 * H
        rows = synth_history(60, start, gap_days=(30, 32), reset_at=reset_t)
        now = rows[-1]["t"]
        before = summary_for(p, rows, now)
        meta = C.load_meta(p)
        C.rollup(p, meta, now)
        meta = C.load_meta(p)
        check("rollup set a seam", meta.get("seam") is not None)
        daily, _ = C.load_rows(p["daily"])
        hourly, _ = C.load_rows(p["hourly"])
        check("rollup wrote daily rows", len(daily) >= 20, str(len(daily)))
        check("rollup trimmed hourly to ~35 days", len(hourly) < 37 * 24, str(len(hourly)))
        after = C.build_summary(p, meta, resolved_for(["a", "b"]), now)
        for name in ("90d", "all", "30d"):
            b = before["windows"][name]["agg"]["views"]["net"]
            a = after["windows"][name]["agg"]["views"]["net"]
            check("rollup invariance [%s]" % name, approx(a, b, 0.5), "%s -> %s" % (b, a))
            hb = before["windows"][name]["plugins"]["a"]["hearts"]["net"]
            ha = after["windows"][name]["plugins"]["a"]["hearts"]["net"]
            check("rollup invariance hearts [%s]" % name, approx(ha, hb, 0.5), "%s -> %s" % (hb, ha))
        # The reset on day 20 is inside the rolled-up region: it must survive as a reset.
        ra = after["windows"]["all"]["plugins"]["a"]["views"]
        check("reset inside rolled-up days is preserved", ra["resets"] == 1, str(ra))
        # Daily-row invariant: e(day) - e(prev) == g + a + jump (views).
        prev = None
        ok = True
        for r in daily:
            e = r["p"].get("a", {})
            if prev is not None and e.get("e") and prev.get("e"):
                jump = sum(x[3] - x[2] for x in e.get("r", []) if x[4] == 0)
                lhs = e["e"][0] - prev["e"][0]
                rhs = e["g"][0] + e["a"][0] + jump
                if not approx(lhs, rhs, 0.5):
                    ok = False
                    print("   day", r["d"], lhs, rhs)
            prev = e
        check("daily rows reconcile e(day)-e(prev) == g+a+jump", ok)
        # Series over 90d past the seam must use >= 1-day buckets.
        class A: pass
        args = A(); args.window = "90d"; args.metric = "views"; args.plugin = ""
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            C.cmd_series(args, sd, p)
        out = json.loads(buf.getvalue())
        check("series past the seam uses >= 1d buckets", out["unit"] >= D, str(out["unit"]))
        total = sum(b["v"] for b in out["agg"])
        check("sum(buckets) == headline after rollup [90d]", approx(total, after["windows"]["90d"]["agg"]["views"]["net"], 1.0),
              "%s vs %s" % (total, after["windows"]["90d"]["agg"]["views"]["net"]))
        # Idempotent: a second rollup changes nothing.
        C.rollup(p, meta, now)
        daily2, _ = C.load_rows(p["daily"])
        check("rollup is idempotent", len(daily2) == len(daily))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_suspect_and_missing():
    d, sd, p = fresh_state()
    try:
        start = 1_700_000_000 - (1_700_000_000 % D)
        rows = synth_history(3, start)
        # A suspect row with garbage must be ignored entirely.
        bad = row(rows[-1]["t"] - 30 * 60, {"a": [1, 0, 0, 1]}, nr=100)
        bad["suspect"] = True
        rows.insert(len(rows) - 1, bad)
        s = summary_for(p, rows, rows[-1]["t"])
        check("suspect row excluded from deltas", approx(s["windows"]["24h"]["plugins"]["a"]["views"]["net"], 72), str(s["windows"]["24h"]["plugins"]["a"]["views"]))
        # Plugin missing at the window end reports missing, not 0.
        rows = synth_history(3, start)
        for r in rows[-6:]:
            r["p"].pop("b", None)
        s = summary_for(p, rows, rows[-1]["t"])
        check("plugin absent at end is 'missing'", s["windows"]["24h"]["plugins"]["b"]["status"] == "missing", str(s["windows"]["24h"]["plugins"]["b"]["status"]))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_sanitise():
    check("plain strips tags", C.plain('<img src="http://x/y">Name') == 'img src="http://x/y"Name')
    check("plain strips control chars", C.plain("a\nb\tc") == "a b c")
    check("valid_id rejects traversal", not C.valid_id("../x") and not C.valid_id("A.b") and C.valid_id("kairos.night-sky"))
    check("repo owner parsed", C.repo_owner("https://github.com/Kairos-Tech-OH/omarchy-x") == "kairos-tech-oh")
    check("etag regex accepts real and rejects injection",
          bool(C.ETAG_RE.match('"6a98681b-51fa2d"')) and bool(C.ETAG_RE.match('W/"abc"'))
          and not C.ETAG_RE.match('"a"\r\nX-Injected: 1') and not C.ETAG_RE.match('abc'))


test_integrate()
test_summary_and_series()
test_rollup_invariance()
test_suspect_and_missing()
test_sanitise()
print()
if FAILS:
    print("%d FAILED: %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("all checks passed")
