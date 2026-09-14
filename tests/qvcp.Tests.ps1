#Requires -Version 7.0

# Tests for the `qvcp` PowerShell helper.
#
# `yt-dlp` and `ffmpeg` are replaced with global stub *functions* for the duration
# of the run. PowerShell resolves functions ahead of applications, so `& yt-dlp`
# inside qvcp hits the stub, which records the argument list instead of
# downloading anything. `$env:QVCP_OUTPUT_ROOT` redirects the dated output folder
# into a temp directory so the real `X:\in\clips` is never touched.

BeforeDiscovery {
    # -Skip: is evaluated during discovery, before BeforeAll runs, so anything a
    # skip condition depends on has to be probed here.
    $global:QvcpTestHasCookies = Test-Path -LiteralPath (
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'cookies.firefox-private.txt'
    ) -PathType Leaf

    $global:QvcpTestCanSetTitle = $false
    try {
        $probe = $Host.UI.RawUI.WindowTitle
        $Host.UI.RawUI.WindowTitle = 'qvcp-title-probe'
        $global:QvcpTestCanSetTitle = ($Host.UI.RawUI.WindowTitle -eq 'qvcp-title-probe')
        $Host.UI.RawUI.WindowTitle = $probe
    }
    catch {
        $global:QvcpTestCanSetTitle = $false
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'qvcp.ps1')

    $global:QvcpTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qvcp-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:QvcpTestRoot -Force | Out-Null

    $global:QvcpTestOriginalOutputRoot = $env:QVCP_OUTPUT_ROOT
    $env:QVCP_OUTPUT_ROOT = $global:QvcpTestRoot

    $global:QvcpTestCookiesPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'cookies.firefox-private.txt'

    # Recomputed per call rather than fixed at suite start: qvcp derives the
    # month folder per invocation, so a cached value would go stale if a run
    # straddled a month boundary.
    function global:Get-QvcpMonthFolder {
        Join-Path $global:QvcpTestRoot ('{0:yyyy-MM}' -f (Get-Date))
    }

    # Both stubs record their arguments and the window title as it stood at the
    # moment of the call, which is the only point where the title is observable.
    # $QvcpTestExitCode may be a single value or one per call; the last entry
    # is reused once the calls outnumber it.
    function global:Get-QvcpStubExitCode {
        $codes = @($global:QvcpTestExitCode)
        $codes[[Math]::Min($global:QvcpTestCalls.Count - 1, $codes.Count - 1)]
    }

    function global:yt-dlp {
        $global:QvcpTestCalls  += , ([string[]]$args)
        $global:QvcpTestTitles += $Host.UI.RawUI.WindowTitle
        $global:LASTEXITCODE = Get-QvcpStubExitCode
    }

    function global:ffmpeg {
        $global:QvcpTestCalls  += , ([string[]]$args)
        $global:QvcpTestTitles += $Host.UI.RawUI.WindowTitle
        $global:LASTEXITCODE = Get-QvcpStubExitCode
    }

    # Pester does not allow BeforeEach at the container root, so each Describe
    # calls this instead.
    function global:Reset-QvcpTestState {
        $global:QvcpTestCalls    = @()
        $global:QvcpTestTitles   = @()
        $global:QvcpTestExitCode = 0
    }

    function global:Get-QvcpArgAfter {
        param([string[]]$Arguments, [string]$Flag)
        $i = [Array]::IndexOf($Arguments, $Flag)
        if ($i -lt 0 -or $i -eq $Arguments.Count - 1) { return $null }
        return $Arguments[$i + 1]
    }
}

