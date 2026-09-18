---
id: omarchy-plugin-analytics.manifest-schema-valid
project: omarchy-plugin-analytics
category: manifest
severity: critical
environment: any
depends_on: []
---

# manifest.json is well-formed and its entry points exist

## Claim
`manifest.json` has `schemaVersion`, `id`, `name`, `version`, and both
`entryPoints` set, and both entry-point files actually exist in the repo.

## Why
This is the minimum Omarchy needs to load the plugin — a renamed or
deleted entry-point file would otherwise only surface as a silent failure
to load on the desktop.

## Check
```bash
m=manifest.json
jq -e '.schemaVersion and .id and .name and .version and .entryPoints.barWidget and .entryPoints.panel' "$m" >/dev/null
bar=$(jq -r '.entryPoints.barWidget' "$m")
panel=$(jq -r '.entryPoints.panel' "$m")
[ -f "$bar" ] && [ -f "$panel" ]
```

## Depends On
None
