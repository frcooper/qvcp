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
        $global:QvcpTestTools  += 'ffmpeg'
        $global:QvcpTestTitles += $Host.UI.RawUI.WindowTitle
        $global:LASTEXITCODE = Get-QvcpStubExitCode
    }

    # Stream capture mode prefers Streamlink whenever it resolves, so the
    # no-Streamlink tests remove this stub and put it back afterwards.
    function global:Add-QvcpStreamlinkStub {
        Set-Item -Path 'function:global:streamlink' -Value {
            $global:QvcpTestCalls  += , ([string[]]$args)
            $global:QvcpTestTools  += 'streamlink'
            $global:QvcpTestPythonWarnings = $env:PYTHONWARNINGS
            $global:QvcpTestTitles += $Host.UI.RawUI.WindowTitle
            $global:LASTEXITCODE = Get-QvcpStubExitCode
            if ($global:QvcpTestStreamlinkWrites) {
                Set-Content -LiteralPath (Get-QvcpArgAfter -Arguments $args -Flag '-o') -Value 'ts' -NoNewline
            }
        }
    }
    Add-QvcpStreamlinkStub

    # Pester does not allow BeforeEach at the container root, so each Describe
    # calls this instead.
    function global:Reset-QvcpTestState {
        $global:QvcpTestCalls    = @()
        $global:QvcpTestTools    = @()
        $global:QvcpTestTitles   = @()
        $global:QvcpTestExitCode = 0
        $global:QvcpTestStreamlinkWrites = $true
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
    Remove-Item -Path 'function:Add-QvcpStreamlinkStub' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:streamlink'      -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpStubExitCode' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpArgAfter' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Reset-QvcpTestState' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Get-QvcpMonthFolder' -ErrorAction SilentlyContinue

    $env:QVCP_OUTPUT_ROOT = $global:QvcpTestOriginalOutputRoot

    if ($global:QvcpTestRoot -and (Test-Path -LiteralPath $global:QvcpTestRoot)) {
        Remove-Item -LiteralPath $global:QvcpTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-Variable -Name QvcpTestCalls, QvcpTestTools, QvcpTestTitles, QvcpTestExitCode, QvcpTestRoot,
        QvcpTestStreamlinkWrites, QvcpTestPythonWarnings,
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
            Should -Throw -ExpectedMessage '*exit code 1*For YouTube use -Y*for Reddit use -R*'
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

    It 'uses an explicit browser session for Reddit and YouTube without the saved cookie file' {
        qvcp -Y -CookiesFromBrowser 'firefox:work' 'https://v.redd.it/test' 'https://youtu.be/test'

        $global:QvcpTestCalls.Count | Should -Be 2
        foreach ($call in $global:QvcpTestCalls) {
            Get-QvcpArgAfter -Arguments $call -Flag '--cookies-from-browser' | Should -Be 'firefox:work'
            $call | Should -Contain '--ignore-config'
            $call | Should -Contain '--no-cookies'
            $call | Should -Not -Contain '--cookies'
            $call | Should -Not -Contain '--no-cookies-from-browser'
        }
    }

    It 'rejects browser cookies in generic mode before invoking yt-dlp' {
        { qvcp -G -CookiesFromBrowser firefox 'https://v.redd.it/test' } | Should -Throw
        $global:QvcpTestCalls.Count | Should -Be 0
    }

    It 'explains how to supply a Reddit browser session' {
        $global:QvcpTestExitCode = 1
        { qvcp -G 'https://v.redd.it/test' -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*Reddit use -R*'
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

Describe 'qvcp (stream capture mode, Streamlink)' {

    BeforeEach { Reset-QvcpTestState }

    It 'captures with Streamlink, without certificate verification' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $global:QvcpTestTools | Should -Be @('streamlink', 'ffmpeg')
        $sl = $global:QvcpTestCalls[0]
        $sl | Should -Contain '--http-no-ssl-verify'
        $sl[-2] | Should -Be 'hls://https://example.com/stream.m3u8'
        $sl[-1] | Should -Be 'best'
    }

    It 'silences the per-request insecure warning for Streamlink only' {
        $saved = $env:PYTHONWARNINGS
        try {
            $env:PYTHONWARNINGS = 'default'
            qvcp 'My Clip' 'https://example.com/stream.m3u8'

            $global:QvcpTestPythonWarnings | Should -Be 'ignore:Unverified HTTPS request'
            $env:PYTHONWARNINGS | Should -Be 'default'
        }
        finally {
            $env:PYTHONWARNINGS = $saved
        }
    }

    It 'asks Streamlink for DASH when the URL is an MPD' {
        qvcp 'My Clip' 'https://example.com/manifest.mpd?t=1'

        $global:QvcpTestCalls[0][-2] | Should -Be 'dash://https://example.com/manifest.mpd?t=1'
    }

    It 'remuxes the capture to an mp4 named after the label, with metadata, and removes the .ts' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $ts = Join-Path (Get-QvcpMonthFolder) 'My Clip.qvcp.ts'
        Get-QvcpArgAfter -Arguments $global:QvcpTestCalls[0] -Flag '-o' | Should -Be $ts
        $remux = $global:QvcpTestCalls[1]
        Get-QvcpArgAfter -Arguments $remux -Flag '-i' | Should -Be $ts
        $remux | Should -Contain '-c'
        $remux | Should -Contain 'copy'
        $remux | Should -Contain 'title=My Clip'
        $remux | Should -Contain 'comment=https://example.com/stream.m3u8'
        $remux[-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'My Clip.mp4')
        Test-Path -LiteralPath $ts | Should -BeFalse
    }

    It '-OutDir applies to stream capture mode too' {
        $dir = Join-Path $global:QvcpTestRoot 'elsewhere'

        qvcp 'My Clip' 'https://example.com/stream.m3u8' -OutDir $dir

        $global:QvcpTestCalls[-1][-1] | Should -Be (Join-Path $dir 'My Clip.mp4')
    }

    It 'sanitizes characters that are illegal in file names' {
        qvcp 'a:b*c?d' 'https://example.com/stream.m3u8'

        $global:QvcpTestCalls[-1][-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'a_b_c_d.mp4')
    }

    It 'appends a numeric suffix when the target already exists' {
        New-Item -ItemType Directory -Path (Get-QvcpMonthFolder) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-QvcpMonthFolder) 'Dupe.mp4') -Value '' -NoNewline

        qvcp 'Dupe' 'https://example.com/stream.m3u8'

        $global:QvcpTestCalls[-1][-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'Dupe-2.mp4')
    }

    It 'keeps the .ts and throws when the remux fails' {
        $global:QvcpTestExitCode = @(0, 1)

        { qvcp 'Remux Fail' 'https://example.com/stream.m3u8' } | Should -Throw '*capture is kept*'
        Test-Path -LiteralPath (Join-Path (Get-QvcpMonthFolder) 'Remux Fail.qvcp.ts') | Should -BeTrue
    }

    It 'falls back to ffmpeg with a warning when Streamlink captures nothing' {
        $global:QvcpTestStreamlinkWrites = $false
        $global:QvcpTestExitCode = 1

        qvcp 'My Clip' 'https://example.com/stream.m3u8' -WarningVariable w -WarningAction SilentlyContinue

        "$w" | Should -Match 'Streamlink captured nothing'
        $global:QvcpTestTools | Should -Be @('streamlink', 'ffmpeg')
        Get-QvcpArgAfter -Arguments $global:QvcpTestCalls[1] -Flag '-i' | Should -Be 'https://example.com/stream.m3u8'
    }
}