AfterAll {
    Remove-Item -Path 'function:yt-dlp'          -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:ffmpeg'          -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpStubExitCode' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpArgAfter' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Reset-QvcpTestState' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpMonthFolder' -ErrorAction SilentlyContinue

    $env:QVCP_OUTPUT_ROOT = $global:QvcpTestOriginalOutputRoot

    if ($global:QvcpTestRoot -and (Test-Path -LiteralPath $global:QvcpTestRoot)) {
        Remove-Item -LiteralPath $global:QvcpTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-Variable -Name QvcpTestCalls, QvcpTestTitles, QvcpTestExitCode, QvcpTestRoot,
        QvcpTestCookiesPath, QvcpTestOriginalOutputRoot,
        QvcpTestHasCookies, QvcpTestCanSetTitle -Scope Global -ErrorAction SilentlyContinue
}

Describe 'qvcp -G (generic yt-dlp mode)' {

    BeforeEach { Reset-QvcpTestState }

    It 'suppresses cookies explicitly for a YouTube URL' {
        qvcp -G 'https://www.youtube.com/watch?v=abc123'

        $global:QvcpTestCalls.Count | Should -Be 1
        $call = $global:QvcpTestCalls[0]
        $call | Should -Contain '--ignore-config'
        $call | Should -Contain '--no-cookies'
        $call | Should -Contain '--no-cookies-from-browser'
    }

    It 'never passes a cookies file, even for YouTube hosts' {
        qvcp -G 'https://youtu.be/abc123'

        $global:QvcpTestCalls[0] | Should -Not -Contain '--cookies'
    }

    It 'accepts the -Generic alias' {
        qvcp -Generic 'https://youtu.be/abc123'

        $global:QvcpTestCalls[0] | Should -Contain '--no-cookies'
    }

    It 'treats non-YouTube URLs identically' {
        qvcp -G 'https://example.com/media/clip.mp4'

        $call = $global:QvcpTestCalls[0]
        $call | Should -Contain '--no-cookies'
        $call | Should -Not -Contain '--cookies'
    }

    It '-OutDir replaces the dated output folder' {
        $dir = Join-Path $global:QvcpTestRoot 'elsewhere'

        qvcp -G 'https://example.com/clip.mp4' -OutDir $dir

        Get-QvcpArgAfter -Arguments $global:QvcpTestCalls[0] -Flag '-P' | Should -Be $dir
        Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
    }

    It 'downloads into the dated output folder' {
        qvcp -G 'https://example.com/clip.mp4'

        Get-QvcpArgAfter -Arguments $global:QvcpTestCalls[0] -Flag '-P' |
            Should -Be (Get-QvcpMonthFolder)
        Test-Path -LiteralPath (Get-QvcpMonthFolder) -PathType Container | Should -BeTrue
    }

    It 'passes the URL as the final argument' {
        qvcp -G 'https://example.com/clip.mp4'

        $call = $global:QvcpTestCalls[0]
        $call[-1] | Should -Be 'https://example.com/clip.mp4'
    }

    It 'downloads multiple URLs sequentially, in order' {
        qvcp -G 'https://example.com/a.mp4' 'https://example.com/b.mp4' 'https://example.com/c.mp4'

        $global:QvcpTestCalls.Count | Should -Be 3
        $global:QvcpTestCalls[0][-1] | Should -Be 'https://example.com/a.mp4'
        $global:QvcpTestCalls[1][-1] | Should -Be 'https://example.com/b.mp4'
        $global:QvcpTestCalls[2][-1] | Should -Be 'https://example.com/c.mp4'
    }

    It 'skips blank and whitespace-only URLs' {
        qvcp -G 'https://example.com/a.mp4' '   ' 'https://example.com/b.mp4'

        $global:QvcpTestCalls.Count | Should -Be 2
    }

    It 'throws when yt-dlp exits non-zero, and points at -Y for sign-in walls' {
        $global:QvcpTestExitCode = 1

        { qvcp -G 'https://example.com/a.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*exit code 1*use -Y instead*'
    }

    It 'embeds metadata, the source URL field, and the tagged comment' {
        qvcp -G 'https://example.com/clip.mp4'

        $call = $global:QvcpTestCalls[0]
        $call | Should -Contain '--embed-metadata'
        $call | Should -Contain '[[SourceURL|%(webpage_url)s]]:%(meta_comment)s'
        $call | Should -Contain '%(webpage_url)s:%(meta_source)s'
        ($call | Where-Object { $_ -eq '--parse-metadata' }).Count | Should -Be 2
        # Regression guard: use_metadata_tags moves every tag to mdta/keys, so
        # the standard mp4 atoms vanish and players show no metadata at all.
        $call | Should -Not -Contain '--postprocessor-args'
        $call -join ' ' | Should -Not -Match 'use_metadata_tags'
    }

    It 'keeps going past a failing URL and reports only the failures at the end' {
        $global:QvcpTestExitCode = 1, 0, 1

        { qvcp -G 'https://example.com/a.mp4' 'https://example.com/b.mp4' 'https://example.com/c.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage "*2 of 3 URL(s)*'https://example.com/a.mp4' (exit code 1)*'https://example.com/c.mp4' (exit code 1)*"
        $global:QvcpTestCalls.Count | Should -Be 3
    }

    It 'does not name URLs that succeeded in the failure report' {
        $global:QvcpTestExitCode = 1, 0

        { qvcp -G 'https://example.com/a.mp4' 'https://example.com/b.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage "*1 of 2 URL(s)*"
        $global:QvcpTestCalls.Count | Should -Be 2
    }

    It 'throws nothing when every URL succeeds' {
        { qvcp -G 'https://example.com/a.mp4' 'https://example.com/b.mp4' } | Should -Not -Throw
        $global:QvcpTestCalls.Count | Should -Be 2
    }

    It 'explains the skipped-fragment exit code' {
        $global:QvcpTestExitCode = 1

        { qvcp -G 'https://example.com/a.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage "*Skipping fragment*already downloaded*"
    }
}

Describe 'qvcp -Y (YouTube mode)' {

    BeforeEach { Reset-QvcpTestState }

    It 'passes the cookies file for YouTube URLs' -Skip:(-not $global:QvcpTestHasCookies) {
        qvcp -Y 'https://www.youtube.com/watch?v=abc123'

        $call = $global:QvcpTestCalls[0]
        $call | Should -Contain '--ignore-config'
        Get-QvcpArgAfter -Arguments $call -Flag '--cookies' | Should -Be $global:QvcpTestCookiesPath
    }

    It 'throws when the cookies file is missing' -Skip:$global:QvcpTestHasCookies {
        { qvcp -Y 'https://www.youtube.com/watch?v=abc123' } |
            Should -Throw -ExpectedMessage '*Cookies file not found*'
    }

    It 'does not pass cookies for non-YouTube URLs' {
        qvcp -Y 'https://example.com/media/clip.mp4'

        $call = $global:QvcpTestCalls[0]
        $call | Should -Not -Contain '--cookies'
        $call | Should -Not -Contain '--ignore-config'
    }

    It 'embeds metadata, the source URL field, and the tagged comment' {
        qvcp -Y 'https://example.com/clip.mp4'

        $call = $global:QvcpTestCalls[0]
        $call | Should -Contain '--embed-metadata'
        $call | Should -Contain '[[SourceURL|%(webpage_url)s]]:%(meta_comment)s'
        $call | Should -Contain '%(webpage_url)s:%(meta_source)s'
        ($call | Where-Object { $_ -eq '--parse-metadata' }).Count | Should -Be 2
        # Regression guard: use_metadata_tags moves every tag to mdta/keys, so
        # the standard mp4 atoms vanish and players show no metadata at all.
        $call | Should -Not -Contain '--postprocessor-args'
        $call -join ' ' | Should -Not -Match 'use_metadata_tags'
    }

    It 'keeps the yt-dlp -U hint on failure' {
        $global:QvcpTestExitCode = 1

        { qvcp -Y 'https://example.com/clip.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage "*yt-dlp -U*"
    }

    It 'points HLS-only downloads at -G' {
        $global:QvcpTestExitCode = 1

        { qvcp -Y 'https://example.com/clip.mp4' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage "*tv downgraded*retry with -G*"
    }
}

Describe 'qvcp (ffmpeg mode)' {

    BeforeEach { Reset-QvcpTestState }

    It '-OutDir applies to ffmpeg mode too' {
        $dir = Join-Path $global:QvcpTestRoot 'elsewhere'

        qvcp 'My Clip' 'https://example.com/stream.m3u8' -OutDir $dir

        $global:QvcpTestCalls[0][-1] | Should -Be (Join-Path $dir 'My Clip.mp4')
    }

    It 'remuxes to an mp4 named after the label, with metadata' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $call = $global:QvcpTestCalls[0]
        Get-QvcpArgAfter -Arguments $call -Flag '-i' | Should -Be 'https://example.com/stream.m3u8'
        $call | Should -Contain '-c'
        $call | Should -Contain 'copy'
        $call | Should -Contain 'title=My Clip'
        $call | Should -Contain 'comment=https://example.com/stream.m3u8'
        $call[-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'My Clip.mp4')
    }

    It 'sanitizes characters that are illegal in file names' {
        qvcp 'a:b*c?d' 'https://example.com/stream.m3u8'

        $global:QvcpTestCalls[0][-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'a_b_c_d.mp4')
    }

    It 'appends a numeric suffix when the target already exists' {
        New-Item -ItemType Directory -Path (Get-QvcpMonthFolder) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-QvcpMonthFolder) 'Dupe.mp4') -Value '' -NoNewline

        qvcp 'Dupe' 'https://example.com/stream.m3u8'

        $global:QvcpTestCalls[0][-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'Dupe-2.mp4')
    }
}

Describe 'qvcp parameter binding' {

    BeforeEach { Reset-QvcpTestState }

    It 'rejects -Y and -G together' {
        { qvcp -Y -G 'https://example.com/clip.mp4' } | Should -Throw
    }

    It 'rejects -G without a URL' {
        { qvcp -G } | Should -Throw
    }

    It 'rejects a bare URL with no label in ffmpeg mode' {
        { qvcp 'https://example.com/stream.m3u8' } | Should -Throw
    }
}

Describe 'qvcp window title handling' {

    BeforeEach { Reset-QvcpTestState }

    It 'leaves the window title alone in -G mode' -Skip:(-not $global:QvcpTestCanSetTitle) {
        $original = $Host.UI.RawUI.WindowTitle
        try {
            $Host.UI.RawUI.WindowTitle = 'qvcp-sentinel'
            qvcp -G 'https://example.com/clip.mp4'

            # Captured inside the stub, i.e. while qvcp was mid-run.
            $global:QvcpTestTitles[0] | Should -Be 'qvcp-sentinel'
        }
        finally {
            $Host.UI.RawUI.WindowTitle = $original
        }
    }

    It 'leaves the window title alone in -Y mode' -Skip:(-not $global:QvcpTestCanSetTitle) {
        $original = $Host.UI.RawUI.WindowTitle
        try {
            $Host.UI.RawUI.WindowTitle = 'qvcp-sentinel'
            qvcp -Y 'https://example.com/clip.mp4'

            $global:QvcpTestTitles[0] | Should -Be 'qvcp-sentinel'
        }
        finally {
            $Host.UI.RawUI.WindowTitle = $original
        }
    }

    It 'still sets the title to the label in ffmpeg mode' -Skip:(-not $global:QvcpTestCanSetTitle) {
        $original = $Host.UI.RawUI.WindowTitle
        try {
            $Host.UI.RawUI.WindowTitle = 'qvcp-sentinel'
            qvcp 'My Clip' 'https://example.com/stream.m3u8'

            $global:QvcpTestTitles[0] | Should -Be 'My Clip'
        }
        finally {
            $Host.UI.RawUI.WindowTitle = $original
        }
    }

    It 'restores the original title when done' -Skip:(-not $global:QvcpTestCanSetTitle) {
        $original = $Host.UI.RawUI.WindowTitle
        try {
            $Host.UI.RawUI.WindowTitle = 'qvcp-sentinel'
            qvcp 'My Clip' 'https://example.com/stream.m3u8'

            $Host.UI.RawUI.WindowTitle | Should -Be 'qvcp-sentinel'
        }
        finally {
            $Host.UI.RawUI.WindowTitle = $original
        }
    }
}
