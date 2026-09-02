#!/usr/bin/env python3
# Collector for kairos.plugin-analytics: polls the marketplace APIs, keeps a
# local time series of cumulative counters, and reduces it for the shell.
#
# Python rather than bash because O_NOFOLLOW|O_NONBLOCK + fstat cannot be
# expressed by shell redirection, and the 5 MB catalog must never reach QML.

import argparse
import datetime as dt
import fcntl
import ipaddress
import json
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import time

VERSION = "1.0.0"
REPO_URL = "https://github.com/kairos-tech-oh/omarchy-plugin-analytics"

STATS_URL = "https://api.omarchyplugins.com/v1/stats"
CATALOG_URL = "https://plugins.omarchy.org/catalog.json"
ALLOWED_HOSTS = {"api.omarchyplugins.com", "plugins.omarchy.org", "raw.githubusercontent.com", "api.github.com"}
# Open issues / pull requests per repo, from GitHub's public API with ETags.
ISSUES_CAP = 4 * 1024 * 1024
ISSUES_MAX_ITEMS = 30
ISSUES_MAX_LABELS = 5
README_CAP = 512 * 1024
README_TTL = 6 * 3600
README_NAMES = ("README.md", "readme.md", "README.markdown", "Readme.md", "README")
# README images: GitHub-hosted only, downloaded and header-checked before Qt sees them.
IMAGE_HOSTS = {"raw.githubusercontent.com", "user-images.githubusercontent.com",
               "private-user-images.githubusercontent.com", "camo.githubusercontent.com",
               "avatars.githubusercontent.com", "objects.githubusercontent.com", "github.com"}
IMAGE_CAP = 8 * 1024 * 1024
IMAGE_MAX_DIM = 6000
IMAGE_MAX_PIXELS = 12_000_000
IMAGE_TTL = 7 * 86400
IMAGE_MAX_HOPS = 3

STATS_CAP = 4 * 1024 * 1024
CATALOG_CAP = 24 * 1024 * 1024
STATE_FILE_CAP = 32 * 1024 * 1024
SERIES_OUT_CAP = 512 * 1024

PERIOD = 3600
MAX_GAP = 2 * PERIOD
RETENTION_DAYS = 35
DAY = 86400
MAX_TRACKED = 50
MAX_POINTS = 180
NR_DROP_SUSPECT = 0.20
TIMER_UNIT = "kairos-plugin-analytics.timer"

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
ETAG_RE = re.compile(r'^(W/)?"[\x21\x23-\x7e]{1,128}"$')

# Metric index inside a hourly row's per-plugin array.
M_VIEWS, M_COPIES, M_HEARTS, M_RANK, M_ISSUES, M_PRS = 0, 1, 2, 3, 4, 5
METRICS = ("views", "copies", "hearts")
MONOTONIC = {"views": True, "copies": True, "hearts": False}

WINDOWS = [("24h", DAY), ("7d", 7 * DAY), ("30d", 30 * DAY), ("90d", 90 * DAY),
           ("180d", 180 * DAY), ("365d", 365 * DAY), ("all", None)]
BUCKET_UNITS = [PERIOD, 3 * PERIOD, 6 * PERIOD, 12 * PERIOD, DAY, 2 * DAY, 7 * DAY]

EXIT_OK, EXIT_REFUSED, EXIT_NO_STATE, EXIT_NET, EXIT_TOO_BIG = 0, 1, 7, 8, 9


def log(msg):
    sys.stderr.write("collect: %s\n" % msg)


def refuse(msg, code=EXIT_REFUSED):
    log(msg)
    sys.exit(code)


# ------------------------------------------------------------------ filesystem

def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    path = os.path.join(base, "kairos.plugin-analytics")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        return None
    return path


def read_capped(path, cap):
    # One open, one read of cap+1 bytes; a body over cap is refused, not truncated.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        chunks, total = [], 0
        while total <= cap:
            chunk = os.read(fd, min(1 << 20, cap + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
        return None if len(data) > cap else data
    finally:
        os.close(fd)


def read_json(path, cap):
    raw = read_capped(path, cap)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def read_jsonl(path, cap):
    raw = read_capped(path, cap)
    rows, corrupt = [], 0
    if raw is None:
        return rows, corrupt
    for line in raw.decode("utf-8", "replace").split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            if isinstance(row, dict) and row.get("v") == 1:
                rows.append(row)
            else:
                corrupt += 1
        except ValueError:
            corrupt += 1
    return rows, corrupt


def replace_file(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=d)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, data if isinstance(data, bytes) else data.encode("utf-8"))
        os.fsync(fd)
        os.close(fd)
        os.replace(tmp, path)
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def append_line(path, line):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        os.write(fd, (line + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)


class Lock:
    def __init__(self, d):
        self.path = os.path.join(d, ".lock")
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


# --------------------------------------------------------------------- network

def validated_address(host, hosts=None):
    if host not in (hosts or ALLOWED_HOSTS):
        return None
    try:
        infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return None
    chosen = None
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
                or ip.is_multicast or ip.is_unspecified):
            return None
        chosen = chosen or str(ip)
    return chosen


def fetch(url, cap, budget, etag=None, hosts=None, redirect=None, headers=None, info=None):
    # Returns (status, body, etag). status is an int HTTP code, or None on failure.
    # With `redirect` (a dict), a 3xx stores its Location there instead of failing;
    # `info` (a dict) receives the raw response headers for the caller to inspect.
    m = re.match(r"^https://([a-z0-9.-]+)/", url)
    host = m.group(1) if m else ""
    ip = validated_address(host, hosts)
    if ip is None:
        log("refusing %s: host not allowlisted or resolved to a private address" % host)
        return None, b"", None
    budget = max(5, min(180, int(budget)))
    pin = "%s:443:%s" % (host, "[%s]" % ip if ":" in ip else ip)
    with tempfile.TemporaryDirectory(prefix="kpa-") as tmp:
        body_path = os.path.join(tmp, "body")
        head_path = os.path.join(tmp, "head")
        # --max-time is curl's whole-request wall clock (not an idle timeout), and
        # the outer `timeout` is the backstop if curl itself wedges.
        cmd = ["timeout", "-k", "2", str(budget + 5), "curl", "-sS",
               "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0",
               "--max-time", str(budget), "--resolve", pin,
               "-A", "kairos.plugin-analytics/%s (+%s)" % (VERSION, REPO_URL),
               "-o", body_path, "-D", head_path, "-w", "%{http_code}"]
        if etag and ETAG_RE.match(etag):
            cmd += ["-H", "If-None-Match: " + etag]
        for h in headers or []:
            cmd += ["-H", h]
        cmd += ["--", url]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=budget + 10)
        except (subprocess.TimeoutExpired, OSError) as e:
            log("fetch failed: %s" % e)
            return None, b"", None
        code = proc.stdout.decode("ascii", "replace").strip()
        if not code.isdigit():
            log("fetch failed: %s" % proc.stderr.decode("utf-8", "replace").strip()[:200])
            return None, b"", None
        code = int(code)
        headers = read_capped(head_path, 64 * 1024)
        if info is not None:
            info["headers"] = headers or b""
            info["status"] = code
        new_etag = etag_from_headers(headers)
        if code in (301, 302, 303, 307, 308) and redirect is not None:
            redirect["location"] = header_value(headers, "location")
            return code, b"", None
        if code == 304:
            return 304, b"", new_etag or etag
        if code != 200:
            log("fetch %s returned %d" % (host, code))
            return None, b"", None
        body = read_capped(body_path, cap)
        if body is None:
            log("fetch %s exceeded %d bytes, refusing" % (host, cap))
            return None, b"", None
        return 200, body, new_etag


