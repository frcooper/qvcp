# Agent directives (qvcp)

This repo is a small, copy/paste–driven toolkit:

- A userscript that right-click copies “best” HLS/DASH stream URLs.
- A Brave Shields scriptlet port of the same logic.
- A PowerShell helper that remuxes a copied URL to an MP4 via `ffmpeg`.

## Key files

- [video-stream-capture.user.js](video-stream-capture.user.js): Tampermonkey/Violentmonkey userscript (`@grant GM_setClipboard`).
- [brave-video-stream-capture.scriptlet.js](brave-video-stream-capture.scriptlet.js): Brave scriptlet variant (no GM_* APIs; clipboard fallbacks).
- [brave-scriptlet.md](brave-scriptlet.md): Brave installation / enablement steps.
- [qvcp.ps1](qvcp.ps1): PowerShell `qvcp` function wrapper around `ffmpeg`.

## Workflow

- No build system / tests: edit the `.js` / `.ps1` files directly.
- When changing stream selection logic, keep both JS implementations functionally aligned:
  - URL detection (`isHLS` / `isDASH`) and normalization (`absURL`).
  - Upgrade logic (`upgradeToBest`, `pickBestFromHLSMaster`, `pickBestFromMPD`).
  - Input modifier: `RAW_MODIFIER` is `ctrlKey`.

## Project-specific conventions

- Page-context instrumentation is core: both JS variants inject hooks for `fetch` and `XMLHttpRequest.open` and forward “seen” URLs via `window.postMessage`.
- UX must stay non-intrusive: do not block native context menus; use toast/prompt feedback.
- “Best” selection policy (keep consistent with [README.md](README.md)):
  - Prefer master playlist / MPD when present.
  - Codec preference order optimized for remux: `['h264','avc1','vp9','hvc1','hev1','av01']`.
  - Score variants primarily by resolution/bandwidth (see `PREFER_RESOLUTION`).
- State isolation: by default `BY_ORIGIN = true` buckets “last seen” per `location.origin`.

## PowerShell helper notes

- [qvcp.ps1](qvcp.ps1) defines a function (not a script entrypoint). Typical usage is to load it from your PowerShell profile so `qvcp` is available in every session. Example profile snippet:
  - `if (Test-Path 'C:\tools\qvcp\qvcp.ps1') { . 'C:\tools\qvcp\qvcp.ps1' }`
- **ffmpeg mode** (default): `qvcp "Label" "https://...m3u8"`
- **YouTube / yt-dlp mode** (`-Y` flag): `qvcp -Y "https://www.youtube.com/watch?v=..."` — yt-dlp must be on `PATH`. Supports multiple URLs: `qvcp -Y "url1" "url2" "url3"` (downloaded sequentially).
- Output folder is currently hardcoded to `X:\in\clips\YYYY-MM\` and the file name is sanitized; preserve this behavior unless the repo explicitly changes it.
- `ffmpeg` invocation uses `-c copy` and writes `title` / `comment` metadata.
- `yt-dlp` mode handles filename and metadata automatically.

## Docs/versioning

- If you change userscript behavior, update [README.md](README.md) and keep the userscript header `@version` in [video-stream-capture.user.js](video-stream-capture.user.js) consistent with the change.
