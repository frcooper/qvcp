# Video Stream Capture (Right‑Click to Copy HLS/DASH)

Right‑click any playing `<video>` to instantly copy a stream URL. Normal right‑click copies the best variant (from HLS master or DASH MPD when available). Ctrl+right‑click copies the raw URL you targeted or last seen.

This userscript is hardened for real sites: keeps a master‑first strategy, prefers remux‑friendly codecs, instruments network calls from the page context (works under CSP/sandbox), runs in all frames, preserves query tokens, and never blocks native menus.

Looking for a Brave Shields scriptlet version? See [`brave-scriptlet.md`](brave-scriptlet.md).

## Install

- Firefox: Tampermonkey, Violentmonkey, or FireMonkey.
- Click “Create new userscript,” paste the code from `video-stream-capture.user.js`, and save.
- No site permissions tuning needed due to `@match *://*/*`.
- No extra grants are required beyond `GM_setClipboard`.

## Usage

- Right‑click directly on the playing `<video>` element.
  - Regular right‑click: copies best variant from master/MPD when available.
  - Ctrl+right‑click: copies the raw URL you targeted or last seen.

Tip: You can paste the copied URL directly into tools or players. For downloads or remux:

```sh
ffmpeg -i "<copied-url>" -c copy output.mp4
```

For playback, VLC can open the same URL.

## PowerShell helper (`qvcp.ps1`)

`qvcp.ps1` wraps ffmpeg so you can archive the copied stream URL with one command. Add it to your PowerShell profile so the `qvcp` function is always available (e.g., `if (Test-Path 'C:\tools\qvcp\qvcp.ps1') { . 'C:\tools\qvcp\qvcp.ps1' }`). It takes the clip label and the URL:

```pwsh
qvcp "Show • Episode 12" "https://example.com/path/to/master.m3u8?token=..."
```

- Saves into `X:\in\clips\YYYY-MM\` (auto-creates the month folder).
- Sanitizes the label for filenames and appends `-1`, `-2`, … if a duplicate exists.
- Runs `ffmpeg -c copy` so the stream is remuxed without re-encoding.
- Records the title and original URL as `title` / `comment` metadata tags.
- Temporarily sets the terminal title to the label to make long captures easy to identify.

### YouTube / yt-dlp mode (`-Y`)

Pass `-Y` to download with `yt-dlp` instead of ffmpeg. The title is optional in this mode — yt-dlp handles the filename automatically. `yt-dlp` must be on `PATH` or an error is thrown. The command always includes `--ignore-config` and `--cookies "C:\Users\FRC\Documents\cookies.firefox-private.txt"`. The same date-stamped folder is used.

```pwsh
qvcp -Y "https://www.youtube.com/watch?v=..."
```

If YouTube extraction fails with `nsig`/SABR warnings or only image formats, run `yt-dlp -U` and retry.

Drop the copied HLS/DASH URL straight into `qvcp` to build an `mp4` that’s ready for VLC, editing, or archival.

## How it decides “best”

- HLS: If a master playlist (`.m3u8` with `#EXT-X-STREAM-INF`) is found, the script picks the highest‑scoring variant by resolution and bandwidth, with a codec preference order tuned for easy remux: `h264/avc1` > `vp9` > `hvc1/hev1` > `av01`.
- DASH: If an MPD is present, the script scores video representations similarly and returns the MPD URL (players and tools select optimal segments).
- Raw mode (Ctrl): bypasses upgrading and copies the exact URL seen.

## Features

- Master‑first logic with smart upgrade to the best variant
- Codec order optimized for remux with ffmpeg/VLC
- Page‑context instrumentation of fetch/XHR (reliable under CSP and sandboxing)
- Works in all frames (top page and iframes)
- Preserves query strings and auth tokens when copying
- Non‑intrusive: never blocks native context menus
- Runs at `document-start` so it catches early requests

## Compatibility & limitations

- Targets HLS (`.m3u8`) and DASH (`.mpd`) URLs.
- Clipboard write uses `GM_setClipboard` when available, with a fallback to the standard Clipboard API.
- Matching is site‑wide via `*://*/*`; you can narrow it in the userscript header if desired.

## Permissions

- `@match *://*/*`
- `@grant GM_setClipboard`

That’s it—no additional permissions are needed.
