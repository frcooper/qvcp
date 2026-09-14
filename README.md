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

Pass `-Y` to download with `yt-dlp` instead of ffmpeg. The title is not used in this mode — yt-dlp handles the filename automatically. `yt-dlp` must be on `PATH` or an error is thrown. The same date-stamped folder is used.

```pwsh
qvcp -Y "https://www.youtube.com/watch?v=..."
```

You can pass multiple URLs and they will be downloaded sequentially:

```pwsh
qvcp -Y "https://www.youtube.com/watch?v=abc" "https://www.youtube.com/watch?v=def"
```

Cookies are only attached to YouTube URLs; anything else in the list is fetched without them.

A URL that fails does not stop the batch: qvcp warns, moves on, and throws once at the end listing every URL that failed with its exit code. Note that yt-dlp exits 1 when it has to skip an unavailable fragment (common for the last fragment of a YouTube HLS stream) even though the file was written and a re-run reports it as already downloaded — the file is missing only that fragment.

When signed in, YouTube may SABR-restrict the clients yt-dlp uses for cookies, which shows up in the log as `Downloading tv downgraded player API JSON` and leaves only m3u8 formats capped at 1080p. For public videos, `-G` avoids cookies entirely and gets the full DASH ladder (up to 2160p), so prefer it unless the video actually needs your account.

Both yt-dlp modes run `--embed-metadata`, so the video's own title, artist, and description are written into the file, and the origin URL is recorded in `comment` as `[[SourceURL|<url>]]`:

```
TAG:title=4k JING SONG ...
TAG:artist=Cerberus_Fancam
TAG:comment=[[SourceURL|https://www.youtube.com/watch?v=SDD-DqtfQ1k]]
```

The URL is the per-video `webpage_url`, so playlist entries each get their own. A dedicated `source` tag is also requested; **mkv/webm keep it, mp4 silently drops it**, because mp4 has no slot for arbitrary keys. That is why the sigil in `comment` is the primary mechanism — `comment` is the one field every container and player supports.

The sigil is built to be trivially parseable: `|` cannot appear unencoded in a URL (RFC 3986), so a plain split works and no regex is required. It also contains no colon, which is why the `--parse-metadata` rule needs no escaping. Extract it with `[[SourceURL\|(.*?)]]`.

> **Do not add `-movflags use_metadata_tags` to rescue the `source` tag on mp4.** It does not add a key alongside the standard atoms — it switches the mov muxer to the `mdta`/`keys` mechanism for *every* tag, so `©nam` and `©cmt` disappear. `ffprobe` still reads the file fine, which makes this look like it works, but VLC, Windows Media Player, and Explorer show no metadata at all.

There is no metadata field for "origin URL" that is standard across containers — the nearest are ID3v2 `WOAS` (audio only), Dublin Core `dc:source` via XMP (which ffmpeg cannot write), and the iTunes `purl` atom (mp4 only).

### Generic / yt-dlp mode (`-G`)

Pass `-G` (alias `-Generic`) to download with `yt-dlp` while explicitly **not** sending any cookies. Use it for public videos, for non-YouTube sites, or whenever you would rather not tie the download to your signed-in account. Multiple URLs work the same way as with `-Y`.

```pwsh
qvcp -G "https://www.youtube.com/watch?v=..."
qvcp -G "https://example.com/a.mp4" "https://example.com/b.mp4"
```

`-G` runs yt-dlp with `--ignore-config --no-cookies --no-cookies-from-browser`, so neither the cookies file nor anything in your personal `yt-dlp.conf` can slip a session in. Because `--ignore-config` also discards your own format and output-template preferences, `-G` downloads use yt-dlp's defaults.

`-Y` and `-G` are mutually exclusive — passing both is a parameter-binding error. If a `-G` download fails on a sign-in wall, retry it with `-Y`.

### Output folder

The output root defaults to `X:\in\clips` and the month folder is appended automatically. Set `QVCP_OUTPUT_ROOT` to redirect it (the test suite uses this to keep out of your real clips folder):

```pwsh
$env:QVCP_OUTPUT_ROOT = 'D:\clips'
```

Drop the copied HLS/DASH URL straight into `qvcp` to build an `mp4` that’s ready for VLC, editing, or archival.

### Tests

The PowerShell helper has a [Pester](https://pester.dev) suite in [tests/](tests/). It stubs out `yt-dlp` / `ffmpeg` and asserts on the argument lists, so nothing is downloaded and no real files are written.

```pwsh
./tests/run-tests.ps1
```

Requires Pester 5+ (`Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck`). The suite also runs on Windows in CI via [.github/workflows/tests.yml](.github/workflows/tests.yml).

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
