#Requires -Version 7.0

# Tests for the `qvcp-audit` PowerShell helper.
#
# `ffprobe` and `yt-dlp` are replaced with global stub functions, as in
# qvcp.Tests.ps1. The ffprobe stub answers from a per-file table of tags and
# dimensions; the yt-dlp stub answers from a per-id table of available
# resolutions and reports unknown ids the way yt-dlp does, on stderr. The
# files under test are empty placeholders in a temp tree.

BeforeDiscovery {
    $global:QvcpAuditHasCookies = Test-Path -LiteralPath (
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'cookies.firefox-private.txt'
    ) -PathType Leaf
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'qvcp-audit.ps1')

    $global:QvcpAuditRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qvcp-audit-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:QvcpAuditRoot -Force | Out-Null

    # Probe table: leaf file name -> @{ Tags = @{...}; Width = ; Height = }.
    # A file absent from the table is reported as unreadable (ffprobe exit 1).
    function global:ffprobe {
        $global:QvcpAuditProbeCalls += , ([string[]]$args)
        $file = [System.IO.Path]::GetFileName([string]$args[-1])
        $entry = $global:QvcpAuditProbe[$file]
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
    function global:yt-dlp {
        $global:QvcpAuditYtDlpCalls += , ([string[]]$args)
        $global:LASTEXITCODE = 0
        foreach ($a in $args) {
            if ($a -notmatch 'watch\?v=(?<id>[A-Za-z0-9_-]{11})$') { continue }
            $id = $Matches['id']
            if (-not $global:QvcpAuditFormats.ContainsKey($id)) {
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
            foreach ($res in $global:QvcpAuditFormats[$id]) {
                $formats += @{ vcodec = 'avc1'; width = [int](16 * $res / 9); height = $res }
            }
            @{ id = $id; formats = $formats } | ConvertTo-Json -Compress -Depth 5
        }
    }

    function global:Reset-QvcpAuditState {
        $global:QvcpAuditProbeCalls = @()
        $global:QvcpAuditYtDlpCalls = @()
        $global:QvcpAuditProbe      = @{}
        $global:QvcpAuditFormats    = @{}
        Get-ChildItem -LiteralPath $global:QvcpAuditRoot -Force | Remove-Item -Recurse -Force
    }

    function global:New-QvcpAuditFile {
        param([string]$RelativePath, [hashtable]$Tags = @{}, [int]$Width = 1920, [int]$Height = 1080)
        $full = Join-Path $global:QvcpAuditRoot $RelativePath
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value '' -NoNewline
        $global:QvcpAuditProbe[[System.IO.Path]::GetFileName($full)] = @{ Tags = $Tags; Width = $Width; Height = $Height }
        $full
    }

    function global:Get-QvcpAuditUrls([string[]]$Arguments) {
        @($Arguments | Where-Object { $_ -like 'https://*' })
    }
}

AfterAll {
    foreach ($name in 'ffprobe', 'yt-dlp', 'Reset-QvcpAuditState', 'New-QvcpAuditFile', 'Get-QvcpAuditUrls') {
        Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
    }
    if ($global:QvcpAuditRoot -and (Test-Path -LiteralPath $global:QvcpAuditRoot)) {
        Remove-Item -LiteralPath $global:QvcpAuditRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name QvcpAuditRoot, QvcpAuditProbeCalls, QvcpAuditYtDlpCalls, QvcpAuditProbe,
        QvcpAuditFormats, QvcpAuditHasCookies -Scope Global -ErrorAction SilentlyContinue
}

Describe 'qvcp-audit file discovery' {

    BeforeEach { Reset-QvcpAuditState }

    It 'finds bracketed ids in video files, recursively' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        New-QvcpAuditFile 'deep/er/b [bbbbbbbbbbb].mkv' | Out-Null

        $rows = qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null

        @($rows).Count | Should -Be 2
        @($rows).Id | Should -Be @('aaaaaaaaaaa', 'bbbbbbbbbbb')
    }

    It 'ignores names without a bracketed id and non-video extensions' {
        New-QvcpAuditFile 'no id here.mp4' | Out-Null
        New-QvcpAuditFile 'bare id aaaaaaaaaaa.mp4' | Out-Null
        New-QvcpAuditFile 'sidecar [aaaaaaaaaaa].jpg' | Out-Null
        New-QvcpAuditFile 'wanted [ccccccccccc].webm' | Out-Null

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'ccccccccccc'
    }

    It 'defaults to the qvcp output root' {
        $saved = $env:QVCP_OUTPUT_ROOT
        try {
            $env:QVCP_OUTPUT_ROOT = $global:QvcpAuditRoot
            New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null

            @(qvcp-audit -NoResolutionCheck 6>$null).Count | Should -Be 1
        }
        finally {
            $env:QVCP_OUTPUT_ROOT = $saved
        }
    }

    It 'throws for a folder that does not exist' {
        { qvcp-audit (Join-Path $global:QvcpAuditRoot 'nope') -NoResolutionCheck } |
            Should -Throw -ExpectedMessage '*Folder not found*'
    }
}

Describe 'qvcp-audit metadata checks' {

    BeforeEach { Reset-QvcpAuditState }

    It 'reports the SourceURL comment as OK when it names the same id' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null

        $row = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)[0]

        $row.SourceUrlStatus | Should -Be 'OK'
        $row.SourceUrl       | Should -Be 'https://www.youtube.com/watch?v=aaaaaaaaaaa'
    }

    It 'accepts youtu.be short links in the comment' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://youtu.be/aaaaaaaaaaa]]' } | Out-Null

        @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)[0].SourceUrlStatus | Should -Be 'OK'
    }

    It 'reads the upper-case COMMENT tag that mkv uses' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mkv' -Tags @{ COMMENT = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null

        @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)[0].SourceUrlStatus | Should -Be 'OK'
    }

    It 'reports Missing when there is no sigil, even if a comment exists' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = 'https://www.youtube.com/watch?v=aaaaaaaaaaa' } | Out-Null
        New-QvcpAuditFile 'b [bbbbbbbbbbb].mp4' -Tags @{ title = 'no comment at all' } | Out-Null

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)

        $rows.SourceUrlStatus | Should -Be @('Missing', 'Missing')
        foreach ($row in $rows) { $row.SourceUrl | Should -BeNullOrEmpty }
    }

    It 'reports Mismatch when the comment names a different video' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=zzzzzzzzzzz]]' } | Out-Null

        $row = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)[0]

        $row.SourceUrlStatus | Should -Be 'Mismatch'
        $row.SourceUrl       | Should -Be 'https://www.youtube.com/watch?v=zzzzzzzzzzz'
    }

    It 'measures resolution by the smaller dimension, like yt-dlp' {
        New-QvcpAuditFile 'portrait [aaaaaaaaaaa].mp4' -Width 1080 -Height 1920 | Out-Null
        New-QvcpAuditFile 'landscape [bbbbbbbbbbb].mp4' -Width 3840 -Height 2160 | Out-Null

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)

        $rows.Res | Should -Be @(2160, 1080)
    }

    It 'flags files ffprobe cannot read instead of aborting' {
        New-QvcpAuditFile 'ok [aaaaaaaaaaa].mp4' | Out-Null
        $broken = Join-Path $global:QvcpAuditRoot 'broken [bbbbbbbbbbb].mp4'
        Set-Content -LiteralPath $broken -Value '' -NoNewline   # not in the probe table

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)

        $rows.Count | Should -Be 2
        $rows[0].ResStatus | Should -Be 'NoVideo'
        $rows[0].Note      | Should -Match 'ffprobe'
        $rows[1].ResStatus | Should -Be 'Skipped'
    }

    It '-MissingSourceUrl keeps only untagged files' {
        New-QvcpAuditFile 'tagged [aaaaaaaaaaa].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]' } | Out-Null
        New-QvcpAuditFile 'untagged [bbbbbbbbbbb].mp4' | Out-Null
        New-QvcpAuditFile 'wrong [ccccccccccc].mp4' -Tags @{ comment = '[[SourceURL|https://www.youtube.com/watch?v=zzzzzzzzzzz]]' } | Out-Null

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck -MissingSourceUrl 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'bbbbbbbbbbb'
    }

    It '-NoResolutionCheck never invokes yt-dlp' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null

        $rows = @(qvcp-audit $global:QvcpAuditRoot -NoResolutionCheck 6>$null)

        $global:QvcpAuditYtDlpCalls.Count | Should -Be 0
        $rows[0].ResStatus | Should -Be 'Skipped'
        $rows[0].BestRes   | Should -BeNullOrEmpty
    }
}

