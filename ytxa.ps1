function ytxa {
    <#
    .SYNOPSIS
        Audits a tree of yt-dlp downloads: is the [[SourceURL|...]] comment
        present, and is each file still the best resolution YouTube offers?

    .DESCRIPTION
        Finds video files whose name carries a YouTube id in yt-dlp's default
        "[<id>]" form, reads their metadata with ffprobe, and (unless
        -NoResolutionCheck) asks yt-dlp what the best available resolution is
        now. One object per file is emitted so the result can be filtered,
        sorted, or exported.

        Each -Path entry may be a folder (scanned recursively), a single file,
        or a filespec such as *.mkv or D:\clips\*Girls*, which is matched
        recursively below its folder part.

        Resolution is compared the way yt-dlp ranks it: the smaller of width
        and height, so a 1080x1920 portrait file is "1080", not "1920".

    .EXAMPLE
        ytxa
        Full audit of the qvcp output root.

    .EXAMPLE
        ytxa D:\clips -MissingSourceUrl
        Only files whose id is in the name but not in the comment tag.

    .EXAMPLE
        ytxa '.\Some Clip [LY5YF8LgHy0].mp4' *.mkv
        One named file plus every .mkv under the current folder.

    .EXAMPLE
        ytxa | Where-Object ResStatus -eq Upgrade
        Files that YouTube now offers in a higher resolution.

    .EXAMPLE
        ytxa D:\clips\2026-07 -Upgrade
        Re-download those files in place, keeping each old one until its
        replacement has landed.
    #>
    [CmdletBinding()]
    param(
        # Folders (scanned recursively), files, or filespecs (matched
        # recursively below their folder part). Defaults to the qvcp output
        # root.
        [Parameter(Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Path,

        # Report only files whose name carries an id but whose metadata has no
        # [[SourceURL|...]] comment. The filename id still drives the
        # resolution check, so combine with -NoResolutionCheck for a quick,
        # offline listing.
        [switch]$MissingSourceUrl,

        # Skip the yt-dlp query; metadata checks only. Nothing touches the
        # network.
        [switch]$NoResolutionCheck,

        # Query YouTube with the qvcp cookies file from the start. Off by
        # default: signed-in clients are SABR-restricted and under-report the
        # format ladder, so an unauthenticated query is the more honest "best
        # available". Even when off, ids that YouTube refuses without a
        # sign-in (age-gated, private, members-only) are retried with the
        # cookies file if it exists.
        [switch]$UseCookies,

        # URLs per yt-dlp invocation. yt-dlp's start-up cost is amortised
        # across the batch; the per-video extraction cost is not.
        [ValidateRange(1, 100)]
        [int]$BatchSize = 20,

        # Re-download every file marked Upgrade into its own folder via qvcp
        # (-Y when the cookies file exists, -G otherwise). The old file is
        # moved aside first and deleted only once the new one is confirmed;
        # on failure it is put back. Needs qvcp loaded in the session.
        [switch]$Upgrade
    )

    # Kept in sync with qvcp.ps1 by hand; the two files are dot-sourced
    # independently, so there is no shared module to import.
    $YTDLP_COOKIES_FILE = 'cookies.firefox-private.txt'
    $QVCP_OUTPUT_ROOT   = if ([string]::IsNullOrWhiteSpace($env:QVCP_OUTPUT_ROOT)) { 'X:\in\clips' } else { $env:QVCP_OUTPUT_ROOT }

    # yt-dlp's default output template ends in " [%(id)s].%(ext)s". Only the
    # bracketed form is matched: an 11-character id can appear by chance in
    # any title, so a bare match would flood the report with false positives.
    $ID_IN_NAME   = '\[(?<id>[A-Za-z0-9_-]{11})\]$'
    $ID_IN_URL    = '(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/)(?<id>[A-Za-z0-9_-]{11})'
    $SOURCE_SIGIL = '\[\[SourceURL\|(?<url>.*?)\]\]'
    $VIDEO_EXT    = @('.mp4', '.mkv', '.webm', '.mov', '.m4v')

    $Path = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Path.Count -eq 0) {
        $Path = @($QVCP_OUTPUT_ROOT)
    }
    if (-not (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)) {
        throw "ffprobe not found on PATH"
    }

    if ($Upgrade -and $NoResolutionCheck) {
        throw "-Upgrade needs the resolution check; drop -NoResolutionCheck"
    }
    if ($Upgrade -and -not (Get-Command 'qvcp' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "-Upgrade downloads through qvcp, which is not loaded; dot-source qvcp.ps1 first"
    }

    $ytDlpCookiesPath = $null
    if (-not $NoResolutionCheck) {
        if (-not (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)) {
            throw "yt-dlp not found on PATH"
        }
        # The cookies file is optional unless -UseCookies demands it: without
        # the switch it only serves the sign-in retry, and its absence simply
        # leaves those ids Unavailable with yt-dlp's reason.
        $ytDlpCookiesPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $YTDLP_COOKIES_FILE
        if (-not (Test-Path -LiteralPath $ytDlpCookiesPath -PathType Leaf)) {
            if ($UseCookies) {
                throw "Cookies file not found: '$ytDlpCookiesPath'"
            }
            $ytDlpCookiesPath = $null
        }
    }

    # yt-dlp's wording when a signed-in session might help: age gates,
    # members-only, and private videos, which resolve if the account is the
    # owner. Removed or region-locked videos are not worth a retry.
    $NEEDS_SIGN_IN = 'Sign in to confirm|Private video|members-only|Join this channel|This video may be inappropriate'

    # yt-dlp ranks resolution by the smaller dimension, so portrait video is
    # measured the same way here.
    function Get-Res([object]$Width, [object]$Height) {
        $w = $Width  -as [int]
        $h = $Height -as [int]
        if (-not $w -or -not $h) { return $null }
        [Math]::Min($w, $h)
    }

    # ---- Pass 1: filesystem + ffprobe ------------------------------------

    # Folder scans and filespecs are limited to video extensions, since a
    # pattern like *Girls* would otherwise pull in yt-dlp's sidecar files
    # (.description, .jpg), which carry the same "[id]" suffix. A file named
    # outright is taken as-is and ffprobe decides. Literal lookups come first
    # because '[' in a real name is also a wildcard character.
    $isCandidate = { $VIDEO_EXT -contains $_.Extension.ToLowerInvariant() -and $_.BaseName -match $ID_IN_NAME }
    $seen  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($spec in $Path) {
        if (Test-Path -LiteralPath $spec -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $spec -File -Recurse | Where-Object $isCandidate)
        }
        elseif (Test-Path -LiteralPath $spec -PathType Leaf) {
            $item = Get-Item -LiteralPath $spec
            if ($item.BaseName -notmatch $ID_IN_NAME) {
                Write-Warning "No [id] in the file name, skipped: '$spec'"
                continue
            }
            $found = @($item)
        }
        elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($spec)) {
            # With -Recurse, a wildcard in the leaf acts as -Include for every
            # level below the folder part, which is the "recursive filespec"
            # the caller asked for.
            $found = @(Get-ChildItem -Path $spec -File -Recurse -ErrorAction SilentlyContinue | Where-Object $isCandidate)
            if ($found.Count -eq 0) {
                Write-Warning "Nothing matched '$spec'"
            }
        }
        else {
            throw "Path not found: '$spec'"
        }
        foreach ($f in $found) {
            if ($seen.Add($f.FullName)) { $files.Add($f) }
        }
    }
    $files = @($files | Sort-Object FullName)

    $rows = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($file in $files) {
        $i++
        Write-Progress -Activity 'Reading metadata' -Status $file.Name -PercentComplete (100 * $i / $files.Count)

        $id = [regex]::Match($file.BaseName, $ID_IN_NAME).Groups['id'].Value

        $row = [pscustomobject]@{
            Path            = $file.FullName
            Id              = $id
            SourceUrl       = $null
            SourceUrlStatus = 'Missing'   # Missing | OK | Mismatch
            Res             = $null
            BestRes         = $null
            ResStatus       = 'Skipped'   # Skipped | OK | Upgrade | Unavailable | NoVideo
            UpgradeStatus   = $null       # Upgraded | Failed, only with -Upgrade
            NewPath         = $null
            Note            = $null
        }

        # Every format tag is requested and matched case-insensitively below:
        # mp4 stores the comment as 'comment', mkv as 'COMMENT', and
        # -show_entries filters are case-sensitive.
        $probe = $null
        try {
            $probeText = & ffprobe -v error -show_entries 'format_tags:stream=codec_type,width,height' -of json -i $file.FullName 2>$null
            if ($LASTEXITCODE -eq 0 -and $probeText) {
                $probe = ($probeText -join "`n") | ConvertFrom-Json
            }
        }
        catch { $probe = $null }

        if (-not $probe) {
            $row.ResStatus = 'NoVideo'
            $row.Note      = 'ffprobe could not read the file'
            $rows.Add($row)
            continue
        }

        $tags = $probe.format.tags
        if ($tags) {
            foreach ($prop in $tags.PSObject.Properties) {
                if ($prop.Name -ine 'comment') { continue }
                $m = [regex]::Match([string]$prop.Value, $SOURCE_SIGIL)
                if ($m.Success) {
                    $row.SourceUrl = $m.Groups['url'].Value
                    $urlId = [regex]::Match($row.SourceUrl, $ID_IN_URL).Groups['id'].Value
                    $row.SourceUrlStatus = if ($urlId -eq $id) { 'OK' } else { 'Mismatch' }
                }
            }
        }

        $res = $null
        foreach ($stream in @($probe.streams)) {
            if ($stream.codec_type -ne 'video') { continue }
            $r = Get-Res $stream.width $stream.height
            if ($r -and (-not $res -or $r -gt $res)) { $res = $r }
        }
        $row.Res = $res
        if (-not $res) {
            $row.ResStatus = 'NoVideo'
            $row.Note      = 'no video stream with dimensions'
        }

        $rows.Add($row)
    }
    Write-Progress -Activity 'Reading metadata' -Completed

    $rows = @($rows)
    if ($MissingSourceUrl) {
        $rows = @($rows | Where-Object SourceUrlStatus -eq 'Missing')
    }

    # ---- Pass 2: yt-dlp ----------------------------------------------------

    if (-not $NoResolutionCheck) {
        $pending = @($rows | Where-Object { $_.ResStatus -ne 'NoVideo' })

        # The query key is the filename id, which is what makes untagged files
        # auditable at all. A valid SourceURL agrees with it by construction,
        # and on a mismatch the filename wins: it is the id the file was found
        # by, and the tag is already flagged. Duplicates (the same video in
        # two folders) share one query.
        $byQueryId = @{}
        foreach ($row in $pending) {
            if (-not $byQueryId.ContainsKey($row.Id)) { $byQueryId[$row.Id] = [System.Collections.Generic.List[object]]::new() }
            $byQueryId[$row.Id].Add($row)
            $row.ResStatus = 'Unavailable'   # until yt-dlp says otherwise
        }

        # One pass over a set of ids, with or without cookies, updating the
        # rows in place. Runs twice at most: once for everything, then once
        # more with cookies for the ids YouTube refused without a sign-in.
        function Invoke-YtDlpQuery([string[]]$Ids, [bool]$WithCookies, [string]$Activity) {
            $batches = [Math]::Ceiling($Ids.Count / $BatchSize)
            for ($b = 0; $b -lt $batches; $b++) {
                $chunk = $Ids[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize, $Ids.Count) - 1)]
                Write-Progress -Activity $Activity -Status ("batch {0} of {1}" -f ($b + 1), $batches) -PercentComplete (100 * $b / $batches)

                $ytDlpArgs = @('--ignore-config')
                if ($WithCookies) {
                    $ytDlpArgs += @('--cookies', $ytDlpCookiesPath)
                }
                else {
                    $ytDlpArgs += @('--no-cookies', '--no-cookies-from-browser')
                }
                # -j prints one JSON document per video and never downloads.
                # Errors for individual videos go to stderr and yt-dlp carries on
                # with the rest of the batch, so both streams are captured.
                $ytDlpArgs += @('-j', '--no-warnings')
                $ytDlpArgs += @($chunk | ForEach-Object { "https://www.youtube.com/watch?v=$_" })

                Write-Verbose ("yt-dlp " + ($ytDlpArgs -join ' '))
                $output = @(& yt-dlp @ytDlpArgs 2>&1)

                foreach ($line in $output) {
                    $text = [string]$line
                    if ($line -is [System.Management.Automation.ErrorRecord] -or $text -like 'ERROR:*') {
                        # ERROR: [youtube] <id>: <reason>
                        $m = [regex]::Match($text, '^ERROR:\s*(?:\[[^\]]+\]\s*)?(?<id>[A-Za-z0-9_-]{11}):\s*(?<reason>.*)$')
                        if ($m.Success -and $byQueryId.ContainsKey($m.Groups['id'].Value)) {
                            foreach ($row in $byQueryId[$m.Groups['id'].Value]) {
                                $row.Note = $m.Groups['reason'].Value.Trim()
                            }
                        }
                        else {
                            Write-Warning $text
                        }
                        continue
                    }

                    if (-not $text.StartsWith('{')) { continue }
                    try { $info = $text | ConvertFrom-Json } catch { Write-Warning "unparseable yt-dlp output: $($text.Substring(0, [Math]::Min(80, $text.Length)))"; continue }
                    if (-not $info.id -or -not $byQueryId.ContainsKey([string]$info.id)) { continue }

                    $best = $null
                    foreach ($f in @($info.formats)) {
                        if ($f.vcodec -eq 'none') { continue }
                        $r = Get-Res $f.width $f.height
                        if ($r -and (-not $best -or $r -gt $best)) { $best = $r }
                    }

                    foreach ($row in $byQueryId[[string]$info.id]) {
                        $row.BestRes = $best
                        if (-not $best) {
                            $row.ResStatus = 'Unavailable'
                            $row.Note      = 'no video formats offered'
                        }
                        else {
                            $row.ResStatus = if ($best -gt $row.Res) { 'Upgrade' } else { 'OK' }
                            # Only worth saying when cookies were a fallback the
                            # caller did not ask for; under -UseCookies it is
                            # the whole run and the caveat is already known.
                            $row.Note = if ($WithCookies -and -not $UseCookies) { 'resolved with cookies; the ladder may be under-reported' } else { $null }
                        }
                    }
                }
            }
            Write-Progress -Activity $Activity -Completed
        }

        $ids = @($byQueryId.Keys | Sort-Object)
        Invoke-YtDlpQuery $ids ([bool]$UseCookies) 'Querying YouTube'

        if (-not $UseCookies -and $ytDlpCookiesPath) {
            $retry = @($ids | Where-Object {
                $rowsForId = $byQueryId[$_]
                $rowsForId[0].ResStatus -eq 'Unavailable' -and $rowsForId[0].Note -match $NEEDS_SIGN_IN
            })
            if ($retry.Count -gt 0) {
                Invoke-YtDlpQuery $retry $true 'Retrying with cookies'
            }
        }

        foreach ($row in $pending) {
            if ($row.ResStatus -eq 'Unavailable' -and -not $row.Note) {
                $row.Note = 'yt-dlp returned nothing for this id'
            }
        }
    }

    # ---- Pass 3: replace upgradable files ----------------------------------

    if ($Upgrade) {
        $ASIDE_SUFFIX = '.ytxa-old'
        $todo = @($rows | Where-Object ResStatus -eq 'Upgrade')
        $i = 0
        foreach ($row in $todo) {
            $i++
            Write-Progress -Activity 'Upgrading' -Status ([System.IO.Path]::GetFileName($row.Path)) -PercentComplete (100 * ($i - 1) / $todo.Count)

            $dir   = [System.IO.Path]::GetDirectoryName($row.Path)
            $aside = $row.Path + $ASIDE_SUFFIX
            $url   = "https://www.youtube.com/watch?v=$($row.Id)"

            # yt-dlp refuses to overwrite a same-named file ("has already been
            # downloaded"), so the old one is moved aside for the duration. A
            # locked file must fail here, loudly: were the move to fail softly,
            # yt-dlp would skip the download and the old file would then be
            # mistaken for the new one.
            $movedAside = $false
            $newFile = $null
            try {
                Move-Item -LiteralPath $row.Path -Destination $aside -Force -ErrorAction Stop
                $movedAside = $true

                if ($ytDlpCookiesPath) { qvcp -Y $url -OutDir $dir } else { qvcp -G $url -OutDir $dir }

                # The new name is whatever yt-dlp chose (the title may have
                # changed, the container may differ), so find it by id.
                $newFile = Get-ChildItem -LiteralPath $dir -File |
                    Where-Object { $_.FullName -ne $aside -and $VIDEO_EXT -contains $_.Extension.ToLowerInvariant() -and $_.BaseName -match "\[$([regex]::Escape($row.Id))\]$" } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
                if (-not $newFile) {
                    throw "qvcp returned without error but no new file with [$($row.Id)] appeared in '$dir'"
                }
            }
            catch {
                $row.UpgradeStatus = 'Failed'
                $row.Note = if ($row.Note) { "$_ (before the upgrade: $($row.Note))" } else { "$_" }
                Write-Warning "Upgrade of '$($row.Path)' failed: $_"
                if ($movedAside) {
                    # No -Force: anything now sitting at the original name was
                    # produced by the download and must not be overwritten.
                    # Failing here leaves both files and says so.
                    try {
                        Move-Item -LiteralPath $aside -Destination $row.Path -ErrorAction Stop
                    }
                    catch {
                        Write-Warning "Could not restore '$($row.Path)' from '$aside': $_"
                    }
                }
                continue
            }

            $row.UpgradeStatus = 'Upgraded'
            $row.NewPath       = $newFile.FullName
            try {
                Remove-Item -LiteralPath $aside -Force -ErrorAction Stop
            }
            catch {
                $row.Note = "old file could not be removed, still at '$aside': $_"
                Write-Warning $row.Note
            }
        }
        Write-Progress -Activity 'Upgrading' -Completed
    }

    # ---- Summary -----------------------------------------------------------

    $summary = [ordered]@{
        Files          = $rows.Count
        MissingSource  = @($rows | Where-Object SourceUrlStatus -eq 'Missing').Count
        MismatchSource = @($rows | Where-Object SourceUrlStatus -eq 'Mismatch').Count
    }
    if (-not $NoResolutionCheck) {
        $summary.Upgradable  = @($rows | Where-Object ResStatus -eq 'Upgrade').Count
        $summary.Unavailable = @($rows | Where-Object ResStatus -eq 'Unavailable').Count
    }
    if ($Upgrade) {
        $summary.Upgraded      = @($rows | Where-Object UpgradeStatus -eq 'Upgraded').Count
        $summary.UpgradeFailed = @($rows | Where-Object UpgradeStatus -eq 'Failed').Count
    }
    # Write-Host lands on the information stream (PS 5+), so 6>$null silences
    # the summary and the pipeline carries only the rows.
    Write-Host (($summary.GetEnumerator() | ForEach-Object { "{0}: {1}" -f $_.Key, $_.Value }) -join '  ')

    $rows
}