def header_value(raw, name):
    if not raw:
        return ""
    for line in raw.decode("latin-1").split("\n"):
        if line.lower().startswith(name + ":"):
            return line.split(":", 1)[1].strip()
    return ""


def etag_from_headers(raw):
    # The validator is server-controlled; only a well-formed one is ever reused.
    if not raw:
        return None
    for line in raw.decode("latin-1").split("\n"):
        if line.lower().startswith("etag:"):
            tag = line.split(":", 1)[1].strip()
            return tag if ETAG_RE.match(tag) else None
    return None


# ----------------------------------------------------------------- sanitising

def plain(value, limit=120):
    text = str(value if value is not None else "")
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    text = re.sub(r"[<>&]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def valid_id(pid):
    return isinstance(pid, str) and len(pid) <= 128 and ".." not in pid and bool(ID_RE.match(pid))


def repo_owner(repo):
    m = re.match(r"^https://github\.com/([A-Za-z0-9_.-]+)/", str(repo or "") + "/")
    return m.group(1).lower() if m else ""


# --------------------------------------------------------------------- loading

def paths(d):
    return {k: os.path.join(d, v) for k, v in {
        "hourly": "hourly.jsonl", "daily": "daily.jsonl", "catalog": "catalog.jsonl",
        "meta": "meta.json", "resolved": "resolved.json", "summary": "summary.json",
    }.items()}


def load_meta(p):
    meta = read_json(p["meta"], 64 * 1024)
    return meta if isinstance(meta, dict) else {}


def save_meta(p, meta):
    replace_file(p["meta"], json.dumps(meta, separators=(",", ":")))


def load_rows(path):
    # Sorted by t, clock-jump rows dropped, duplicate timestamps last-wins.
    rows, corrupt = read_jsonl(path, STATE_FILE_CAP)
    rows = [r for r in rows if isinstance(r.get("t"), (int, float))]
    rows.sort(key=lambda r: r["t"])
    out = []
    for r in rows:
        if out and r["t"] == out[-1]["t"]:
            out[-1] = r
        elif not out or r["t"] > out[-1]["t"]:
            out.append(r)
    return out, corrupt


def day_start(ts):
    return int(ts) - (int(ts) % DAY)


def day_key(ts):
    return dt.datetime.fromtimestamp(day_start(ts), dt.timezone.utc).strftime("%Y-%m-%d")


def day_from_key(key):
    return int(dt.datetime.strptime(key, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc).timestamp())


# ------------------------------------------------------------------ the maths

def is_reset(v_i, v_j):
    return v_j < v_i and v_j <= max(10, 0.10 * v_i)


class Seg:
    __slots__ = ("a", "b", "gross", "adj", "resets", "uncovered")

    def __init__(self, a, b, gross, adj, resets, uncovered):
        self.a, self.b, self.gross, self.adj, self.resets, self.uncovered = a, b, gross, adj, resets, uncovered


def hourly_segments(obs, monotonic):
    # obs: sorted [(t, v)] for one plugin/metric. One segment per consecutive pair.
    segs = []
    for (t_i, v_i), (t_j, v_j) in zip(obs, obs[1:]):
        d = v_j - v_i
        unc = max(0, (t_j - t_i) - MAX_GAP)
        if monotonic and is_reset(v_i, v_j):
            segs.append(Seg(t_i, t_j, 0.0, 0.0, [(t_i, t_j, v_i, v_j)], unc))
        elif d >= 0:
            segs.append(Seg(t_i, t_j, float(d), 0.0, [], unc))
        else:
            segs.append(Seg(t_i, t_j, 0.0, float(d), [], unc))
    return segs


def integrate(segs, a, b):
    # Half-open (a, b]. Every segment contributes its overlapping fraction.
    gross = adj = unc = 0.0
    resets = []
    first = last = None
    for s in segs:
        lo, hi = max(s.a, a), min(s.b, b)
        if hi <= lo:
            continue
        f = (hi - lo) / float(s.b - s.a)
        gross += f * s.gross
        adj += f * s.adj
        unc += f * s.uncovered
        if s.resets and s.a >= a:
            resets.extend(s.resets)
        first = lo if first is None else min(first, lo)
        last = hi if last is None else max(last, hi)
    w = b - a
    if first is None:
        unc = float(w)
    else:
        unc += max(0, (first - a) - MAX_GAP) + max(0, (b - last) - MAX_GAP)
    coverage = 0.0 if w <= 0 else max(0.0, min(1.0, 1.0 - unc / w))
    return {"gross": gross, "adj": adj, "net": gross + adj, "resets": resets,
            "uncovered": unc, "coverage": coverage}


def last_obs_at_or_before(obs, t):
    best = None
    for ot, ov in obs:
        if ot <= t:
            best = (ot, ov)
        else:
            break
    return best


# ------------------------------------------------------------ series building

class Series:
    # All observations and segments for one plugin, across daily + hourly files.
    def __init__(self):
        self.obs = {m: [] for m in METRICS}
        self.segs = {m: [] for m in METRICS}
        self.rank = []
        self.stars = []
        self.issues = []
        self.prs = []
        self.obs_ts = []
        self.first_ts = None


def build_series(hourly, daily, catalog, seam):
    series = {}

    def get(pid):
        if pid not in series:
            series[pid] = Series()
        return series[pid]

    for row in daily:
        try:
            a = day_from_key(row["d"])
        except (KeyError, ValueError):
            continue
        b = a + DAY
        for pid, entry in (row.get("p") or {}).items():
            if not valid_id(pid) or not isinstance(entry, dict):
                continue
            s = get(pid)
            g, adj, c = entry.get("g") or [0, 0, 0], entry.get("a") or [0, 0, 0], entry.get("c", 0)
            resets = entry.get("r") or []
            for idx, m in enumerate(METRICS):
                rs = [tuple(r[:4]) for r in resets if len(r) >= 5 and r[4] == idx]
                s.segs[m].append(Seg(a, b, float(g[idx]), float(adj[idx]), rs, max(0, DAY - c)))
            if entry.get("e") and isinstance(row.get("t"), (int, float)):
                e = entry["e"]
                for idx, m in enumerate(METRICS):
                    s.obs[m].append((row["t"], e[idx]))
                if len(e) > M_RANK and e[M_RANK] is not None:
                    s.rank.append((row["t"], e[M_RANK]))
                if len(e) > M_PRS and e[M_ISSUES] is not None and e[M_PRS] is not None:
                    s.issues.append((row["t"], e[M_ISSUES]))
                    s.prs.append((row["t"], e[M_PRS]))
                s.obs_ts.append(row["t"])
            if s.first_ts is None or a < s.first_ts:
                s.first_ts = entry.get("f", a) if entry.get("f") else a

    hourly_obs = {}
    for row in hourly:
        if row.get("suspect"):
            continue
        t = row["t"]
        for pid, arr in (row.get("p") or {}).items():
            if not valid_id(pid) or not isinstance(arr, list) or len(arr) < 3:
                continue
            hourly_obs.setdefault(pid, []).append((t, arr))

    for pid, items in hourly_obs.items():
        s = get(pid)
        for m_idx, m in enumerate(METRICS):
            obs = [(t, arr[m_idx]) for t, arr in items if isinstance(arr[m_idx], (int, float))]
            segs = hourly_segments(obs, MONOTONIC[m])
            if seam:
                segs = [x for x in segs if x.b > seam]
                for x in segs:
                    if x.a < seam:
                        # The part before the seam is already inside a daily row.
                        f = (x.b - seam) / float(x.b - x.a)
                        x.gross, x.adj, x.uncovered = x.gross * f, x.adj * f, x.uncovered * f
                        x.a = seam
            s.segs[m].extend(segs)
            s.obs[m].extend(o for o in obs if not seam or o[0] > seam)
        s.rank.extend((t, arr[M_RANK]) for t, arr in items if len(arr) > M_RANK and isinstance(arr[M_RANK], (int, float)))
        s.issues.extend((t, arr[M_ISSUES]) for t, arr in items if len(arr) > M_PRS and isinstance(arr[M_ISSUES], (int, float)))
        s.prs.extend((t, arr[M_PRS]) for t, arr in items if len(arr) > M_PRS and isinstance(arr[M_PRS], (int, float)))
        s.obs_ts.extend(t for t, _ in items)
        if s.first_ts is None or items[0][0] < s.first_ts:
            s.first_ts = items[0][0]

    for row in catalog:
        t = row["t"]
        for pid, arr in (row.get("p") or {}).items():
            if valid_id(pid) and isinstance(arr, list) and arr and isinstance(arr[0], (int, float)):
                get(pid).stars.append((t, arr[0]))

    for s in series.values():
        for m in METRICS:
            s.obs[m].sort()
            s.segs[m].sort(key=lambda x: x.a)
        s.rank.sort()
        s.stars.sort()
        s.issues.sort()
        s.prs.sort()
        s.obs_ts = sorted(set(s.obs_ts))
    return series


# --------------------------------------------------------------------- rollup

def rollup(p, meta, now):
    hourly, _ = load_rows(p["hourly"])
    if not hourly:
        return
    seam = meta.get("seam") or 0
    cutoff = now - RETENTION_DAYS * DAY
    first_day = max(day_start(hourly[0]["t"]), seam)
    days = []
    d = first_day
    while d + DAY <= cutoff:
        days.append(d)
        d += DAY
    if not days:
        return

    daily_rows, _ = load_rows(p["daily"])
    existing = {r.get("d") for r in daily_rows}
    series = build_series(hourly, [], [], 0)
    new_rows = []
    for a in days:
        b = a + DAY
        key = day_key(a)
        if key in existing:
            continue
        entry = {}
        last_t = None
        for pid, s in series.items():
            g, adj, resets, unc = [], [], [], 0.0
            for idx, m in enumerate(METRICS):
                r = integrate(s.segs[m], a, b)
                g.append(round(r["gross"], 3))
                adj.append(round(r["adj"], 3))
                resets.extend([list(x) + [idx] for x in r["resets"]])
                if idx == 0:
                    unc = r["uncovered"]
            in_day = [t for t in s.obs_ts if a < t <= b]
            item = {"g": g, "a": adj, "c": int(max(0, DAY - unc)), "k": len(in_day)}
            if resets:
                item["r"] = resets
            if in_day:
                t_last = in_day[-1]
                e = [last_obs_at_or_before(s.obs[m], t_last)[1] for m in METRICS]
                rk = last_obs_at_or_before(s.rank, t_last)
                e.append(rk[1] if rk else None)
                oi = last_obs_at_or_before(s.issues, t_last)
                op = last_obs_at_or_before(s.prs, t_last)
                e.extend([oi[1] if oi else None, op[1] if op else None])
                item["e"] = e
                last_t = t_last if last_t is None else max(last_t, t_last)
            if s.first_ts and a <= s.first_ts < b:
                item["f"] = s.first_ts
            entry[pid] = item
        row = {"v": 1, "d": key, "t": last_t, "p": entry}
        new_rows.append(json.dumps(row, separators=(",", ":")))

    if new_rows:
        existing_raw = read_capped(p["daily"], STATE_FILE_CAP) or b""
        replace_file(p["daily"], existing_raw + ("\n".join(new_rows) + "\n").encode("utf-8"))
    new_seam = days[-1] + DAY
    meta["seam"] = new_seam
    save_meta(p, meta)

    # Keep the last row at or before the seam: the step across it is still needed.
    keep_from = None
    for r in hourly:
        if r["t"] <= new_seam:
            keep_from = r["t"]
    kept = [r for r in hourly if keep_from is None or r["t"] >= keep_from]
    replace_file(p["hourly"], "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in kept))


# ------------------------------------------------------------------- summary

def window_bounds(name, w, T, series_first):
    if name == "all":
        a = series_first if series_first is not None else T - PERIOD
        return a, T
    if name == "today":
        return day_start(T), T
    if name == "month":
        d = dt.datetime.fromtimestamp(T, dt.timezone.utc)
        return int(d.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp()), T
    return T - w, T


def metric_window(s, m, a, b, first_ts, want_prev):
    cur = integrate(s.segs[m], a, b)
    partial = first_ts is None or first_ts > a
    out = {"net": round(cur["net"], 2), "gross": round(cur["gross"], 2), "adj": round(cur["adj"], 2),
           "resets": len(cur["resets"]), "coverage": round(cur["coverage"], 3),
           "gapHours": round(cur["uncovered"] / 3600.0, 1), "partial": partial}
    if partial:
        out["since"] = first_ts
    if want_prev and not partial:
        w = b - a
        pa, pb = a - w, a
        if first_ts is not None and first_ts <= pa:
            prev = integrate(s.segs[m], pa, pb)
            if prev["coverage"] >= 0.9:
                out["prev"] = round(prev["net"], 2)
                if prev["net"] > 0:
                    out["changePct"] = round(100.0 * (cur["net"] - prev["net"]) / prev["net"], 1)
                elif cur["net"] > 0:
                    out["trend"] = "new"
    return out


def sparse_window(obs, a, b, refresh):
    # Signed delta for a sparse, non-prorated metric (stars, rank).
    base = last_obs_at_or_before(obs, a)
    end = last_obs_at_or_before(obs, b)
    if not end:
        return None
    if not base:
        return {"now": end[1], "delta": None, "partial": True, "since": obs[0][0] if obs else None}
    eff = (end[0] - base[0]) / 3600.0
    return {"now": end[1], "delta": end[1] - base[1], "effectiveHours": round(eff, 1),
            "approx": abs(eff * 3600 - (b - a)) > refresh, "partial": False}


def longest_gap_hours(ts, a, b):
    pts = [t for t in ts if a <= t <= b]
    if not pts:
        return round((b - a) / 3600.0, 1)
    gaps = [pts[0] - a] + [y - x for x, y in zip(pts, pts[1:])] + [b - pts[-1]]
    return round(max(gaps) / 3600.0, 1)


def build_summary(p, meta, resolved, now):
    hourly, corrupt_h = load_rows(p["hourly"])
    daily, corrupt_d = load_rows(p["daily"])
    catalog, _ = load_rows(p["catalog"])
    seam = meta.get("seam") or 0
    series = build_series(hourly, daily, catalog, seam)
    good = [r for r in hourly if not r.get("suspect")]
    T = good[-1]["t"] if good else None
    nr = good[-1].get("nr") if good else None

    tracked = [x for x in (resolved.get("plugins") or []) if valid_id(x.get("id"))]
    issues_store = read_json(os.path.join(os.path.dirname(p["meta"]), "issues.json"), 8 * 1024 * 1024) or {}
    if not isinstance(issues_store, dict):
        issues_store = {}
    global_first = None
    for s in series.values():
        if s.first_ts is not None and (global_first is None or s.first_ts < global_first):
            global_first = s.first_ts

    summary = {
        "v": 1, "generatedAt": now, "asOf": T,
        "staleMinutes": None if T is None else int((now - T) / 60),
        "nr": nr, "author": resolved.get("author", ""),
        "resolved": {k: resolved.get(k) for k in ("ok", "reason", "count", "checkedAt")},
        "collector": {
            "lastOk": meta.get("lastOk"), "lastError": meta.get("lastError"),
            "lastErrorAt": meta.get("lastErrorAt"), "snapshotCount": len(good),
            "firstTs": global_first, "corruptLines": corrupt_h + corrupt_d,
            "timerActive": timer_active(), "linger": timer_status()["linger"],
            "timerSetup": meta.get("timerSetup"), "catalog": meta.get("catalogStatus"),
            "seam": seam or None,
        },
        "plugins": [], "windows": {},
    }

    for item in tracked:
        pid = item["id"]
        s = series.get(pid)
        totals = {}
        if s:
            for m in METRICS:
                o = last_obs_at_or_before(s.obs[m], T) if T else None
                totals[m] = o[1] if o else None
            rk = last_obs_at_or_before(s.rank, T) if T else None
            totals["rank"] = rk[1] if rk else None
            totals["percentile"] = round(100.0 * (1 - (rk[1] - 1) / float(nr)), 1) if rk and nr else None
            st = s.stars[-1] if s.stars else None
            totals["stars"] = st[1] if st else None
            totals["starsAt"] = st[0] if st else None
            totals["copyRate"] = round(totals["copies"] / float(totals["views"]), 4) if totals.get("views") else None
        ie = issues_store.get(pid) if isinstance(issues_store.get(pid), dict) else {}
        if "open" in ie:
            totals["issues"] = ie.get("open")
            totals["prs"] = ie.get("prs")
        summary["plugins"].append({
            "id": pid, "name": item.get("name", pid), "repo": item.get("repo", ""),
            "category": item.get("category", ""), "addedAt": item.get("addedAt", ""),
            "matchedBy": item.get("matchedBy", ""), "firstTs": s.first_ts if s else None,
            "totals": totals,
            "issues": {"open": ie.get("open"), "prs": ie.get("prs"), "items": ie.get("items") or [],
                       "truncated": ie.get("truncated") is True, "repo": ie.get("repo", ""),
                       "fetchedAt": ie.get("t"), "stale": ie.get("stale", True) if ie else None} if ie else None,
        })

    if T is None:
        return summary

    for name, w in WINDOWS + [("today", None), ("month", None)]:
        a, b = window_bounds(name, w, T, global_first)
        if b <= a:
            a = b - PERIOD
        win = {"a": a, "b": b, "seconds": b - a, "plugins": {}, "agg": {}}
        agg = {m: {"net": 0.0, "gross": 0.0, "adj": 0.0} for m in METRICS}
        agg_stars = 0
        stars_known = True
        any_partial = False
        min_cov = 1.0
        totals_now = {m: 0 for m in METRICS}
        totals_prev = {m: 0.0 for m in METRICS}
        prev_ok = True
        for item in tracked:
            pid = item["id"]
            s = series.get(pid)
            entry = {"status": "ok"}
            if not s or not s.obs_ts:
                entry["status"] = "untracked"
                win["plugins"][pid] = entry
                continue
            end_obs = last_obs_at_or_before(s.obs["views"], b)
            if not end_obs or (b - end_obs[0]) > MAX_GAP and s.obs_ts[-1] < b - MAX_GAP:
                entry["status"] = "missing"
            for m in METRICS:
                mw = metric_window(s, m, a, b, s.first_ts, name not in ("all", "today", "month"))
                entry[m] = mw
                agg[m]["net"] += mw["net"]
                agg[m]["gross"] += mw["gross"]
                agg[m]["adj"] += mw["adj"]
                if "prev" in mw:
                    totals_prev[m] += mw["prev"]
                else:
                    prev_ok = False
                any_partial = any_partial or mw["partial"]
                min_cov = min(min_cov, mw["coverage"])
                o = last_obs_at_or_before(s.obs[m], b)
                totals_now[m] += o[1] if o else 0
            stw = sparse_window(s.stars, a, b, 6 * PERIOD)
            entry["stars"] = stw
            if stw and stw.get("delta") is not None:
                agg_stars += stw["delta"]
            else:
                stars_known = False
            entry["issues"] = sparse_window(s.issues, a, b, PERIOD)
            entry["prs"] = sparse_window(s.prs, a, b, PERIOD)
            rk = sparse_window(s.rank, a, b, PERIOD)
            if rk:
                rk["improvement"] = -rk["delta"] if rk.get("delta") is not None else None
                rk["percentile"] = round(100.0 * (1 - (rk["now"] - 1) / float(nr)), 1) if nr else None
                rk.pop("delta", None)
            entry["rank"] = rk
            dv, dc = entry["views"]["net"], entry["copies"]["net"]
            entry["copyRate"] = round(dc / dv, 4) if dv >= 30 else None
            entry["longestGapHours"] = longest_gap_hours(s.obs_ts, a, b)
            entry["snapshotCount"] = len([t for t in s.obs_ts if a < t <= b])
            win["plugins"][pid] = entry

        for pid, entry in win["plugins"].items():
            if entry.get("status") != "ok" and "views" not in entry:
                continue
            for m in ("views", "copies"):
                tot = agg[m]["net"]
                entry[m]["share"] = round(100.0 * entry[m]["net"] / tot, 1) if tot > 0 else None

        for m in METRICS:
            a_m = {"net": round(agg[m]["net"], 1), "gross": round(agg[m]["gross"], 1),
                   "adj": round(agg[m]["adj"], 1), "total": totals_now[m]}
            if prev_ok and name not in ("all", "today", "month"):
                a_m["prev"] = round(totals_prev[m], 1)
                if totals_prev[m] > 0:
                    a_m["changePct"] = round(100.0 * (agg[m]["net"] - totals_prev[m]) / totals_prev[m], 1)
                elif agg[m]["net"] > 0:
                    a_m["trend"] = "new"
            win["agg"][m] = a_m
        win["agg"]["stars"] = {"delta": agg_stars if stars_known else None,
                               "total": sum((x["totals"].get("stars") or 0) for x in summary["plugins"])}
        for key in ("issues", "prs"):
            total = sum((x["totals"].get(key) or 0) for x in summary["plugins"])
            deltas = [e[key]["delta"] for e in win["plugins"].values() if e.get(key) and e[key].get("delta") is not None]
            known = all(e.get(key) and e[key].get("delta") is not None for e in win["plugins"].values() if e.get("status") == "ok")
            win["agg"][key] = {"total": total, "delta": sum(deltas) if known and deltas else None}
        dv, dc = agg["views"]["net"], agg["copies"]["net"]
        win["agg"]["copyRate"] = round(dc / dv, 4) if dv >= 30 else None
        win["agg"]["partial"] = any_partial
        win["agg"]["coverage"] = round(min_cov, 3)
        win["agg"]["since"] = global_first
        summary["windows"][name] = win
    return summary


_TIMER_CACHE = None


def timer_active():
    return timer_status()["active"]


def timer_status():
    # Active timer + lingering user manager is what makes collection survive logout.
    global _TIMER_CACHE
    if _TIMER_CACHE is not None:
        return _TIMER_CACHE
    out = {"active": False, "linger": False}
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", TIMER_UNIT],
                           capture_output=True, timeout=5)
        out["active"] = r.returncode == 0
        user = os.environ.get("USER") or ""
        if user:
            r = subprocess.run(["loginctl", "show-user", user, "--property=Linger", "--value"],
                               capture_output=True, timeout=5)
            out["linger"] = r.stdout.decode("ascii", "replace").strip() == "yes"
    except (OSError, subprocess.TimeoutExpired):
        pass
    _TIMER_CACHE = out
    return out


def unit_texts():
    helper = os.path.abspath(__file__)
    service = ("[Unit]\n"
               "Description=Collect marketplace stats for kairos.plugin-analytics\n\n"
               "[Service]\n"
               "Type=oneshot\n"
               "ExecStart=/usr/bin/python3 %s --budget 150 collect\n"
               "Nice=10\n" % helper)
    timer = ("[Unit]\n"
             "Description=Hourly marketplace stats snapshot for kairos.plugin-analytics\n\n"
             "[Timer]\n"
             "OnBootSec=3min\n"
             "OnCalendar=hourly\n"
             "Persistent=true\n"
             "RandomizedDelaySec=300\n"
             "AccuracySec=1min\n\n"
             "[Install]\n"
             "WantedBy=timers.target\n")
    return service, timer


ISSUE_URL_RE = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/(\d{1,9})$")


def iso_to_epoch(text):
    try:
        return int(dt.datetime.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())
    except (ValueError, TypeError):
        return None


def parse_issues(body, owner, name):
    # Reduces GitHub's issues list to counts plus a short, sanitised item list.
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, list):
        return None
    items, n_issues, n_prs = [], 0, 0
    for it in data:
        if not isinstance(it, dict) or it.get("state") != "open":
            continue
        number = it.get("number")
        if not isinstance(number, int) or number <= 0:
            continue
        is_pr = isinstance(it.get("pull_request"), dict)
        if is_pr:
            n_prs += 1
        else:
            n_issues += 1
        url = str(it.get("html_url") or "")
        m = ISSUE_URL_RE.match(url)
        if not m or m.group(1).lower() != owner.lower() or m.group(2).lower() != name.lower():
            url = "https://github.com/%s/%s/%s/%d" % (owner, name, "pull" if is_pr else "issues", number)
        user = it.get("user") if isinstance(it.get("user"), dict) else {}
        labels = []
        for lb in (it.get("labels") or [])[:ISSUES_MAX_LABELS]:
            nm = plain(lb.get("name") if isinstance(lb, dict) else lb, 30)
            if nm:
                labels.append(nm)
        items.append({
            "n": number, "kind": "pr" if is_pr else "issue", "title": plain(it.get("title"), 120),
            "url": url, "by": plain(user.get("login"), 40), "labels": labels,
            "comments": int(it.get("comments") or 0) if isinstance(it.get("comments"), int) else 0,
            "updated": iso_to_epoch(it.get("updated_at")), "created": iso_to_epoch(it.get("created_at")),
            "draft": it.get("draft") is True,
        })
    items.sort(key=lambda x: x["updated"] or 0, reverse=True)
    # The list is one page of 100; past that the counts are a floor, not a total.
    return {"open": n_issues, "prs": n_prs, "items": items[:ISSUES_MAX_ITEMS], "truncated": len(data) >= 100}