Describe 'qvcp-audit resolution check' {

    BeforeEach { Reset-QvcpAuditState }

    It 'queries without cookies by default, one watch URL per id, without downloading' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = 360, 1080

        qvcp-audit $global:QvcpAuditRoot 6>$null | Out-Null

        $global:QvcpAuditYtDlpCalls.Count | Should -Be 1
        $call = $global:QvcpAuditYtDlpCalls[0]
        $call | Should -Contain '--ignore-config'
        $call | Should -Contain '--no-cookies'
        $call | Should -Contain '--no-cookies-from-browser'
        $call | Should -Contain '-j'
        $call | Should -Not -Contain '--cookies'
        Get-QvcpAuditUrls $call | Should -Be @('https://www.youtube.com/watch?v=aaaaaaaaaaa')
    }

    It '-UseCookies passes the qvcp cookies file' -Skip:(-not $global:QvcpAuditHasCookies) {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = 1080

        qvcp-audit $global:QvcpAuditRoot -UseCookies 6>$null | Out-Null

        $call = $global:QvcpAuditYtDlpCalls[0]
        $call | Should -Contain '--cookies'
        $call | Should -Not -Contain '--no-cookies'
    }

    It '-UseCookies throws when the cookies file is missing' -Skip:$global:QvcpAuditHasCookies {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' | Out-Null

        { qvcp-audit $global:QvcpAuditRoot -UseCookies 6>$null } |
            Should -Throw -ExpectedMessage '*Cookies file not found*'
    }

    It 'marks a file Upgrade when YouTube offers more, OK when it does not' {
        New-QvcpAuditFile 'low [aaaaaaaaaaa].mp4' -Width 1920 -Height 1080 | Out-Null
        New-QvcpAuditFile 'best [bbbbbbbbbbb].mp4' -Width 3840 -Height 2160 | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = 360, 1080, 2160
        $global:QvcpAuditFormats['bbbbbbbbbbb'] = 360, 1080, 2160

        $rows = @(qvcp-audit $global:QvcpAuditRoot 6>$null)

        $rows[0].ResStatus | Should -Be 'OK'
        $rows[0].BestRes   | Should -Be 2160
        $rows[1].ResStatus | Should -Be 'Upgrade'
        $rows[1].BestRes   | Should -Be 2160
    }

    It 'ignores audio-only formats when finding the best resolution' {
        New-QvcpAuditFile 'a [aaaaaaaaaaa].mp4' -Width 1920 -Height 1080 | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = @(1080)   # plus the stub's audio-only entry

        @(qvcp-audit $global:QvcpAuditRoot 6>$null)[0].ResStatus | Should -Be 'OK'
    }

    It 'checks untagged files by their filename id' {
        New-QvcpAuditFile 'untagged [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = 1080

        $row = @(qvcp-audit $global:QvcpAuditRoot -MissingSourceUrl 6>$null)[0]

        Get-QvcpAuditUrls $global:QvcpAuditYtDlpCalls[0] | Should -Be @('https://www.youtube.com/watch?v=aaaaaaaaaaa')
        $row.ResStatus | Should -Be 'Upgrade'
    }

    It 'records the yt-dlp reason for an id it cannot resolve, and keeps going' {
        New-QvcpAuditFile 'gone [aaaaaaaaaaa].mp4' | Out-Null
        New-QvcpAuditFile 'fine [bbbbbbbbbbb].mp4' | Out-Null
        $global:QvcpAuditFormats['bbbbbbbbbbb'] = 1080

        $rows = @(qvcp-audit $global:QvcpAuditRoot 6>$null)

        $rows[0].ResStatus | Should -Be 'OK'
        $rows[1].ResStatus | Should -Be 'Unavailable'
        $rows[1].Note      | Should -Be 'This video is unavailable'
        $rows[1].BestRes   | Should -BeNullOrEmpty
    }

    It 'splits the ids into batches of -BatchSize' {
        foreach ($id in 'aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd', 'eeeeeeeeeee') {
            New-QvcpAuditFile "$id [$id].mp4" | Out-Null
            $global:QvcpAuditFormats[$id] = 1080
        }

        qvcp-audit $global:QvcpAuditRoot -BatchSize 2 6>$null | Out-Null

        $global:QvcpAuditYtDlpCalls.Count | Should -Be 3
        (Get-QvcpAuditUrls $global:QvcpAuditYtDlpCalls[0]).Count | Should -Be 2
        (Get-QvcpAuditUrls $global:QvcpAuditYtDlpCalls[2]).Count | Should -Be 1
    }

    It 'queries a duplicated id once and fills in every copy' {
        New-QvcpAuditFile 'one/dupe [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        New-QvcpAuditFile 'two/dupe [aaaaaaaaaaa].mp4' -Width 1280 -Height 720 | Out-Null
        $global:QvcpAuditFormats['aaaaaaaaaaa'] = 1080

        $rows = @(qvcp-audit $global:QvcpAuditRoot 6>$null)

        $global:QvcpAuditYtDlpCalls.Count | Should -Be 1
        (Get-QvcpAuditUrls $global:QvcpAuditYtDlpCalls[0]).Count | Should -Be 1
        $rows.ResStatus | Should -Be @('Upgrade', 'Upgrade')
    }

    It 'does not query files ffprobe could not read' {
        $broken = Join-Path $global:QvcpAuditRoot 'broken [aaaaaaaaaaa].mp4'
        Set-Content -LiteralPath $broken -Value '' -NoNewline

        qvcp-audit $global:QvcpAuditRoot 6>$null | Out-Null

        $global:QvcpAuditYtDlpCalls.Count | Should -Be 0
    }
}
