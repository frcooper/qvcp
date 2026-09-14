#Requires -Version 7.0

# Tests for the `ytxa` PowerShell helper.
#
# `ffprobe` and `yt-dlp` are replaced with global stub functions, as in
# qvcp.Tests.ps1. The ffprobe stub answers from a per-file table of tags and
# dimensions; the yt-dlp stub answers from a per-id table of available
# resolutions and reports unknown ids the way yt-dlp does, on stderr. The
# files under test are empty placeholders in a temp tree.

BeforeDiscovery {
    $global:YtxaHasCookies = Test-Path -LiteralPath (
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'cookies.firefox-private.txt'
    ) -PathType Leaf
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'ytxa.ps1')

    $global:YtxaRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ytxa-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:YtxaRoot -Force | Out-Null

    # Probe table: leaf file name -> @{ Tags = @{...}; Width = ; Height = }.
    # A file absent from the table is reported as unreadable (ffprobe exit 1).
    function global:ffprobe {
        $global:YtxaProbeCalls += , ([string[]]$args)
        $file = [System.IO.Path]::GetFileName([string]$args[-1])
        $entry = $global:YtxaProbe[$file]
        if (-not $entry) {
            $global:LASTEXITCODE = 1
            return
        }
        $streams = @(@{ codec_type = 'audio' })
        if ($entry.Width) {
            $streams += @{ codec_type = 'video'; width = $entry.Width; height = $entry.Height }
        }
        $global:LASTEXITCODE = 0
        @{ streams = $streams; format = @{ tags = $entry.Tags } } | ConvertTo-Json -Depth 5
    }

    # Format table: id -> int[] of resolutions on offer (as min(width,height)).
    # Ids in $YtxaGated answer only when --cookies is on the command line,
    # failing with yt-dlp's sign-in wording otherwise.
    function global:yt-dlp {
        $global:YtxaYtDlpCalls += , ([string[]]$args)
        $global:LASTEXITCODE = 0
        $withCookies = [string[]]$args -contains '--cookies'
        foreach ($a in $args) {
            if ($a -notmatch 'watch\?v=(?<id>[A-Za-z0-9_-]{11})$') { continue }
            $id = $Matches['id']
            if ($global:YtxaGated -contains $id -and -not $withCookies) {
                [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new("ERROR: [youtube] ${id}: Sign in to confirm your age. Use --cookies-from-browser or --cookies for the authentication."),
                    'NativeCommandError', 'FromStdErr', $null)
                $global:LASTEXITCODE = 1
                continue
            }
            if (-not $global:YtxaFormats.ContainsKey($id)) {
                # What a native command's stderr looks like after 2>&1: an
                # ErrorRecord whose ToString() is the line. Emitted on the
                # output stream so $ErrorActionPreference cannot turn it into
                # a terminating error, which Write-Error would under Pester.
                [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new("ERROR: [youtube] ${id}: This video is unavailable"),
                    'NativeCommandError', 'FromStdErr', $null)
                $global:LASTEXITCODE = 1
                continue
            }
            $formats = @(@{ vcodec = 'none'; acodec = 'opus' })
            foreach ($res in $global:YtxaFormats[$id]) {
                $formats += @{ vcodec = 'avc1'; width = [int](16 * $res / 9); height = $res }
            }
            @{ id = $id; formats = $formats } | ConvertTo-Json -Compress -Depth 5
        }
    }

    # Stand-in for the real qvcp: records its arguments and, unless the id is
    # in $YtxaQvcpFails, drops a file named the way yt-dlp would into -OutDir.
    # $YtxaQvcpNames maps an id to a different new file name, for the case
    # where the title or container changed upstream.
    function global:qvcp {
        $global:YtxaQvcpCalls += , ([string[]]$args)
        $i = [Array]::IndexOf([string[]]$args, '-OutDir')
        $dir = [string]$args[$i + 1]
        $url = [string]($args | Where-Object { $_ -like 'https://*' } | Select-Object -First 1)
        $id  = [regex]::Match($url, 'v=(?<id>[A-Za-z0-9_-]{11})').Groups['id'].Value
        if ($global:YtxaQvcpFails -contains $id) {
            throw "yt-dlp failed for '$url' (exit code 1)"
        }
        $name = if ($global:YtxaQvcpNames.ContainsKey($id)) { $global:YtxaQvcpNames[$id] } else { "new [$id].mp4" }
        Set-Content -LiteralPath (Join-Path $dir $name) -Value 'new' -NoNewline
    }

    function global:Reset-YtxaState {
        $global:YtxaProbeCalls = @()
        $global:YtxaYtDlpCalls = @()
        $global:YtxaQvcpCalls  = @()
        $global:YtxaQvcpFails  = @()
        $global:YtxaQvcpNames  = @{}
        $global:YtxaProbe      = @{}
        $global:YtxaFormats    = @{}
        $global:YtxaGated      = @()
        Get-ChildItem -LiteralPath $global:YtxaRoot -Force | Remove-Item -Recurse -Force
    }

    function global:New-YtxaFile {
        param([string]$RelativePath, [hashtable]$Tags = @{}, [int]$Width = 1920, [int]$Height = 1080)
        $full = Join-Path $global:YtxaRoot $RelativePath
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value '' -NoNewline
        $global:YtxaProbe[[System.IO.Path]::GetFileName($full)] = @{ Tags = $Tags; Width = $Width; Height = $Height }
        $full
    }

    function global:Get-YtxaUrls([string[]]$Arguments) {
        @($Arguments | Where-Object { $_ -like 'https://*' })
    }
}