def rate_limit_from(headers):
    remaining = header_value(headers, "x-ratelimit-remaining")
    reset = header_value(headers, "x-ratelimit-reset")
    return (int(remaining) if remaining.isdigit() else None, int(reset) if reset.isdigit() else None)


def fetch_issues(p, meta, resolved, remaining, now):
    # One conditional request per tracked repo; 304s are free of GitHub's rate limit.
    store = read_json(os.path.join(os.path.dirname(p["meta"]), "issues.json"), 8 * 1024 * 1024) or {}
    if not isinstance(store, dict):
        store = {}
    until = meta.get("githubRateLimitedUntil") or 0
    counts = {}
    if isinstance(until, int) and until > now:
        log("github rate limit active until %d; skipping issues" % until)
        for pid, e in store.items():
            if isinstance(e, dict) and "open" in e:
                counts[pid] = (e["open"], e["prs"])
        return counts
    changed = False
    for x in resolved.get("plugins") or []:
        pid = x.get("id")
        parts = repo_parts(x.get("repo"))
        if not valid_id(pid) or parts is None:
            continue
        if remaining() < 15:
            log("budget exhausted before issues for %s" % pid)
            break
        prev = store.get(pid) if isinstance(store.get(pid), dict) else {}
        url = "https://api.github.com/repos/%s/%s/issues?state=open&per_page=100" % parts
        info = {}
        status, body, etag = fetch(url, ISSUES_CAP, min(remaining(), 20), prev.get("etag"),
                                   headers=["Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"],
                                   info=info)
        rem, reset = rate_limit_from(info.get("headers", b""))
        if status is None and rem == 0 and reset:
            meta["githubRateLimitedUntil"] = reset
            log("github rate limited until %d" % reset)
            break
        if status == 304 and prev:
            store[pid] = dict(prev, t=now, stale=False)
            changed = True
        elif status == 200:
            parsed = parse_issues(body, parts[0], parts[1])
            body = b""
            if parsed is None:
                store[pid] = dict(prev, stale=True) if prev else {"stale": True}
            else:
                parsed.update({"t": now, "etag": etag, "stale": False, "repo": "https://github.com/%s/%s" % parts})
                store[pid] = parsed
            changed = True
        elif prev:
            store[pid] = dict(prev, stale=True)
            changed = True
        e = store.get(pid) or {}
        if "open" in e:
            counts[pid] = (e["open"], e["prs"])
    if changed:
        replace_file(os.path.join(os.path.dirname(p["meta"]), "issues.json"), json.dumps(store, separators=(",", ":")))
    return counts


