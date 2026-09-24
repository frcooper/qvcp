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

        if ($Y -or $G) {
            if (-not (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)) {
                throw "yt-dlp not found on PATH"
            }

            $ytDlpCookiesPath = $null

            if ($Y) {
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

                $existing = Find-QvcpDownload $folder $id
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