AfterAll {
    foreach ($name in 'ffprobe', 'yt-dlp', 'qvcp', 'Reset-YtxaState', 'New-YtxaFile', 'Get-YtxaUrls') {
        Remove-Item -Path "function:$name" -ErrorAction SilentlyContinue
    }
    if ($global:YtxaRoot -and (Test-Path -LiteralPath $global:YtxaRoot)) {
        Remove-Item -LiteralPath $global:YtxaRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name YtxaRoot, YtxaProbeCalls, YtxaYtDlpCalls, YtxaQvcpCalls, YtxaQvcpFails, YtxaQvcpNames, YtxaProbe,
        YtxaFormats, YtxaGated, YtxaHasCookies -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ytxa file discovery' {

    BeforeEach { Reset-YtxaState }

    It 'finds bracketed ids in video files, recursively' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        New-YtxaFile 'deep/er/b [bbbbbbbbbbb].mkv' | Out-Null

        $rows = ytxa $global:YtxaRoot -NoResolutionCheck 6>$null

        @($rows).Count | Should -Be 2
        @($rows).Id | Should -Be @('aaaaaaaaaaa', 'bbbbbbbbbbb')
    }

    It 'ignores names without a bracketed id and non-video extensions' {
        New-YtxaFile 'no id here.mp4' | Out-Null
        New-YtxaFile 'bare id aaaaaaaaaaa.mp4' | Out-Null
        New-YtxaFile 'sidecar [aaaaaaaaaaa].jpg' | Out-Null
        New-YtxaFile 'wanted [ccccccccccc].webm' | Out-Null

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'ccccccccccc'
    }

    It 'defaults to the qvcp output root' {
        $saved = $env:QVCP_OUTPUT_ROOT
        try {
            $env:QVCP_OUTPUT_ROOT = $global:YtxaRoot
            New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null

            @(ytxa -NoResolutionCheck 6>$null).Count | Should -Be 1
        }
        finally {
            $env:QVCP_OUTPUT_ROOT = $saved
        }
    }

    It 'throws for a path that does not exist' {
        { ytxa (Join-Path $global:YtxaRoot 'nope') -NoResolutionCheck } |
            Should -Throw -ExpectedMessage '*Path not found*'
    }

    It 'accepts a single file, brackets and all' {
        $file = New-YtxaFile 'sub/one [aaaaaaaaaaa].mp4'
        New-YtxaFile 'sub/other [bbbbbbbbbbb].mp4' | Out-Null

        $rows = @(ytxa $file -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Path | Should -Be $file
    }

    It 'takes a named file as-is, whatever its extension' {
        $file = New-YtxaFile 'odd [aaaaaaaaaaa].ts'

        @(ytxa $file -NoResolutionCheck 6>$null).Count | Should -Be 1
    }

    It 'skips a named file that has no id, with a warning' {
        $file = New-YtxaFile 'no id.mp4'

        $rows = @(ytxa $file -NoResolutionCheck -WarningVariable w -WarningAction SilentlyContinue 6>$null)

        $rows.Count | Should -Be 0
        $w | Should -Match 'No \[id\]'
    }

    It 'matches a filespec recursively below its folder part' {
        New-YtxaFile 'top [aaaaaaaaaaa].mkv' | Out-Null
        New-YtxaFile 'deep/er/low [bbbbbbbbbbb].mkv' | Out-Null
        New-YtxaFile 'deep/not this [ccccccccccc].mp4' | Out-Null

        $rows = @(ytxa (Join-Path $global:YtxaRoot '*.mkv') -NoResolutionCheck 6>$null)

        $rows.Id | Should -Be @('bbbbbbbbbbb', 'aaaaaaaaaaa')
    }

    It 'applies the video-extension filter to filespec matches' {
        New-YtxaFile 'clip [aaaaaaaaaaa].mp4' | Out-Null
        New-YtxaFile 'clip [aaaaaaaaaaa].description' | Out-Null

        $rows = @(ytxa (Join-Path $global:YtxaRoot 'clip*') -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Path | Should -BeLike '*.mp4'
    }

    It 'warns, not throws, for a filespec that matches nothing' {
        $rows = @(ytxa (Join-Path $global:YtxaRoot '*.avi') -NoResolutionCheck -WarningVariable w -WarningAction SilentlyContinue 6>$null)

        $rows.Count | Should -Be 0
        $w | Should -Match 'Nothing matched'
    }

    It 'accepts several paths and reports each file once' {
        $file = New-YtxaFile 'one [aaaaaaaaaaa].mp4'
        New-YtxaFile 'sub/two [bbbbbbbbbbb].mkv' | Out-Null

        $rows = @(ytxa $file $global:YtxaRoot (Join-Path $global:YtxaRoot '*.mkv') -NoResolutionCheck 6>$null)

        $rows.Id | Should -Be @('aaaaaaaaaaa', 'bbbbbbbbbbb')
    }
}

Describe 'ytxa metadata checks' {

    BeforeEach { Reset-YtxaState }

    It 'reports the SourceURL comment as OK when it names the same id' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null

        $row = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)[0]

        $row.SourceUrlStatus | Should -Be 'OK'
        $row.SourceUrl       | Should -Be 'https://www.youtube.com/watch?v=aaaaaaaaaaa'
    }

    It 'accepts youtu.be short links in the comment' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://youtu.be/aaaaaaaaaaa]]' } | Out-Null

        @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)[0].SourceUrlStatus | Should -Be 'OK'
    }

    It 'reads the upper-case COMMENT tag that mkv uses' {
        New-YtxaFile 'a [aaaaaaaaaaa].mkv' -Tags @{ COMMENT = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null

        @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)[0].SourceUrlStatus | Should -Be 'OK'
    }

    It 'reports Missing when there is no sigil, even if a comment exists' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = 'https://www.youtube.com/watch?v=aaaaaaaaaaa' } | Out-Null
        New-YtxaFile 'b [bbbbbbbbbbb].mp4' -Tags @{ title = 'no comment at all' } | Out-Null

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)

        $rows.SourceUrlStatus | Should -Be @('Missing', 'Missing')
        foreach ($row in $rows) { $row.SourceUrl | Should -BeNullOrEmpty }
    }

    It 'reports Mismatch when the comment names a different video' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=zzzzzzzzzzz]]' } | Out-Null

        $row = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)[0]

        $row.SourceUrlStatus | Should -Be 'Mismatch'
        $row.SourceUrl       | Should -Be 'https://www.youtube.com/watch?v=zzzzzzzzzzz'
    }

    It 'measures resolution by the smaller dimension, like yt-dlp' {
        New-YtxaFile 'portrait [aaaaaaaaaaa].mp4' -Width 1080 -Height 1920 | Out-Null
        New-YtxaFile 'landscape [bbbbbbbbbbb].mp4' -Width 3840 -Height 2160 | Out-Null

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)

        $rows.Res | Should -Be @(2160, 1080)
    }

    It 'flags files ffprobe cannot read instead of aborting' {
        New-YtxaFile 'ok [aaaaaaaaaaa].mp4' | Out-Null
        $broken = Join-Path $global:YtxaRoot 'broken [bbbbbbbbbbb].mp4'
        Set-Content -LiteralPath $broken -Value '' -NoNewline   # not in the probe table

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 2
        $rows[0].ResStatus | Should -Be 'NoVideo'
        $rows[0].Note      | Should -Match 'ffprobe'
        $rows[1].ResStatus | Should -Be 'Skipped'
    }

    It '-MissingSourceUrl keeps only untagged files' {
        New-YtxaFile 'tagged [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null
        New-YtxaFile 'untagged [bbbbbbbbbbb].mp4' | Out-Null
        New-YtxaFile 'wrong [ccccccccccc].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=zzzzzzzzzzz]]' } | Out-Null

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck -MissingSourceUrl 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'bbbbbbbbbbb'
    }

    It '-NoResolutionCheck never invokes yt-dlp' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null

        $rows = @(ytxa $global:YtxaRoot -NoResolutionCheck 6>$null)

        $global:YtxaYtDlpCalls.Count | Should -Be 0
        $rows[0].ResStatus | Should -Be 'Skipped'
        $rows[0].BestRes   | Should -BeNullOrEmpty
    }
}

