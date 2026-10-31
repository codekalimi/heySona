# Scripts

## `generate-brand-assets.swift`

Draws every brand asset from one geometry: the AppIcon PNGs (16–1024 px, with simplified sound waves at 64 px and below), `branding/heysona-mark.svg`, and `branding/heysona-logo-light.png` / `-dark.png`.

Run it from the repo root:

```bash
swift scripts/generate-brand-assets.swift
```

Never hand-edit the generated files; change the script and run it again.
