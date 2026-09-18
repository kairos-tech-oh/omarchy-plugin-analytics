---
id: omarchy-plugin-analytics.helper-py-compiles
project: omarchy-plugin-analytics
category: logic
severity: critical
environment: any
depends_on: []
---

# helper/collect.py has valid syntax

## Claim
`helper/collect.py` compiles cleanly with Python's own compiler.

## Why
The hourly systemd timer and both QML surfaces depend on this one file —
a syntax error breaks collection and every stat the plugin shows at once.

## Check
```bash
python3 -m py_compile helper/collect.py
```

## Depends On
None
