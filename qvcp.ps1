function qvcp {
    [CmdletBinding(DefaultParameterSetName='FFmpeg')]
    param(
        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=0)]
        [string]$Word,

        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=1)]
        [Parameter(ParameterSetName='YouTube', Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
        [Parameter(ParameterSetName='Generic', Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Url,

        [Parameter(ParameterSetName='YouTube', Mandatory=$true)]
        [switch]$Y,

        [Parameter(ParameterSetName='Generic', Mandatory=$true)]
        [Alias('Generic')]
        [switch]$G,

        # Download into this folder instead of the dated one under the
        # output root. ytxa -Upgrade uses it to replace a file in place.
        [string]$OutDir
    )

    $YTDLP_COOKIES_FILE = 'cookies.firefox-private.txt'
    # FROM:TO for yt-dlp --parse-metadata, split on the first unescaped colon.
    # The sigil deliberately contains no colon, so nothing here needs escaping,
    # and '|' cannot appear unencoded in a URL, so splitting on it is safe.
    $YTDLP_COMMENT_RULE = '[[SourceURL|%(webpage_url)s]]:%(meta_comment)s'
    # mp4 silently drops non-standard keys such as 'source'; mkv/webm keep them.
    # Do NOT try to rescue this with -movflags use_metadata_tags: that switches
    # the mov muxer to the mdta/keys mechanism for *all* tags, so the standard
    # atoms (title, comment) disappear and players show nothing at all.
    $YTDLP_SOURCE_RULE  = '%(webpage_url)s:%(meta_source)s'
    $QVCP_OUTPUT_ROOT   = if ([string]::IsNullOrWhiteSpace($env:QVCP_OUTPUT_ROOT)) { 'X:\in\clips' } else { $env:QVCP_OUTPUT_ROOT }

    $originalTitle = $Host.UI.RawUI.WindowTitle

    try {
        if (-not [string]::IsNullOrWhiteSpace($Word)) {
            $Host.UI.RawUI.WindowTitle = $Word
        }

        $folder = if ([string]::IsNullOrWhiteSpace($OutDir)) {
            Join-Path $QVCP_OUTPUT_ROOT ('{0:yyyy-MM}' -f (Get-Date))
        }
        else {
            $OutDir
        }

        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            try {
                [void][System.IO.Directory]::CreateDirectory($folder)
            }
            catch {
                throw "Unable to access output folder '$folder' : $_"
            }
        }

        if ($Y -or $G) {
            if (-not (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)) {
                throw "yt-dlp not found on PATH"
            }

            $youtubeHosts = @(
                'youtube.com',
                'www.youtube.com',
                'm.youtube.com',
                'music.youtube.com',
                'youtu.be',
                'www.youtu.be',
                'youtube-nocookie.com',
                'www.youtube-nocookie.com'
            )

            $ytDlpCookiesPath = $null

            if ($Y) {
                $hasYouTubeUrl = $false
                foreach ($u in $Url) {
                    if ([string]::IsNullOrWhiteSpace($u)) {
                        continue
                    }

                    $uri = $null
                    if ([Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -and $youtubeHosts -contains $uri.Host.ToLowerInvariant()) {
                        $hasYouTubeUrl = $true
                        break
                    }
                }

                if ($hasYouTubeUrl) {
                    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
                    $ytDlpCookiesPath = Join-Path $documentsPath $YTDLP_COOKIES_FILE
                    if (-not (Test-Path -LiteralPath $ytDlpCookiesPath -PathType Leaf)) {
                        throw "Cookies file not found: '$ytDlpCookiesPath'"
                    }
                }
            }

            # One bad URL must not abandon the rest of the batch: yt-dlp exits 1
            # for a skipped fragment even though the file was written, and
            # re-running the whole list to get past it is the real cost.
            $failed = @()

            foreach ($u in $Url) {
                if ([string]::IsNullOrWhiteSpace($u)) {
                    continue
                }

                $ytDlpArgs = @()

                if ($G) {
                    $ytDlpArgs += @('--ignore-config', '--no-cookies', '--no-cookies-from-browser')
                }
                else {
                    $uri = $null
                    $isYouTube = [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -and $youtubeHosts -contains $uri.Host.ToLowerInvariant()

                    if ($isYouTube) {
                        $ytDlpArgs += @('--ignore-config', '--cookies', $ytDlpCookiesPath)
                    }
                }

                $ytDlpArgs += @(
                    '--embed-metadata',
                    '--parse-metadata', $YTDLP_COMMENT_RULE,
                    '--parse-metadata', $YTDLP_SOURCE_RULE
                )
                $ytDlpArgs += @('-P', $folder, $u)

                & yt-dlp @ytDlpArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "yt-dlp exited $LASTEXITCODE for '$u'; continuing with the remaining URLs."
                    $failed += [pscustomobject]@{ Url = $u; ExitCode = $LASTEXITCODE }
                }
            }

            if ($failed.Count -gt 0) {
                # Tie each hint to the symptom that warrants it. yt-dlp exits 1
                # for everything, so asserting a single cause here misleads.
                $hints = @(
                    "  * 'Did not get any data blocks' then 'Skipping fragment N': a fragment (typically the last one of a YouTube HLS stream) was unavailable. The file was still written without it and a re-run reports it 'already downloaded'; only that fragment is missing."
                    "  * 'Postprocessing' / 'No such file or directory': the target file is locked or unreadable. A player or Explorer may still hold it open, and on a network share a deleted-but-open file lingers in the listing. Close it and retry."
                    "  * nsig/SABR warnings, or only image formats offered: update with 'yt-dlp -U'."
                )
                if ($G) {
                    $hints += "  * Sign-in required: generic mode sends no cookies, so use -Y instead."
                }
                else {
                    $hints += "  * 'tv downgraded player' in the log, or only m3u8 formats offered: YouTube is SABR-restricting the signed-in clients, which leaves HLS capped at 1080p. For public videos retry with -G (no cookies, full DASH ladder), and update with 'yt-dlp -U'."
                }
                $attempted = @($Url | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                $lines = @($failed | ForEach-Object { "  '$($_.Url)' (exit code $($_.ExitCode))" })
                throw ("yt-dlp failed for {0} of {1} URL(s):`n{2}`nCheck the yt-dlp output above:`n{3}" -f $failed.Count, $attempted, ($lines -join "`n"), ($hints -join "`n"))
            }
        }
        else {
            $safeWord   = ($Word -replace '[\\\/\:\*\?\"\<\>\|]', '_').Trim()
            $baseName   = $safeWord
            $baseFile   = Join-Path $folder ($baseName + '.mp4')
            $outputPath = $baseFile

            if ([System.IO.File]::Exists($baseFile)) {
                $i = 2
                while ($true) {
                    $candidate = Join-Path $folder ("{0}-{1}.mp4" -f $baseName, $i)
                    if (-not [System.IO.File]::Exists($candidate)) {
                        $outputPath = $candidate
                        break
                    }
                    $i++
                }
            }

            & ffmpeg `
                -i $Url[0] `
                -c copy `
                -metadata title="$Word" `
                -metadata comment="$($Url[0])" `
                $outputPath
        }
    }
    finally {
        $Host.UI.RawUI.WindowTitle = $originalTitle
    }
}