def cmd_ensure_timer(args, d, p):
    # Installs the user-scope units under $XDG_CONFIG_HOME/systemd/user, enables the
    # timer, and asks logind to keep this user's manager alive across logouts.
    global _TIMER_CACHE
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    udir = os.path.join(base, "systemd", "user")
    result = {"ok": False, "installed": False, "active": False, "linger": False, "error": None}
    try:
        os.makedirs(udir, mode=0o700, exist_ok=True)
        st = os.lstat(udir)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            raise OSError("systemd user directory is not a private directory we own")
        service, timer = unit_texts()
        changed = False
        for name, text in (("kairos-plugin-analytics.service", service), ("kairos-plugin-analytics.timer", timer)):
            path = os.path.join(udir, name)
            current = read_capped(path, 16 * 1024)
            if current is None or current.decode("utf-8", "replace") != text:
                replace_file(path, text)
                changed = True
        result["installed"] = True
        if changed:
            subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True, timeout=20)
        r = subprocess.run(["systemctl", "--user", "enable", "--now", TIMER_UNIT], capture_output=True, timeout=20)
        if r.returncode != 0:
            raise OSError(r.stderr.decode("utf-8", "replace").strip()[:200] or "enable failed")
        user = os.environ.get("USER") or ""
        _TIMER_CACHE = None
        if user and not timer_status()["linger"]:
            # Allowed for an active local user without a password; best effort otherwise.
            subprocess.run(["loginctl", "enable-linger", user], capture_output=True, timeout=20)
        _TIMER_CACHE = None
        status = timer_status()
        result.update(status)
        result["ok"] = status["active"]
    except (OSError, subprocess.TimeoutExpired) as e:
        result["error"] = str(e)[:200]
    meta = load_meta(p)
    meta["timerSetupAt"] = int(time.time())
    meta["timerSetup"] = result
    save_meta(p, meta)
    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, int(time.time())), separators=(",", ":")))
    emit(result)


