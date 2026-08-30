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

- No build system. Edit the `.js` / `.ps1` files directly. The PowerShell helper has a Pester suite (see **Tests** below); the userscripts do not.
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
- **YouTube / yt-dlp mode** (`-Y` flag): `qvcp -Y "https://www.youtube.com/watch?v=..."` — yt-dlp must be on `PATH`. Supports multiple URLs: `qvcp -Y "url1" "url2" "url3"` (downloaded sequentially). Cookies (`--cookies`) are attached only to URLs whose host is in `$youtubeHosts`.
- **Generic / yt-dlp mode** (`-G` flag, alias `-Generic`): same download path, but never sends cookies — runs yt-dlp with `--ignore-config --no-cookies --no-cookies-from-browser`. The cookies file is never resolved or validated in this mode. `-Y` and `-G` live in separate parameter sets, so PowerShell rejects both at once; do not add a manual guard.
- Only set the terminal title when `$Word` is bound. `$Word` belongs to the `FFmpeg` parameter set only, so `-Y` / `-G` must leave the title untouched.
- Output folder defaults to `X:\in\clips\YYYY-MM\`, overridable via `$env:QVCP_OUTPUT_ROOT` (the tests rely on this). The file name is sanitized; preserve this behavior unless the repo explicitly changes it.
- `ffmpeg` invocation uses `-c copy` and writes `title` / `comment` metadata.
- `yt-dlp` modes handle the filename automatically and run `--embed-metadata` (video title) plus two `--parse-metadata` rules that write the origin URL to both a `source` tag and `comment` as `<>SourceURL::%(webpage_url)s<>`. Keep both: `source` is for machines, `comment` for players that only show that field.
- Colons inside a `--parse-metadata` FROM half must stay escaped as `\:` — yt-dlp splits FROM:TO on the first unescaped colon.
- **Never pass `-movflags use_metadata_tags`.** It looks like the fix for mp4 dropping the non-standard `source` key, and `ffprobe` confirms the key is there — but it switches the mov muxer to the `mdta`/`keys` mechanism for every tag, so the standard `©nam`/`©cmt` atoms are never written and real players (VLC, WMP, Explorer) show nothing. There is a regression guard for this in the test suite; verify metadata changes by inspecting atoms, not with `ffprobe` alone.
- The `source` tag therefore survives only in mkv/webm. `comment` is the portable carrier, which is what the `<>SourceURL::...<>` sigil is for.
- ffmpeg mode still writes the bare URL as `comment`, not the `<>SourceURL::...<>` form.

## Tests

- [tests/qvcp.Tests.ps1](tests/qvcp.Tests.ps1) is a Pester 5+ suite covering the PowerShell helper; run it with [tests/run-tests.ps1](tests/run-tests.ps1). CI: [.github/workflows/tests.yml](.github/workflows/tests.yml).
- The suite shadows `yt-dlp` / `ffmpeg` with global stub **functions** (PowerShell resolves functions before applications) and asserts on the recorded argument arrays — nothing is downloaded.
- Stubs also record `$Host.UI.RawUI.WindowTitle` at call time, which is the only point where the title is observable from outside.
- `-Skip:` is evaluated during Pester discovery, so anything a skip condition depends on must be probed in `BeforeDiscovery`, not `BeforeAll`. Pester rejects a `BeforeEach` at the container root; each `Describe` calls `Reset-QvcpTestState` instead.
- Tests must not write to the real `X:\in\clips` or the user's Documents folder. Cookie-dependent tests skip based on whether `cookies.firefox-private.txt` already exists.
- The JS files have no test coverage; keep verifying those by hand in the browser.

## Docs/versioning

- If you change userscript behavior, update [README.md](README.md) and keep the userscript header `@version` in [video-stream-capture.user.js](video-stream-capture.user.js) consistent with the change.
