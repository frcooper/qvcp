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
- [ytxa.ps1](ytxa.ps1): PowerShell `ytxa` function that checks a tree of downloads for the SourceURL tag and for newer, higher-resolution versions on YouTube.
- [ytup.ps1](ytup.ps1): PowerShell `ytup` function that updates yt-dlp (winget) and the bgutil PO token provider (git checkout + plugin zip) together.

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
- A non-zero yt-dlp exit does **not** abort the batch: the loop warns, records the URL and exit code, and one `throw` at the end lists every failure. yt-dlp exits 1 for a skipped fragment even though the file was written, so aborting on the first one forced a full re-run of the list. The hints in that message are scoped per symptom; keep it that way rather than asserting a single cause.
- Signed-in YouTube (cookies) can land on the `tv downgraded` client with only m3u8 formats ≤1080p (SABR restriction), while `-G` (no cookies) gets the full DASH ladder. The `-Y` failure hint points at `-G` for public videos; do not "fix" this by forcing a player client in the script.
- **Generic / yt-dlp mode** (`-G` flag, alias `-Generic`): same download path, but never sends cookies — runs yt-dlp with `--ignore-config --no-cookies --no-cookies-from-browser`. The cookies file is never resolved or validated in this mode. `-Y` and `-G` live in separate parameter sets, so PowerShell rejects both at once; do not add a manual guard.
- Only set the terminal title when `$Word` is bound. `$Word` belongs to the `FFmpeg` parameter set only, so `-Y` / `-G` must leave the title untouched.
- Output folder defaults to `X:\in\clips\YYYY-MM\`, overridable via `$env:QVCP_OUTPUT_ROOT` (the tests rely on this); `-OutDir` replaces the whole dated path for a single call, which is how `ytxa -Upgrade` downloads into a file's own folder. The file name is sanitized; preserve this behavior unless the repo explicitly changes it.
- `ffmpeg` invocation uses `-c copy` and writes `title` / `comment` metadata.
- `yt-dlp` modes handle the filename automatically and run `--embed-metadata` (video title) plus two `--parse-metadata` rules that write the origin URL to both a `source` tag and `comment` as `[[SourceURL|%(webpage_url)s]]`. Keep both: `source` is for machines, `comment` for players that only show that field.
- Colons inside a `--parse-metadata` FROM half must stay escaped as `\:` — yt-dlp splits FROM:TO on the first unescaped colon.
- **Never pass `-movflags use_metadata_tags`.** It looks like the fix for mp4 dropping the non-standard `source` key, and `ffprobe` confirms the key is there — but it switches the mov muxer to the `mdta`/`keys` mechanism for every tag, so the standard `©nam`/`©cmt` atoms are never written and real players (VLC, WMP, Explorer) show nothing. There is a regression guard for this in the test suite; verify metadata changes by inspecting atoms, not with `ffprobe` alone.
- The `source` tag therefore survives only in mkv/webm. `comment` is the portable carrier, which is what the `[[SourceURL|...]]` sigil is for. It avoids ':' so the `--parse-metadata` rule needs no escaping, avoids '<>' so it survives being rendered as HTML, and uses '|' because that cannot appear unencoded in a URL.
- ffmpeg mode still writes the bare URL as `comment`, not the `[[SourceURL|...]]` form.

## ytxa helper notes

- [ytxa.ps1](ytxa.ps1) is a separate dot-sourced function, not a mode of `qvcp`. It duplicates the cookies-file name and output-root default from `qvcp.ps1` on purpose (there is no shared module); keep the two in sync by hand.
- `-Path` takes folders, files, and filespecs, several at once. Literal lookups (`Test-Path -LiteralPath`) run before the wildcard branch because `[` in a real file name is also a wildcard character; a filespec is matched recursively via `Get-ChildItem -Path <spec> -Recurse`, where a leaf wildcard acts as `-Include` at every level. The extension filter applies to folder scans and filespecs, not to a file named outright.
- Files are matched only by yt-dlp's bracketed `[<id>]` suffix. Do not loosen this to a bare 11-character match; titles contain such runs by chance.
- Resolution is compared as `min(width, height)` on both sides, which is how yt-dlp's `res` sort key works, so portrait video is not misreported.
- The yt-dlp query runs **without cookies** first, uses `-j` (no download), and batches ids per invocation. Ids whose error matches `$NEEDS_SIGN_IN` (age gate, private, members-only) get a second pass with the cookies file when it exists — `Invoke-YtDlpQuery` runs at most twice — and their rows are annotated so the caller knows the ladder came from a signed-in client. `-UseCookies` collapses this to a single signed-in pass. The cookies file is only mandatory under `-UseCookies`. Per-video `ERROR:` lines arrive on stderr; the function captures both streams with `2>&1` and maps the reason back to the row by id. The test stub emits an `ErrorRecord` on the output stream to mimic that, because `Write-Error` would become terminating under Pester's `$ErrorActionPreference`.
- `-Upgrade` re-downloads `Upgrade` rows through `qvcp` (resolved by `Get-Command` at runtime; the tests stub it). The old file is moved to `<path>.ytxa-old` before the download because yt-dlp refuses to overwrite, the replacement is located by `[id]` (title and container may differ), and only then is the old one removed; any failure restores it. `-Y` or `-G` is chosen by whether the cookies file exists.
- `-Upgrade` also writes the `[[SourceURL|...]]` comment into rows that are `OK` but `Missing` (the `Upgrade` rows get theirs from the download). The URL is derived from the filename id and written only when yt-dlp resolved that id and its `duration` agrees with ffprobe's `format=duration` within `$DURATION_TOLERANCE` (5 s); both durations live in side tables (`$fileMeta`, `$ytDurationById`), not on the rows. ffmpeg cannot edit tags in place, so it is a `-map 0 -c copy` remux into `<base>.ytxa-new.<ext>` (a name that no longer ends in `[id]`, so a concurrent scan ignores it); the comment is read back with ffprobe, the timestamps are copied over, and only then does it replace the original. An existing comment is kept behind the sigil. Success sets `SourceUrlStatus = 'Added'`; failure leaves the original, removes the temp file, and notes the reason. This is why `-Upgrade` requires `ffmpeg` on PATH.
- The function emits one object per file and writes its summary with `Write-Host`, which since PowerShell 5 lands on the information stream: `6>$null` silences it and the pipeline stays clean. Do not swap it for `Write-Information` on the assumption that `Write-Host` is unredirectable; that stopped being true in PS 4.
- `ffprobe` is called with `-i <file>`, which its own `-h` lists and which keeps a name starting with `-` from being read as an option. Do not "fix" it to a bare positional argument.
- [tests/ytxa.Tests.ps1](tests/ytxa.Tests.ps1) builds an empty placeholder tree in a temp folder and answers `ffprobe` from a per-file table keyed by leaf name (tags, dimensions, duration); `yt-dlp` answers from a per-id table of resolutions, reporting duration 100 unless `$YtxaDurations` overrides it. The `ffmpeg` stub writes its output file and registers it in the probe table with the comment it was given, so the read-back check sees it; `$YtxaFfmpegFails` / `$YtxaFfmpegDropsTag` drive the failure paths. The "ffmpeg not on PATH" test empties `$env:PATH` because a real ffmpeg may be installed alongside the stub.

## ytup helper notes

- [ytup.ps1](ytup.ps1) runs three independent steps through a local `Step` helper that catches, warns, and records; the function throws once at the end. `Step` bodies run in a child scope, so they cannot assign to `ytup`'s variables — anything to hand back is *output* (see the release lookup), and the `$versions` hashtable is mutated by reference.
- winget's "modified portable package" refusal is detected by text and retried with `--force`; "No available upgrade found" is success, not failure. Native tool output is captured with `2>&1 | ForEach-Object { "$_" }` and echoed, so the user sees winget/git/deno as they run.
- The provider checkout and the plugin zip must come from the same release: both are taken from one GitHub `releases/latest` response, and `Get-YtupPluginVersion` reads `__version__` back out of the zip to confirm. `deno install` must run with `server\` as the working directory.
- [tests/ytup.Tests.ps1](tests/ytup.Tests.ps1) stubs `winget` / `git` / `deno` / `yt-dlp` and mocks `Invoke-RestMethod` / `Invoke-WebRequest` (the latter writes a real zip). `Get-YtupCalls` builds its result with a loop and `return , $out` because piping an array of argument arrays unrolls them.

## Tests

- [tests/qvcp.Tests.ps1](tests/qvcp.Tests.ps1), [tests/ytxa.Tests.ps1](tests/ytxa.Tests.ps1) and [tests/ytup.Tests.ps1](tests/ytup.Tests.ps1) are Pester 5+ suites covering the PowerShell helpers; run them with [tests/run-tests.ps1](tests/run-tests.ps1). CI: [.github/workflows/tests.yml](.github/workflows/tests.yml).
- The suites shadow `yt-dlp` / `ffmpeg` / `ffprobe` / `winget` / `git` / `deno` with global stub **functions** (PowerShell resolves functions before applications) and assert on the recorded argument arrays — nothing is downloaded. Each file defines and removes its own stubs in `BeforeAll` / `AfterAll`, since the files run one after the other in the same session.
- Stubs also record `$Host.UI.RawUI.WindowTitle` at call time, which is the only point where the title is observable from outside.
- `-Skip:` is evaluated during Pester discovery, so anything a skip condition depends on must be probed in `BeforeDiscovery`, not `BeforeAll`. Pester rejects a `BeforeEach` at the container root; each `Describe` calls `Reset-QvcpTestState` instead.
- `Remove-Item` on the `function:` drive ignores a scope qualifier: `Remove-Item function:global:x` silently removes nothing, so stub cleanup uses `function:x`. `Set-Item function:global:x` does honour it.
- Tests must not write to the real `X:\in\clips` or the user's Documents folder. Cookie-dependent tests skip based on whether `cookies.firefox-private.txt` already exists.
- The JS files have no test coverage; keep verifying those by hand in the browser.

## Docs/versioning

- If you change userscript behavior, update [README.md](README.md) and keep the userscript header `@version` in [video-stream-capture.user.js](video-stream-capture.user.js) consistent with the change.