# --------------------------------------------------------------------- series

def pick_unit(w, past_seam):
    for u in BUCKET_UNITS:
        if past_seam and u < DAY:
            continue
        if w / float(u) <= MAX_POINTS:
            return u
    return BUCKET_UNITS[-1]


def bucketize(segs, a, b, unit):
    edges = []
    t = b
    while t > a:
        edges.append(t)
        t -= unit
    edges.append(max(a, t))
    edges.reverse()
    out = []
    for lo, hi in zip(edges, edges[1:]):
        r = integrate(segs, lo, hi)
        # v is always the prorated estimate so buckets sum to the headline; c < 0.5
        # tells the renderer to draw it as interpolated rather than observed.
        out.append({"t": hi, "v": round(r["net"], 2), "c": round(r["coverage"], 2)})
    return out


def cmd_series(args, d, p):
    meta = load_meta(p)
    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    hourly, _ = load_rows(p["hourly"])
    daily, _ = load_rows(p["daily"])
    catalog, _ = load_rows(p["catalog"])
    seam = meta.get("seam") or 0
    series = build_series(hourly, daily, catalog, seam)
    good = [r for r in hourly if not r.get("suspect")]
    if not good:
        emit({"v": 1, "ok": False, "reason": "no-data"})
        return
    T = good[-1]["t"]
    metric = args.metric if args.metric in METRICS else "views"
    names = dict(WINDOWS)
    if args.window not in names and args.window not in ("today", "month"):
        refuse("unknown window")
    global_first = min((s.first_ts for s in series.values() if s.first_ts is not None), default=None)
    a, b = window_bounds(args.window, names.get(args.window), T, global_first)
    if b <= a:
        a = b - PERIOD
    unit = pick_unit(b - a, bool(seam) and a < seam)
    tracked = [x["id"] for x in (resolved.get("plugins") or []) if valid_id(x.get("id"))]
    if args.plugin:
        tracked = [x for x in tracked if x == args.plugin]
    agg_segs = []
    per = {}
    for pid in tracked:
        s = series.get(pid)
        if not s:
            continue
        agg_segs.extend(s.segs[metric])
        per[pid] = bucketize(s.segs[metric], a, b, unit)
    out = {"v": 1, "ok": True, "window": args.window, "metric": metric, "unit": unit,
           "a": a, "b": b, "asOf": T, "agg": bucketize(agg_segs, a, b, unit), "plugins": per}
    text = json.dumps(out, separators=(",", ":"))
    if len(text) > SERIES_OUT_CAP:
        out["plugins"] = {}
        out["pluginsDropped"] = True
        text = json.dumps(out, separators=(",", ":"))
    sys.stdout.write(text[:SERIES_OUT_CAP])


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")))