Describe 'ytxa resolution check' {

    BeforeEach { Reset-YtxaState }

    It 'queries without cookies by default, one watch URL per id, without downloading' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 360, 1080

        ytxa $global:YtxaRoot 6>$null | Out-Null

        $global:YtxaYtDlpCalls.Count | Should -Be 1
        $call = $global:YtxaYtDlpCalls[0]
        $call | Should -Contain '--ignore-config'
        $call | Should -Contain '--no-cookies'
        $call | Should -Contain '--no-cookies-from-browser'
        $call | Should -Contain '-j'
        $call | Should -Not -Contain '--cookies'
        Get-YtxaUrls $call | Should -Be @('https://www.youtube.com/watch?v=aaaaaaaaaaa')
    }

    It '-UseCookies passes the qvcp cookies file' -Skip:(-not $global:YtxaHasCookies) {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        ytxa $global:YtxaRoot -UseCookies 6>$null | Out-Null

        $call = $global:YtxaYtDlpCalls[0]
        $call | Should -Contain '--cookies'
        $call | Should -Not -Contain '--no-cookies'
    }

    It '-UseCookies throws when the cookies file is missing' -Skip:$global:YtxaHasCookies {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' | Out-Null

        { ytxa $global:YtxaRoot -UseCookies 6>$null } |
            Should -Throw -ExpectedMessage '*Cookies file not found*'
    }

    It 'marks a file Upgrade when YouTube offers more, OK when it does not' {
        New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1920 -Height 1080 | Out-Null
        New-YtxaFile 'best [bbbbbbbbbbb].mp4' -Width 3840 -Height 2160 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 360, 1080, 2160
        $global:YtxaFormats['bbbbbbbbbbb'] = 360, 1080, 2160

        $rows = @(ytxa $global:YtxaRoot 6>$null)

        $rows[0].ResStatus | Should -Be 'OK'
        $rows[0].BestRes   | Should -Be 2160
        $rows[1].ResStatus | Should -Be 'Upgrade'
        $rows[1].BestRes   | Should -Be 2160
    }

    It 'ignores audio-only formats when finding the best resolution' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Width 1920 -Height 1080 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = @(1080)   # plus the stub's audio-only entry

        @(ytxa $global:YtxaRoot 6>$null)[0].ResStatus | Should -Be 'OK'
    }

    It 'checks untagged files by their filename id' {
        New-YtxaFile 'untagged [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        $row = @(ytxa $global:YtxaRoot -MissingSourceUrl 6>$null)[0]

        Get-YtxaUrls $global:YtxaYtDlpCalls[0] | Should -Be @('https://www.youtube.com/watch?v=aaaaaaaaaaa')
        $row.ResStatus | Should -Be 'Upgrade'
    }

    It 'records the yt-dlp reason for an id it cannot resolve, and keeps going' {
        New-YtxaFile 'gone [aaaaaaaaaaa].mp4' | Out-Null
        New-YtxaFile 'fine [bbbbbbbbbbb].mp4' | Out-Null
        $global:YtxaFormats['bbbbbbbbbbb'] = 1080

        $rows = @(ytxa $global:YtxaRoot 6>$null)

        $rows[0].ResStatus | Should -Be 'OK'
        $rows[1].ResStatus | Should -Be 'Unavailable'
        $rows[1].Note      | Should -Be 'This video is unavailable'
        $rows[1].BestRes   | Should -BeNullOrEmpty
    }

    It 'splits the ids into batches of -BatchSize' {
        foreach ($id in 'aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd', 'eeeeeeeeeee') {
            New-YtxaFile "$id [$id].mp4" | Out-Null
            $global:YtxaFormats[$id] = 1080
        }

        ytxa $global:YtxaRoot -BatchSize 2 6>$null | Out-Null

        $global:YtxaYtDlpCalls.Count | Should -Be 3
        (Get-YtxaUrls $global:YtxaYtDlpCalls[0]).Count | Should -Be 2
        (Get-YtxaUrls $global:YtxaYtDlpCalls[2]).Count | Should -Be 1
    }

    It 'queries a duplicated id once and fills in every copy' {
        New-YtxaFile 'one/dupe [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        New-YtxaFile 'two/dupe [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        $rows = @(ytxa $global:YtxaRoot 6>$null)

        $global:YtxaYtDlpCalls.Count | Should -Be 1
        (Get-YtxaUrls $global:YtxaYtDlpCalls[0]).Count | Should -Be 1
        $rows.ResStatus | Should -Be @('Upgrade', 'Upgrade')
    }

    It 'retries ids that need a sign-in with cookies, and only those' -Skip:(-not $global:YtxaHasCookies) {
        New-YtxaFile 'gated [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        New-YtxaFile 'open [bbbbbbbbbbb].mp4' -Width 1920 -Height 1080 | Out-Null
        New-YtxaFile 'gone [ccccccccccc].mp4' | Out-Null
        $global:YtxaGated = @('aaaaaaaaaaa')
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaFormats['bbbbbbbbbbb'] = 1080

        $rows = @(ytxa $global:YtxaRoot 6>$null)

        $global:YtxaYtDlpCalls.Count | Should -Be 2
        $global:YtxaYtDlpCalls[0] | Should -Contain '--no-cookies'
        $global:YtxaYtDlpCalls[1] | Should -Contain '--cookies'
        Get-YtxaUrls $global:YtxaYtDlpCalls[1] | Should -Be @('https://www.youtube.com/watch?v=aaaaaaaaaaa')

        $rows[0].ResStatus | Should -Be 'Upgrade'          # gated, resolved on retry
        $rows[0].Note      | Should -Match 'cookies'
        $rows[1].ResStatus | Should -Be 'Unavailable'      # gone: not a sign-in problem
        $rows[1].Note      | Should -Be 'This video is unavailable'
        $rows[2].ResStatus | Should -Be 'OK'               # open: first pass, no note
        $rows[2].Note      | Should -BeNullOrEmpty
    }

    It 'does not retry when nothing needed a sign-in' -Skip:(-not $global:YtxaHasCookies) {
        New-YtxaFile 'gone [aaaaaaaaaaa].mp4' | Out-Null

        ytxa $global:YtxaRoot 6>$null | Out-Null

        $global:YtxaYtDlpCalls.Count | Should -Be 1
    }

    It '-UseCookies queries everything with cookies in a single pass' -Skip:(-not $global:YtxaHasCookies) {
        New-YtxaFile 'gated [aaaaaaaaaaa].mp4' | Out-Null
        $global:YtxaGated = @('aaaaaaaaaaa')
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        $rows = @(ytxa $global:YtxaRoot -UseCookies 6>$null)

        $global:YtxaYtDlpCalls.Count | Should -Be 1
        $rows[0].ResStatus | Should -Be 'OK'
    }

    It 'leaves sign-in failures Unavailable when there is no cookies file' -Skip:$global:YtxaHasCookies {
        New-YtxaFile 'gated [aaaaaaaaaaa].mp4' | Out-Null
        $global:YtxaGated = @('aaaaaaaaaaa')
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        $rows = @(ytxa $global:YtxaRoot 6>$null)

        $global:YtxaYtDlpCalls.Count | Should -Be 1
        $rows[0].ResStatus | Should -Be 'Unavailable'
        $rows[0].Note      | Should -Match 'Sign in'
    }

    It 'does not query files ffprobe could not read' {
        $broken = Join-Path $global:YtxaRoot 'broken [aaaaaaaaaaa].mp4'
        Set-Content -LiteralPath $broken -Value '' -NoNewline

        ytxa $global:YtxaRoot 6>$null | Out-Null

        $global:YtxaYtDlpCalls.Count | Should -Be 0
    }
}

