---
id: omarchy-plugin-analytics.counter-math-correct
project: omarchy-plugin-analytics
category: logic
severity: critical
environment: any
depends_on: []
---

# window deltas and coverage maths are correct

## Claim
`tools/check-math.py` passes against `helper/collect.py`.

## Why
Every number the plugin shows — 24h/7d/30d deltas, coverage percentage,
rank movement — comes from this arithmetic over a local time series with
real gaps in it. Wrong maths here is wrong on both surfaces at once.

## Check
```bash
python3 tools/check-math.py
```

## Depends On
None