# -------------------------------------------------------------------- collect

def resolve_from_catalog(body, author):
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, list):
        return None
    want = author.strip().lower()
    out, stars = [], {}
    for entry in plugins:
        if not isinstance(entry, dict) or not valid_id(entry.get("id")):
            continue
        by_author = plain(entry.get("author"), 120).lower() == want
        by_owner = repo_owner(entry.get("repo")) == want
        if not (by_author or by_owner):
            continue
        pid = entry["id"]
        out.append({
            "id": pid, "name": plain(entry.get("name") or pid, 80),
            "repo": plain(entry.get("repo"), 200) if str(entry.get("repo", "")).startswith("https://github.com/") else "",
            "category": plain(entry.get("category"), 40), "addedAt": plain(entry.get("addedAt"), 20),
            "matchedBy": "both" if by_author and by_owner else ("author" if by_author else "owner"),
        })
        st = entry.get("stars")
        stars[pid] = int(st) if isinstance(st, (int, float)) and st >= 0 else 0
        if len(out) >= MAX_TRACKED:
            break
    out.sort(key=lambda x: x["id"])
    return {"plugins": out, "stars": stars, "total": len(plugins)}


def cmd_collect(args, d, p, force_catalog=False):
    meta = load_meta(p)
    now = int(time.time())
    author = (args.author or meta.get("author") or "").strip()
    if args.author:
        if args.author.strip() != meta.get("author"):
            force_catalog = True
        meta["author"] = args.author.strip()
    if not author:
        meta["lastError"] = "no author configured"
        meta["lastErrorAt"] = now
        save_meta(p, meta)
        replace_file(p["resolved"], json.dumps({"ok": False, "reason": "no-author", "author": "", "plugins": []}))
        replace_file(p["summary"], json.dumps(build_summary(p, meta, {"ok": False, "reason": "no-author"}, now)))
        return

    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    hourly, _ = load_rows(p["hourly"])
    if hourly and not args.force and now - hourly[-1]["t"] < PERIOD // 2:
        log("skipping: last snapshot %ds ago" % (now - hourly[-1]["t"]))
        meta["lastSkip"] = now
        save_meta(p, meta)
        replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, now), separators=(",", ":")))
        return
    budget = args.budget
    deadline = time.monotonic() + budget

    def remaining():
        return max(5, int(deadline - time.monotonic()))

    # --- catalog: conditional unless the author changed or nothing is resolved.
    etag = None if (force_catalog or resolved.get("author") != author) else meta.get("catalogEtag")
    status, body, new_etag = fetch(CATALOG_URL, CATALOG_CAP, min(remaining(), 90), etag)
    catalog_stars = None
    if status == 200:
        res = resolve_from_catalog(body, author)
        body = b""
        if res is None:
            meta["catalogStatus"] = "unparseable"
        else:
            meta["catalogEtag"] = new_etag
            meta["catalogStatus"] = "fresh"
            meta["catalogAt"] = now
            resolved = {"ok": len(res["plugins"]) > 0, "author": author, "checkedAt": now,
                        "count": len(res["plugins"]), "catalogTotal": res["total"],
                        "reason": None if res["plugins"] else "no-author-match",
                        "plugins": res["plugins"]}
            replace_file(p["resolved"], json.dumps(resolved, separators=(",", ":")))
            catalog_stars = res["stars"]
    elif status == 304 and resolved.get("author") == author:
        meta["catalogStatus"] = "unchanged"
        meta["catalogAt"] = now
        rows, _ = load_rows(p["catalog"])
        if rows:
            catalog_stars = {pid: arr[0] for pid, arr in (rows[-1].get("p") or {}).items() if valid_id(pid)}
    else:
        meta["catalogStatus"] = "failed"

    if catalog_stars is not None and resolved.get("plugins"):
        row = {"v": 1, "t": now, "nr": resolved.get("catalogTotal"),
               "p": {x["id"]: [catalog_stars.get(x["id"], 0)] for x in resolved["plugins"]}}
        append_line(p["catalog"], json.dumps(row, separators=(",", ":")))

    if not resolved.get("plugins"):
        meta["lastError"] = "no plugins resolved for author"
        meta["lastErrorAt"] = now
        save_meta(p, meta)
        replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, now)))
        return

    # --- stats: hourly, unconditional.
    status, body, _ = fetch(STATS_URL, STATS_CAP, min(remaining(), 60))
    if status != 200:
        meta["lastError"] = "stats fetch failed"
        meta["lastErrorAt"] = now
        save_meta(p, meta)
        replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, now)))
        sys.exit(EXIT_NET)
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        data = None
    body = b""
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict) or data.get("schemaVersion") != 1:
        meta["lastError"] = "stats schema unexpected"
        meta["lastErrorAt"] = now
        save_meta(p, meta)
        sys.exit(EXIT_REFUSED)

    all_views = []
    for pid, st in plugins.items():
        v = st.get("views") if isinstance(st, dict) else None
        if isinstance(v, (int, float)):
            all_views.append(v)
    all_views.sort(reverse=True)
    nr = len(all_views)

    def rank_of(v):
        # Competition ranking: 1 + count of plugins with strictly more views.
        lo, hi = 0, len(all_views)
        while lo < hi:
            mid = (lo + hi) // 2
            if all_views[mid] > v:
                lo = mid + 1
            else:
                hi = mid
        return lo + 1

    row_p = {}
    for x in resolved["plugins"]:
        st = plugins.get(x["id"])
        if not isinstance(st, dict):
            continue
        vals = []
        for key in ("views", "copies", "hearts"):
            v = st.get(key)
            vals.append(int(v) if isinstance(v, (int, float)) and v >= 0 else None)
        if vals[0] is None:
            continue
        vals.append(rank_of(vals[0]))
        row_p[x["id"]] = vals

    issue_counts = fetch_issues(p, meta, resolved, remaining, now)
    for pid, vals in row_p.items():
        if pid in issue_counts:
            vals.extend([int(issue_counts[pid][0]), int(issue_counts[pid][1])])

    row = {"v": 1, "t": now, "nr": nr, "p": row_p}
    prev_nr = hourly[-1].get("nr") if hourly else None
    if isinstance(prev_nr, (int, float)) and prev_nr > 0 and nr < prev_nr * (1 - NR_DROP_SUSPECT):
        row["suspect"] = True
        log("payload shrank from %s to %d plugins; row marked suspect" % (prev_nr, nr))
    append_line(p["hourly"], json.dumps(row, separators=(",", ":")))
    meta["lastOk"] = now
    meta.pop("lastError", None)
    save_meta(p, meta)

    rollup(p, meta, now)
    replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, now), separators=(",", ":")))


