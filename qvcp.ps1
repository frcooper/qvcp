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
        [switch]$G
    )

    $YTDLP_COOKIES_FILE = 'cookies.firefox-private.txt'
    # FROM:TO for yt-dlp --parse-metadata. Colons in FROM must be escaped; the
    # split is on the first unescaped one.
    $YTDLP_COMMENT_RULE = '<>SourceURL\:\:%(webpage_url)s<>:%(meta_comment)s'
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

        $now    = Get-Date
        $folder = Join-Path $QVCP_OUTPUT_ROOT ('{0:yyyy-MM}' -f $now)

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
                    $hint = if ($G) {
                        "Generic mode never sends cookies; if the site requires a sign-in, use -Y instead."
                    }
                    else {
                        "If YouTube shows nsig/SABR warnings or only image formats, update yt-dlp with 'yt-dlp -U' and try again."
                    }
                    throw "yt-dlp failed for '$u' (exit code $LASTEXITCODE). $hint"
                }
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
