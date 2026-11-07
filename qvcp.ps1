# Output root, cookies path, id matching and the SourceURL sigil are shared
# with ytxa.ps1 through this module, which has to sit next to this file.
Import-Module (Join-Path $PSScriptRoot 'QvcpCommon.psm1') -Force

function qvcp {
    [CmdletBinding(DefaultParameterSetName='FFmpeg')]
    param(
        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=0)]
        [string]$Word,

        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=1)]
        [Parameter(ParameterSetName='YouTube', Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
        [Parameter(ParameterSetName='Generic', Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
        [Parameter(ParameterSetName='Reddit', Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Url,

        [Parameter(ParameterSetName='YouTube', Mandatory=$true)]
        [switch]$Y,

        [Parameter(ParameterSetName='Generic', Mandatory=$true)]
        [Alias('Generic')]
        [switch]$G,

        [Parameter(ParameterSetName='Reddit', Mandatory=$true)]
        [switch]$R,

        # Explicit browser session for every URL in this invocation, including
        # non-YouTube sites. Accepts yt-dlp's browser[:profile] syntax.
        [Parameter(ParameterSetName='YouTube')]
        [Parameter(ParameterSetName='Reddit')]
        [ValidateNotNullOrEmpty()]
        [string]$CookiesFromBrowser,

        # Download into this folder instead of the dated one under the
        # output root. ytxa -Upgrade uses it to replace a file in place.
        [string]$OutDir
    )

    if ($R -and -not $CookiesFromBrowser) { $CookiesFromBrowser = 'firefox' }

    # FROM:TO for yt-dlp --parse-metadata, split on the first unescaped colon.
    # The sigil deliberately contains no colon, so nothing here needs escaping,
    # and '|' cannot appear unencoded in a URL, so splitting on it is safe.
    $YTDLP_COMMENT_RULE = (Format-QvcpSourceSigil '%(webpage_url)s') + ':%(meta_comment)s'
    # mp4 silently drops non-standard keys such as 'source'; mkv/webm keep them.
    # Do NOT try to rescue this with -movflags use_metadata_tags: that switches
    # the mov muxer to the mdta/keys mechanism for *all* tags, so the standard
    # atoms (title, comment) disappear and players show nothing at all.
    $YTDLP_SOURCE_RULE  = '%(webpage_url)s:%(meta_source)s'

    $originalTitle = $Host.UI.RawUI.WindowTitle

    try {
        if (-not [string]::IsNullOrWhiteSpace($Word)) {
            $Host.UI.RawUI.WindowTitle = $Word
        }

        $folder = if ([string]::IsNullOrWhiteSpace($OutDir)) {
            Join-Path (Get-QvcpOutputRoot) ('{0:yyyy-MM}' -f (Get-Date))
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

        if ($Y -or $G -or $R) {
            if (-not (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)) {
                throw "yt-dlp not found on PATH"
            }

            $ytDlpCookiesPath = $null

            if ($Y -and -not $CookiesFromBrowser) {
                $hasYouTubeUrl = $false
                foreach ($u in $Url) {
                    if ([string]::IsNullOrWhiteSpace($u)) {
                        continue
                    }

                    if (Test-QvcpYouTubeUrl $u) {
                        $hasYouTubeUrl = $true
                        break
                    }
                }

                if ($hasYouTubeUrl) {
                    $ytDlpCookiesPath = Get-QvcpCookiesPath
                    if (-not (Test-Path -LiteralPath $ytDlpCookiesPath -PathType Leaf)) {
                        throw "Cookies file not found: '$ytDlpCookiesPath'"
                    }
                }
            }

            # A re-run over files already on disk is not free: yt-dlp reports
            # 'has already been downloaded' and then runs its post-processors
            # anyway, so --embed-metadata remuxes every file again (and fails
            # on one a player still holds open). For a YouTube URL the file can
            # be found by its '[id]' suffix, the same way ytxa matches it, and
            # when its comment already carries the SourceURL sigil for that id
            # there is nothing left to write, so yt-dlp is not run at all.
            # Anything short of that (no id, no file, no ffprobe, an untagged
            # or mismatched comment) falls through to yt-dlp as before.
            $canProbe = [bool](Get-Command 'ffprobe' -ErrorAction SilentlyContinue)

            function Get-QvcpTaggedFile([string]$TargetUrl) {
                if (-not $canProbe -or -not (Test-QvcpYouTubeUrl $TargetUrl)) { return $null }
                $id = Get-QvcpUrlId $TargetUrl
                if (-not $id) { return $null }

                # @() here, not just inside the function: its output is unrolled,
                # so no match arrives as $null, and under Set-StrictMode .Count
                # on $null (or on a lone FileInfo) throws.
                $existing = @(Find-QvcpDownload $folder $id)
                if ($existing.Count -eq 0) { return $null }

                # Every copy has to be tagged: an untagged one may be the file
                # yt-dlp would post-process, and that one does need the write.
                foreach ($file in $existing) {
                    if (-not (Test-QvcpSourceComment (Read-QvcpComment $file.FullName) $id)) {
                        return $null
                    }
                }
                return $existing[0].FullName
            }

            # One bad URL must not abandon the rest of the batch: yt-dlp exits 1
            # for a skipped fragment even though the file was written, and
            # re-running the whole list to get past it is the real cost.
            $failed = @()

            foreach ($u in $Url) {
                if ([string]::IsNullOrWhiteSpace($u)) {
                    continue
                }

                $tagged = Get-QvcpTaggedFile $u
                if ($tagged) {
                    Write-Host "Already downloaded and tagged, skipping: $tagged"
                    continue
                }

                $ytDlpArgs = @()

                if ($G) {
                    $ytDlpArgs += @('--ignore-config', '--no-cookies', '--no-cookies-from-browser')
                }
                elseif ($CookiesFromBrowser) {
                    $ytDlpArgs += @('--ignore-config', '--no-cookies', '--cookies-from-browser', $CookiesFromBrowser)
                }
                else {
                    if (Test-QvcpYouTubeUrl $u) {
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
                    $hints += "  * Sign-in required: generic mode sends no cookies. For YouTube use -Y; for Reddit use -R, or for another site use -Y -CookiesFromBrowser firefox (after opening the site in that browser)."
                }
                else {
                    $hints += "  * 'tv downgraded player' in the log, or only m3u8 formats offered: YouTube is SABR-restricting the signed-in clients, which leaves HLS capped at 1080p. For public videos retry with -G (no cookies, full DASH ladder), and update with 'yt-dlp -U'."
                }
                if ($Y -or $R) {
                    $hints += "  * Reddit / other site authentication or 403: open the site in your browser and complete any challenge or sign-in, then retry with -R (Firefox), or -R -CookiesFromBrowser browser[:profile]. Plain -Y only supplies the saved cookies file to YouTube."
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

            # Streamlink is the default capture tool because certificate
            # verification can be turned off for every request it makes. ffmpeg
            # 8+ verifies by default and applies -tls_verify only to the URL it
            # opens itself, not to the playlists and segments the HLS/DASH
            # demuxer fetches, so a stream host with a bad cert fails there.
            $captured = $false

            if (Get-Command 'streamlink' -ErrorAction SilentlyContinue) {
                # Streamlink streams straight into ffmpeg, which it starts as
                # its "player" and feeds on stdin, so ffmpeg writes the mp4 as
                # the stream arrives. This is deliberately not a PowerShell
                # pipe (streamlink -O | ffmpeg -i -): PowerShell kills a native
                # command whose stdin it redirects when Ctrl+C stops the
                # pipeline, and a killed ffmpeg never writes the mp4 index.
                # Here neither process is redirected by PowerShell; Ctrl+C
                # reaches both through the console, Streamlink closes ffmpeg's
                # stdin, and ffmpeg finalizes the file. --player-no-close stops
                # Streamlink from terminating ffmpeg on exit, which on Windows
                # is TerminateProcess and would lose the file the same way.
                $scheme = if ($Url[0] -match '\.mpd($|\?)') { 'dash://' } else { 'hls://' }
                $ffmpegArgs = @(
                    '-i', '-'
                    '-c', 'copy'
                    '-metadata', "title=$Word"
                    '-metadata', "comment=$($Url[0])"
                    $outputPath
                )
                # Streamlink fills {playerinput} ('-' for stdin) through
                # str.format rules, then splits the result POSIX-shell style.
                # Single-quote every argument (backslashes in the path stay
                # literal) and double the braces so a label containing { or }
                # survives the format step.
                $playerArgs = ($ffmpegArgs | ForEach-Object {
                    if ($_ -ceq '-') { '{playerinput}' }
                    else { ("'" + ($_ -replace "'", "'\''") + "'") -replace '\{', '{{' -replace '\}', '}}' }
                }) -join ' '
                # Without verification urllib3 warns on every request, which
                # floods the console for the length of a live capture.
                $savedPythonWarnings = $env:PYTHONWARNINGS
                $env:PYTHONWARNINGS = 'ignore:Unverified HTTPS request'
                try {
                    & streamlink --http-no-ssl-verify `
                        --player ffmpeg --player-args $playerArgs --player-no-close --player-verbose `
                        ($scheme + $Url[0]) best
                }
                finally {
                    $env:PYTHONWARNINGS = $savedPythonWarnings
                }

                # Streamlink starts ffmpeg only once the stream opens, and
                # does not pass on its exit code, so the file is the evidence.
                $captured = [System.IO.File]::Exists($outputPath) -and ([System.IO.FileInfo]$outputPath).Length -gt 0
                if (-not $captured) {
                    Write-Warning "Streamlink captured nothing from '$($Url[0])'; trying ffmpeg."
                }
            }

            if (-not $captured) {
                & ffmpeg `
                    -tls_verify 0 `
                    -i $Url[0] `
                    -c copy `
                    -metadata title="$Word" `
                    -metadata comment="$($Url[0])" `
                    $outputPath

                if ($LASTEXITCODE -ne 0 -and -not (Get-Command 'streamlink' -ErrorAction SilentlyContinue)) {
                    Write-Warning "ffmpeg exited $LASTEXITCODE. If it reported 'Peer certificate failed verification', install Streamlink (winget install Streamlink.Streamlink): qvcp uses it when present, with verification off."
                }
            }
        }
    }
    finally {
        $Host.UI.RawUI.WindowTitle = $originalTitle
    }
}