Describe 'qvcp (stream capture mode, no Streamlink)' {

    BeforeEach {
        Reset-QvcpTestState
        # A real Streamlink may be installed alongside the stub; every tool
        # qvcp still needs here is a stub function, so PATH can go.
        $script:savedPath = $env:PATH
        $env:PATH = ''
        Remove-Item -Path 'function:streamlink'
    }

    AfterEach {
        $env:PATH = $script:savedPath
        Add-QvcpStreamlinkStub
    }

    It 'remuxes the URL with ffmpeg, verification off, with metadata' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $global:QvcpTestTools | Should -Be @('ffmpeg')
        $call = $global:QvcpTestCalls[0]
        Get-QvcpArgAfter -Arguments $call -Flag '-i' | Should -Be 'https://example.com/stream.m3u8'
        Get-QvcpArgAfter -Arguments $call -Flag '-tls_verify' | Should -Be '0'
        [Array]::IndexOf($call, '-tls_verify') | Should -BeLessThan ([Array]::IndexOf($call, '-i'))
        $call | Should -Contain 'title=My Clip'
        $call | Should -Contain 'comment=https://example.com/stream.m3u8'
        $call[-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'My Clip.mp4')
    }

    It 'points at installing Streamlink when ffmpeg fails' {
        $global:QvcpTestExitCode = 1

        qvcp 'My Clip' 'https://example.com/stream.m3u8' -WarningVariable w -WarningAction SilentlyContinue

        "$w" | Should -Match 'winget install Streamlink\.Streamlink'
    }

    It 'warns about nothing when ffmpeg succeeds' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8' -WarningVariable w

        $w | Should -BeNullOrEmpty
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

Describe 'qvcp -R (Reddit preset)' {
    BeforeEach { Reset-QvcpTestState }

    It 'uses Firefox cookies for each URL by default' {
        qvcp -R 'https://v.redd.it/test' 'https://www.reddit.com/r/test/comments/test/'
        $global:QvcpTestCalls.Count | Should -Be 2
        foreach ($call in $global:QvcpTestCalls) {
            Get-QvcpArgAfter -Arguments $call -Flag '--cookies-from-browser' | Should -Be 'firefox'
            $call | Should -Contain '--ignore-config'
            $call | Should -Contain '--embed-metadata'
            $call | Should -Not -Contain '--cookies'
        }
    }

    It 'accepts an explicit browser profile' {
        qvcp -R -CookiesFromBrowser 'firefox:work' 'https://v.redd.it/test'
        Get-QvcpArgAfter -Arguments $global:QvcpTestCalls[0] -Flag '--cookies-from-browser' | Should -Be 'firefox:work'
    }

    It 'rejects combining Reddit with another mode' {
        { qvcp -R -G 'https://v.redd.it/test' } | Should -Throw
        { qvcp -R -Y 'https://v.redd.it/test' } | Should -Throw
        $global:QvcpTestCalls.Count | Should -Be 0
    }
}