def repo_parts(repo):
    m = re.match(r"^https://github\.com/([A-Za-z0-9_.-]{1,100})/([A-Za-z0-9_.-]{1,100})/?$", str(repo or ""))
    if not m or m.group(1).startswith(".") or m.group(2).startswith("."):
        return None
    return m.group(1), m.group(2)


def cmd_readme(args, d, p):
    # Fetches a plugin's root README from raw.githubusercontent.com, cached 6h.
    pid = args.plugin
    if not valid_id(pid):
        emit({"ok": False, "reason": "bad-id"})
        return
    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    entry = next((x for x in (resolved.get("plugins") or []) if x.get("id") == pid), None)
    parts = repo_parts(entry.get("repo")) if entry else None
    if parts is None:
        emit({"ok": False, "reason": "no-repo"})
        return
    cache_dir = os.path.join(d, "readme")
    os.makedirs(cache_dir, mode=0o700, exist_ok=True)
    cache_path = os.path.join(cache_dir, pid + ".json")
    now = int(time.time())
    cached = read_json(cache_path, README_CAP + 4096)
    if cached and not args.refresh and isinstance(cached.get("t"), int) and now - cached["t"] < README_TTL:
        cached["cached"] = True
        emit(cached)
        return
    budget = args.budget
    for name in README_NAMES:
        url = "https://raw.githubusercontent.com/%s/%s/HEAD/%s" % (parts[0], parts[1], name)
        status, body, _ = fetch(url, README_CAP, min(budget, 30))
        if status == 200:
            text = body.decode("utf-8", "replace")
            text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
            out = {"ok": True, "t": now, "url": url, "text": text, "cached": False,
                   "repo": "https://github.com/%s/%s" % parts}
            replace_file(cache_path, json.dumps(out, separators=(",", ":")))
            emit(out)
            return
    if cached and cached.get("ok"):
        cached["cached"] = True
        cached["stale"] = True
        emit(cached)
        return
    out = {"ok": False, "reason": "not-found", "t": now, "repo": "https://github.com/%s/%s" % parts}
    replace_file(cache_path, json.dumps(out, separators=(",", ":")))
    emit(out)