Describe 'ytxa -Upgrade' {

    BeforeEach { Reset-YtxaState }

    It 'refuses -NoResolutionCheck' {
        { ytxa $global:YtxaRoot -Upgrade -NoResolutionCheck 6>$null } |
            Should -Throw -ExpectedMessage '*-Upgrade needs the resolution check*'
    }

    It 'refuses to run without qvcp loaded' {
        # Remove-Item ignores a scope qualifier on the function: drive
        # ('function:global:qvcp' removes nothing), while Set-Item honours it.
        $saved = Get-Item function:qvcp
        Remove-Item function:qvcp
        try {
            { ytxa $global:YtxaRoot -Upgrade 6>$null } |
                Should -Throw -ExpectedMessage '*qvcp*not loaded*'
        }
        finally {
            Set-Item function:global:qvcp $saved.ScriptBlock
        }
    }

    It 're-downloads only the Upgrade rows, each into its own folder' {
        $low  = New-YtxaFile 'one/low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720
        $best = New-YtxaFile 'two/best [bbbbbbbbbbb].mp4' -Width 3840 -Height 2160
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaFormats['bbbbbbbbbbb'] = 2160

        $rows = @(ytxa $global:YtxaRoot -Upgrade 6>$null)

        $global:YtxaQvcpCalls.Count | Should -Be 1
        $call = $global:YtxaQvcpCalls[0]
        $call | Should -Contain 'https://www.youtube.com/watch?v=aaaaaaaaaaa'
        $call[[Array]::IndexOf($call, '-OutDir') + 1] | Should -Be (Split-Path $low)
        $rows[0].UpgradeStatus | Should -Be 'Upgraded'
        $rows[1].UpgradeStatus | Should -BeNullOrEmpty
        Test-Path -LiteralPath $best | Should -BeTrue
    }

    It 'uses -Y when the cookies file exists' -Skip:(-not $global:YtxaHasCookies) {
        New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        ytxa $global:YtxaRoot -Upgrade 6>$null | Out-Null

        $global:YtxaQvcpCalls[0] | Should -Contain '-Y'
    }

    It 'falls back to -G when there is no cookies file' -Skip:$global:YtxaHasCookies {
        New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        ytxa $global:YtxaRoot -Upgrade 6>$null | Out-Null

        $global:YtxaQvcpCalls[0] | Should -Contain '-G'
    }

    It 'removes the old file only after the new one is in place, and reports the new path' {
        $old = New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080

        $row = @(ytxa $global:YtxaRoot -Upgrade 6>$null)[0]

        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath "$old.ytxa-old" | Should -BeFalse
        $row.NewPath | Should -Be (Join-Path (Split-Path $old) 'new [aaaaaaaaaaa].mp4')
        Test-Path -LiteralPath $row.NewPath | Should -BeTrue
    }

    It 'keeps the old file when the download fails, and marks the row Failed' {
        $old = New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaQvcpFails = @('aaaaaaaaaaa')

        $row = @(ytxa $global:YtxaRoot -Upgrade -WarningAction SilentlyContinue 6>$null)[0]

        $row.UpgradeStatus | Should -Be 'Failed'
        $row.Note          | Should -Match 'exit code 1'
        $row.NewPath       | Should -BeNullOrEmpty
        Test-Path -LiteralPath $old | Should -BeTrue
        (Get-Item -LiteralPath $old).Length | Should -Be 0   # the original placeholder, not the stub's 'new'
        Test-Path -LiteralPath "$old.ytxa-old" | Should -BeFalse
    }

    It 'treats a download that produced no file with the id as a failure' {
        $old = New-YtxaFile 'low [aaaaaaaaaaa].mp4' -Width 1280 -Height 720
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaQvcpNames['aaaaaaaaaaa'] = 'wrong [zzzzzzzzzzz].mp4'

        $row = @(ytxa $global:YtxaRoot -Upgrade -WarningAction SilentlyContinue 6>$null)[0]

        $row.UpgradeStatus | Should -Be 'Failed'
        $row.Note          | Should -Match 'no new file'
        Test-Path -LiteralPath $old | Should -BeTrue
    }

    It 'finds the replacement even when its title and container changed' {
        $old = New-YtxaFile 'old title [aaaaaaaaaaa].mp4' -Width 1280 -Height 720
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaQvcpNames['aaaaaaaaaaa'] = 'renamed title [aaaaaaaaaaa].mkv'

        $row = @(ytxa $global:YtxaRoot -Upgrade 6>$null)[0]

        $row.UpgradeStatus | Should -Be 'Upgraded'
        $row.NewPath       | Should -BeLike '*renamed title [[]aaaaaaaaaaa[]].mkv'
        Test-Path -LiteralPath $old | Should -BeFalse
    }

    It 'continues with the next file after a failure' {
        New-YtxaFile 'a [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        New-YtxaFile 'b [bbbbbbbbbbb].mp4' -Width 1280 -Height 720 | Out-Null
        $global:YtxaFormats['aaaaaaaaaaa'] = 1080
        $global:YtxaFormats['bbbbbbbbbbb'] = 1080
        $global:YtxaQvcpFails = @('aaaaaaaaaaa')

        $rows = @(ytxa $global:YtxaRoot -Upgrade -WarningAction SilentlyContinue 6>$null)

        $rows.UpgradeStatus | Should -Be @('Failed', 'Upgraded')
        $global:YtxaQvcpCalls.Count | Should -Be 2
    }
}
