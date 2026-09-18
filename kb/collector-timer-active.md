---
id: omarchy-plugin-analytics.collector-timer-active
project: omarchy-plugin-analytics
category: service
severity: critical
environment: omarchy-desktop
depends_on: []
---

# hourly collector timer is active and last run succeeded

## Claim
The `kairos-plugin-analytics.timer` user unit is active, and the last run
of `kairos-plugin-analytics.service` exited 0.

## Why
Without this timer the local time series stops growing and every window
past whatever was last collected silently goes stale — the plugin would
keep showing old numbers with no error anywhere.

## Check
```bash
systemctl --user is-active --quiet kairos-plugin-analytics.timer
result=$(systemctl --user show kairos-plugin-analytics.service --property=Result --value)
[ "$result" = "success" ]
```

## Depends On
None
