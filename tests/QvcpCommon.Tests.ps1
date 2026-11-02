#Requires -Version 7.0

# Tests for QvcpCommon.psm1, the helpers qvcp.ps1 and ytxa.ps1 share. The
# behaviour of each caller is covered by its own suite; this one pins down the
# parsing rules both depend on.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'QvcpCommon.psm1') -Force

    $global:QvcpCommonRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qvcpcommon-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:QvcpCommonRoot -Force | Out-Null

    # Answers from a table of comments keyed by leaf name; a file absent from
    # the table is unreadable (exit 1).
    function global:ffprobe {
        $global:QvcpCommonProbeCalls += , ([string[]]$args)
        $leaf = [System.IO.Path]::GetFileName([string]$args[-1])
        if (-not $global:QvcpCommonComments.ContainsKey($leaf)) {
            $global:LASTEXITCODE = 1
            return
        }
        $tags = @{}
        if ($null -ne $global:QvcpCommonComments[$leaf]) { $tags.COMMENT = $global:QvcpCommonComments[$leaf] }
        @{ format = @{ tags = $tags } } | ConvertTo-Json -Depth 5
        $global:LASTEXITCODE = 0
    }
}

AfterAll {
    Remove-Item -Path 'function:ffprobe' -ErrorAction SilentlyContinue
    if ($global:QvcpCommonRoot -and (Test-Path -LiteralPath $global:QvcpCommonRoot)) {
        Remove-Item -LiteralPath $global:QvcpCommonRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name QvcpCommonRoot, QvcpCommonComments, QvcpCommonProbeCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'QvcpCommon paths' {
    BeforeEach { $saved = $env:QVCP_OUTPUT_ROOT }
    AfterEach  { $env:QVCP_OUTPUT_ROOT = $saved }

    It 'defaults the output root to X:\in\clips' {
        $env:QVCP_OUTPUT_ROOT = ''
        Get-QvcpOutputRoot | Should -Be 'X:\in\clips'
    }

    It 'takes the output root from QVCP_OUTPUT_ROOT' {
        $env:QVCP_OUTPUT_ROOT = 'D:\elsewhere'
        Get-QvcpOutputRoot | Should -Be 'D:\elsewhere'
    }

    It 'puts the cookies file in Documents' {
        Get-QvcpCookiesPath | Should -Be (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'cookies.firefox-private.txt')
    }
}

Describe 'QvcpCommon id matching' {
    It 'recognises YouTube hosts, case-insensitively' -TestCases @(
        @{ Url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' }
        @{ Url = 'https://YOUTU.BE/dQw4w9WgXcQ' }
        @{ Url = 'https://music.youtube.com/watch?v=dQw4w9WgXcQ' }
        @{ Url = 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ' }
    ) {
        Test-QvcpYouTubeUrl $Url | Should -BeTrue
    }

    It 'rejects other hosts and non-URLs' -TestCases @(
        @{ Url = 'https://example.com/watch?v=dQw4w9WgXcQ' }
        @{ Url = 'https://notyoutube.com/watch?v=dQw4w9WgXcQ' }
        @{ Url = 'dQw4w9WgXcQ' }
    ) {
        Test-QvcpYouTubeUrl $Url | Should -BeFalse
    }

    It 'reads the id from every URL shape' -TestCases @(
        @{ Url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' }
        @{ Url = 'https://www.youtube.com/watch?list=x&v=dQw4w9WgXcQ' }
        @{ Url = 'https://youtu.be/dQw4w9WgXcQ?t=5' }
        @{ Url = 'https://www.youtube.com/shorts/dQw4w9WgXcQ' }
        @{ Url = 'https://www.youtube.com/embed/dQw4w9WgXcQ' }
        @{ Url = 'https://www.youtube.com/live/dQw4w9WgXcQ' }
    ) {
        Get-QvcpUrlId $Url | Should -BeExactly 'dQw4w9WgXcQ'
    }

    It 'returns nothing for a URL without an id' {
        Get-QvcpUrlId 'https://www.youtube.com/' | Should -BeNullOrEmpty
    }

    It 'reads only a bracketed id at the end of a name' {
        Get-QvcpNameId 'Some Clip [dQw4w9WgXcQ]'        | Should -BeExactly 'dQw4w9WgXcQ'
        Get-QvcpNameId 'dQw4w9WgXcQ plain title'        | Should -BeNullOrEmpty
        Get-QvcpNameId 'Clip [dQw4w9WgXcQ] (1)'         | Should -BeNullOrEmpty
        Get-QvcpNameId 'Clip [short]'                   | Should -BeNullOrEmpty
    }

    It 'knows the video extensions, case-insensitively' {
        Test-QvcpVideoFile ([System.IO.FileInfo]'a.MKV')           | Should -BeTrue
        Test-QvcpVideoFile ([System.IO.FileInfo]'a.mp4.ytxa-old')  | Should -BeFalse
        Test-QvcpVideoFile ([System.IO.FileInfo]'a.description')   | Should -BeFalse
    }
}

Describe 'QvcpCommon SourceURL sigil' {
    It 'formats the sigil around any URL, including a yt-dlp template' {
        Format-QvcpSourceSigil 'https://youtu.be/dQw4w9WgXcQ' | Should -BeExactly '[[SourceURL|https://youtu.be/dQw4w9WgXcQ]]'
        Format-QvcpSourceSigil '%(webpage_url)s'              | Should -BeExactly '[[SourceURL|%(webpage_url)s]]'
    }

    It 'round-trips a URL through the sigil, with text around it' {
        $comment = "before`n" + (Format-QvcpSourceSigil 'https://www.youtube.com/watch?v=dQw4w9WgXcQ') + "`nafter"
        Get-QvcpSourceUrl $comment | Should -BeExactly 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
    }

    It 'returns nothing for a comment without the sigil' {
        Get-QvcpSourceUrl 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' | Should -BeNullOrEmpty
        Get-QvcpSourceUrl $null | Should -BeNullOrEmpty
    }

    It 'accepts a comment only when the sigil names the same id, case-sensitively' {
        Test-QvcpSourceComment '[[SourceURL|https://youtu.be/dQw4w9WgXcQ]]' 'dQw4w9WgXcQ' | Should -BeTrue
        Test-QvcpSourceComment '[[SourceURL|https://youtu.be/dQw4w9WgXcQ]]' 'DQW4W9WGXCQ' | Should -BeFalse
        Test-QvcpSourceComment '[[SourceURL|https://youtu.be/aaaaaaaaaaa]]' 'dQw4w9WgXcQ' | Should -BeFalse
        Test-QvcpSourceComment 'no sigil' 'dQw4w9WgXcQ' | Should -BeFalse
        Test-QvcpSourceComment $null 'dQw4w9WgXcQ' | Should -BeFalse
    }

    It 'reads the comment tag whatever its case' {
        Get-QvcpCommentTag ([pscustomobject]@{ title = 't'; COMMENT = 'upper' }) | Should -BeExactly 'upper'
        Get-QvcpCommentTag ([pscustomobject]@{ comment = 'lower' })              | Should -BeExactly 'lower'
        Get-QvcpCommentTag ([pscustomobject]@{ title = 't' })                    | Should -BeNullOrEmpty
        Get-QvcpCommentTag $null                                                 | Should -BeNullOrEmpty
    }
}

Describe 'QvcpCommon files on disk' {
    BeforeEach {
        $global:QvcpCommonComments   = @{}
        $global:QvcpCommonProbeCalls = @()
        Get-ChildItem -LiteralPath $global:QvcpCommonRoot -File | Remove-Item -Force
    }

    It 'reads a comment with ffprobe, passing the file after -i' {
        $global:QvcpCommonComments['-dash.mp4'] = 'hello'
        $path = Join-Path $global:QvcpCommonRoot '-dash.mp4'

        Read-QvcpComment $path | Should -BeExactly 'hello'
        $call = $global:QvcpCommonProbeCalls[0]
        $call[-2] | Should -Be '-i'
        $call[-1] | Should -Be $path
    }

    It 'returns nothing when ffprobe cannot read the file' {
        Read-QvcpComment (Join-Path $global:QvcpCommonRoot 'missing.mp4') | Should -BeNullOrEmpty
    }

    It 'finds the video files for an id, newest first, and nothing else' {
        $root = $global:QvcpCommonRoot
        $old  = New-Item -ItemType File -Path (Join-Path $root 'Old [dQw4w9WgXcQ].mp4')
        $new  = New-Item -ItemType File -Path (Join-Path $root 'New [dQw4w9WgXcQ].webm')
        $old.LastWriteTime = (Get-Date).AddDays(-1)
        New-Item -ItemType File -Path (Join-Path $root 'Clip [dQw4w9WgXcQ].mp4.ytxa-old') | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'Clip [dQw4w9WgXcQ].description') | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'Other [aaaaaaaaaaa].mp4') | Out-Null

        $found = Find-QvcpDownload $root 'dQw4w9WgXcQ'
        $found.Name | Should -Be @('New [dQw4w9WgXcQ].webm', 'Old [dQw4w9WgXcQ].mp4')
    }

    It 'returns an empty list for a folder that does not exist' {
        @(Find-QvcpDownload (Join-Path $global:QvcpCommonRoot 'nope') 'dQw4w9WgXcQ').Count | Should -Be 0
    }
}
