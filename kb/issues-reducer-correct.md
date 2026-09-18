---
id: omarchy-plugin-analytics.issues-reducer-correct
project: omarchy-plugin-analytics
category: logic
severity: warn
environment: any
depends_on: []
---

# GitHub issues/PRs reducer is correct

## Claim
`tools/check-issues.py` passes: PR/issue separation, sanitising, URL
pinning, and rate-limit header parsing all behave correctly.

## Why
This is what turns GitHub's public API response into the open-issues red
disc and the PR list on each plugin's detail view — a wrong reducer here
misattributes or drops real repository activity.

## Check
```bash
python3 tools/check-issues.py
```

## Depends On
None
