---
id: omarchy-plugin-analytics.image-handling-correct
project: omarchy-plugin-analytics
category: logic
severity: warn
environment: any
depends_on: []
---

# README image URLs are parsed and normalised safely

## Claim
`tools/check-images.py` passes: header-parsing and URL-normalisation for
README images behave correctly, including rejecting non-https sources.

## Why
This is the boundary between an untrusted README (someone else's plugin,
fetched over the marketplace API) and an image actually rendered in the
detail view — the safe path here matters more than most.

## Check
```bash
python3 tools/check-images.py
```

## Depends On
None
