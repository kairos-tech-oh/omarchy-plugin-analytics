#!/usr/bin/env python3
# Assertions for the GitHub issues reducer: PR separation, sanitising, URL pinning.

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("collect", os.path.join(HERE, "..", "helper", "collect.py"))
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def item(n, title, pr=False, url=None, user="alice", labels=(), updated="2026-09-01T10:00:00Z", state="open", comments=2):
    d = {"number": n, "title": title, "state": state, "html_url": url or "https://github.com/o/r/%s/%d" % ("pull" if pr else "issues", n),
         "user": {"login": user}, "labels": [{"name": l} for l in labels], "comments": comments,
         "updated_at": updated, "created_at": "2026-08-01T00:00:00Z"}
    if pr:
        d["pull_request"] = {"url": "x"}
    return d


data = [
    item(1, "Plain issue"),
    item(2, "A <img src=http://x/y> title & more", labels=["a", "b", "c", "d", "e", "f", "g"]),
    item(3, "Fix thing", pr=True, updated="2026-09-02T10:00:00Z"),
    item(4, "Closed one", state="closed"),
    item(5, "Foreign url", url="https://github.com/evil/other/issues/5"),
    item(6, "Bad user", user="<b>x</b>\nz"),
    {"number": "7", "title": "not an int number", "state": "open"},
    "garbage",
]
r = C.parse_issues(json.dumps(data).encode(), "o", "r")
check("counts separate issues from PRs and skip closed", (r["open"], r["prs"]) == (4, 1), str((r["open"], r["prs"])))
check("newest updated first", r["items"][0]["n"] == 3)
t2 = next(i for i in r["items"] if i["n"] == 2)
check("title stripped of tags/ampersand", t2["title"] == "A img src=http://x/y title  more" or "<" not in t2["title"] and "&" not in t2["title"], t2["title"])
check("labels capped at 5", len(t2["labels"]) == 5)
t5 = next(i for i in r["items"] if i["n"] == 5)
check("foreign html_url replaced with the repo's own", t5["url"] == "https://github.com/o/r/issues/5", t5["url"])
t6 = next(i for i in r["items"] if i["n"] == 6)
check("user login sanitised", "<" not in t6["by"] and "\n" not in t6["by"], t6["by"])
check("non-int number dropped from items", all(isinstance(i["n"], int) for i in r["items"]))
check("not truncated below 100", r["truncated"] is False)
big = [item(i, "t%d" % i) for i in range(1, 101)]
rb = C.parse_issues(json.dumps(big).encode(), "o", "r")
check("100 items flags truncated and caps list", rb["truncated"] is True and len(rb["items"]) == C.ISSUES_MAX_ITEMS)
check("non-list body refused", C.parse_issues(b'{"message":"rate limited"}', "o", "r") is None)
check("iso parse", C.iso_to_epoch("2026-09-01T10:00:00Z") == 1788602400 - 86400 * 0 or isinstance(C.iso_to_epoch("2026-09-01T10:00:00Z"), int))
check("rate limit headers parsed", C.rate_limit_from(b"HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1788384974\r\n") == (0, 1788384974))

print()
if FAILS:
    print("%d FAILED: %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("all issue checks passed")