def image_dimensions(head):
    # (format, width, height) from the first bytes, or None. Each side is bounded
    # before the product is taken so a huge declared size cannot overflow past the check.
    if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
        return "png", int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    if head[:3] == b"\xff\xd8\xff":
        # Walk JPEG markers to the first SOF segment.
        i = 2
        while i + 9 < len(head):
            if head[i] != 0xFF:
                i += 1
                continue
            marker = head[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg_len = int.from_bytes(head[i + 2:i + 4], "big")
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                return "jpeg", int.from_bytes(head[i + 7:i + 9], "big"), int.from_bytes(head[i + 5:i + 7], "big")
            i += 2 + seg_len
        return None
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif", int.from_bytes(head[6:8], "little"), int.from_bytes(head[8:10], "little")
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        chunk = head[12:16]
        if chunk == b"VP8 " and len(head) >= 30:
            return "webp", int.from_bytes(head[26:28], "little") & 0x3FFF, int.from_bytes(head[28:30], "little") & 0x3FFF
        if chunk == b"VP8L" and len(head) >= 25:
            b = head[21:25]
            return "webp", (b[0] | ((b[1] & 0x3F) << 8)) + 1, ((b[1] >> 6) | (b[2] << 2) | ((b[3] & 0x0F) << 10)) + 1
        if chunk == b"VP8X" and len(head) >= 30:
            return "webp", int.from_bytes(head[24:27], "little") + 1, int.from_bytes(head[27:30], "little") + 1
    return None


def normalize_image_url(raw_url, owner, name):
    # Relative README paths and github.com blob/raw links all become raw file URLs.
    u = str(raw_url or "").strip()
    if re.search(r"[\x00-\x20<>\"'\\]", u) or len(u) > 2048:
        return None
    if u.startswith("//"):
        u = "https:" + u
    if not re.match(r"^[a-z]+:", u):
        u = u.lstrip("./")
        if u.startswith("/"):
            u = u[1:]
        return "https://raw.githubusercontent.com/%s/%s/HEAD/%s" % (owner, name, u)
    m = re.match(r"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(?:blob|raw)/([^/]+)/(.+)$", u)
    if m:
        return "https://raw.githubusercontent.com/%s/%s/%s/%s" % (m.group(1), m.group(2), m.group(3), m.group(4).split("?")[0])
    if not u.startswith("https://"):
        return None
    return u


def cmd_image(args, d, p):
    # Downloads one README image into the cache after checking host, size and
    # declared dimensions; prints where it landed. The shell only ever loads that file.
    pid = args.plugin
    if not valid_id(pid):
        emit({"ok": False, "reason": "bad-id"})
        return
    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    entry = next((x for x in (resolved.get("plugins") or []) if x.get("id") == pid), None)
    parts = repo_parts(entry.get("repo")) if entry else None
    if parts is None:
        emit({"ok": False, "reason": "no-repo"})
        return
    url = normalize_image_url(args.url, parts[0], parts[1])
    if url is None:
        emit({"ok": False, "reason": "bad-url"})
        return
    import hashlib
    key = hashlib.sha256(url.encode("utf-8")).hexdigest()[:32]
    cache_dir = os.path.join(d, "readme-images")
    os.makedirs(cache_dir, mode=0o700, exist_ok=True)
    meta_path = os.path.join(cache_dir, key + ".json")
    now = int(time.time())
    cached = read_json(meta_path, 8192)
    if cached and isinstance(cached.get("t"), int) and now - cached["t"] < IMAGE_TTL:
        if not cached.get("ok") or os.path.isfile(cached.get("path", "")):
            cached["cached"] = True
            emit(cached)
            return

    def finish(result):
        result["t"] = now
        result["url"] = url
        replace_file(meta_path, json.dumps(result, separators=(",", ":")))
        emit(result)

    host = re.match(r"^https://([a-z0-9.-]+)/", url)
    if not host or host.group(1) not in IMAGE_HOSTS:
        finish({"ok": False, "reason": "host"})
        return
    # Follow at most a few redirects, validating every hop against the same allowlist.
    current = url
    body = None
    for _ in range(IMAGE_MAX_HOPS + 1):
        hop = {}
        status, data, _ = fetch(current, IMAGE_CAP, min(args.budget, 40), hosts=IMAGE_HOSTS, redirect=hop)
        if status == 200:
            body = data
            break
        loc = hop.get("location", "")
        if not loc:
            break
        if loc.startswith("/"):
            loc = "https://" + host.group(1) + loc
        m = re.match(r"^https://([a-z0-9.-]+)/", loc)
        if not m or m.group(1) not in IMAGE_HOSTS or re.search(r"[\x00-\x20<>\"'\\]", loc):
            finish({"ok": False, "reason": "redirect"})
            return
        current = loc
    if body is None:
        finish({"ok": False, "reason": "fetch"})
        return
    dims = image_dimensions(body[:4096])
    if dims is None:
        finish({"ok": False, "reason": "format"})
        return
    fmt, w, h = dims
    if not (1 <= w <= IMAGE_MAX_DIM and 1 <= h <= IMAGE_MAX_DIM) or w * h > IMAGE_MAX_PIXELS:
        finish({"ok": False, "reason": "too-large", "width": w, "height": h})
        return
    ext = {"png": "png", "jpeg": "jpg", "gif": "gif", "webp": "webp"}[fmt]
    path = os.path.join(cache_dir, key + "." + ext)
    replace_file(path, body)
    body = b""
    finish({"ok": True, "path": path, "width": w, "height": h, "format": fmt, "bytes": os.path.getsize(path)})


def cmd_read(args, d, p):
    name = args.name
    if name not in ("summary", "resolved", "meta"):
        refuse("unknown state file")
    raw = read_capped(p[name], 1024 * 1024)
    if raw is None:
        sys.exit(EXIT_NO_STATE)
    sys.stdout.buffer.write(raw)


def cmd_rebuild(args, d, p):
    # Recompute summary.json from stored rows without touching the network.
    meta = load_meta(p)
    resolved = read_json(p["resolved"], 1024 * 1024) or {}
    rollup(p, meta, int(time.time()))
    replace_file(p["summary"], json.dumps(build_summary(p, meta, resolved, int(time.time())), separators=(",", ":")))


def main():
    ap = argparse.ArgumentParser(prog="collect")
    ap.add_argument("--budget", type=int, default=120)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--author", default="")
    c.add_argument("--force", action="store_true")
    r = sub.add_parser("resolve")
    r.add_argument("--author", required=True)
    s = sub.add_parser("series")
    s.add_argument("--window", default="7d")
    s.add_argument("--metric", default="views")
    s.add_argument("--plugin", default="")
    rd = sub.add_parser("read")
    rd.add_argument("name")
    sub.add_parser("rebuild")
    sub.add_parser("ensure-timer")
    rm = sub.add_parser("readme")
    rm.add_argument("--plugin", required=True)
    rm.add_argument("--refresh", action="store_true")
    im = sub.add_parser("image")
    im.add_argument("--plugin", required=True)
    im.add_argument("--url", required=True)
    args = ap.parse_args()
    args.budget = max(5, min(180, args.budget))

    d = state_dir()
    if d is None:
        refuse("state directory unavailable or unsafe", EXIT_NO_STATE)
    p = paths(d)

    if args.cmd == "series":
        cmd_series(args, d, p)
        return
    if args.cmd == "read":
        cmd_read(args, d, p)
        return
    if args.cmd == "readme":
        cmd_readme(args, d, p)
        return
    if args.cmd == "image":
        cmd_image(args, d, p)
        return
    with Lock(d):
        if args.cmd == "collect":
            cmd_collect(args, d, p)
        elif args.cmd == "resolve":
            args.force = True
            cmd_collect(args, d, p, force_catalog=True)
        elif args.cmd == "rebuild":
            cmd_rebuild(args, d, p)
        elif args.cmd == "ensure-timer":
            cmd_ensure_timer(args, d, p)


if __name__ == "__main__":
    main()
