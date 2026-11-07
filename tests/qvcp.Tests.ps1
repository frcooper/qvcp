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

    # Answers the already-downloaded check from a table of comments keyed by
    # leaf name. Its calls are kept apart from QvcpTestCalls, which the tests
    # count as yt-dlp / ffmpeg invocations.
    function global:ffprobe {
        $global:QvcpTestProbeCalls += , ([string[]]$args)
        $i    = [Array]::IndexOf([string[]]$args, '-i')
        $leaf = [System.IO.Path]::GetFileName($args[$i + 1])
        $tags = @{}
        if ($global:QvcpTestProbeComments.ContainsKey($leaf)) { $tags.comment = $global:QvcpTestProbeComments[$leaf] }
        @{ format = @{ tags = $tags } } | ConvertTo-Json -Depth 5
        $global:LASTEXITCODE = 0
    }

    # Undoes what Streamlink does to --player-args: fill {playerinput} with
    # '-' (stdin), collapse doubled braces (str.format), then split POSIX-shell
    # style (shlex.split). Only the quoting qvcp produces needs handling:
    # single-quoted runs, backslash escapes outside quotes, and whitespace.
    function global:ConvertFrom-QvcpPlayerArgs {
        param([string]$PlayerArgs)
        $s = $PlayerArgs -replace '\{playerinput\}', '-' -replace '\{\{', '{' -replace '\}\}', '}'
        $out = [System.Collections.Generic.List[string]]::new()
        $cur = [System.Text.StringBuilder]::new()
        $inToken = $false
        for ($i = 0; $i -lt $s.Length; $i++) {
            $c = $s[$i]
            if ($c -eq "'") {
                $inToken = $true
                $end = $s.IndexOf("'", $i + 1)
                [void]$cur.Append($s.Substring($i + 1, $end - $i - 1))
                $i = $end
            }
            elseif ($c -eq '\') {
                $inToken = $true
                [void]$cur.Append($s[++$i])
            }
            elseif ([char]::IsWhiteSpace($c)) {
                if ($inToken) { $out.Add($cur.ToString()); [void]$cur.Clear(); $inToken = $false }
            }
            else {
                $inToken = $true
                [void]$cur.Append($c)
            }
        }
        if ($inToken) { $out.Add($cur.ToString()) }
        return , [string[]]$out
    }

    # Stream capture mode prefers Streamlink whenever it resolves, so the
    # no-Streamlink tests remove this stub and put it back afterwards. When it
    # "captures", it starts its player the way Streamlink would — the ffmpeg
    # stub, with the decoded --player-args — and writes the output file.
    function global:Add-QvcpStreamlinkStub {
        Set-Item -Path 'function:global:streamlink' -Value {
            $global:QvcpTestCalls  += , ([string[]]$args)
            $global:QvcpTestTools  += 'streamlink'
            $global:QvcpTestPythonWarnings = $env:PYTHONWARNINGS
            $global:QvcpTestTitles += $Host.UI.RawUI.WindowTitle
            $code = Get-QvcpStubExitCode
            if ($global:QvcpTestStreamlinkWrites) {
                $playerArgs = ConvertFrom-QvcpPlayerArgs (Get-QvcpArgAfter -Arguments $args -Flag '--player-args')
                & (Get-QvcpArgAfter -Arguments $args -Flag '--player') @playerArgs
                Set-Content -LiteralPath $playerArgs[-1] -Value 'mp4' -NoNewline
            }
            $global:LASTEXITCODE = $code
        }
    }
    Add-QvcpStreamlinkStub

    # Pester does not allow BeforeEach at the container root, so each Describe
    # calls this instead.
    function global:Reset-QvcpTestState {
        $global:QvcpTestCalls         = @()
        $global:QvcpTestTools         = @()
        $global:QvcpTestTitles        = @()
        $global:QvcpTestExitCode      = 0
        $global:QvcpTestStreamlinkWrites = $true
        $global:QvcpTestProbeCalls    = @()
        $global:QvcpTestProbeComments = @{}
        $month = Get-QvcpMonthFolder
        if (Test-Path -LiteralPath $month) {
            Get-ChildItem -LiteralPath $month -File | Remove-Item -Force
        }
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
    Remove-Item -Path 'function:ffprobe'         -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Add-QvcpStreamlinkStub' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:ConvertFrom-QvcpPlayerArgs' -ErrorAction SilentlyContinue
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
        QvcpTestStreamlinkWrites, QvcpTestPythonWarnings, QvcpTestProbeCalls, QvcpTestProbeComments,
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

Describe 'qvcp re-run over an existing download' {
    BeforeEach {
        Reset-QvcpTestState
        $month = Get-QvcpMonthFolder
        New-Item -ItemType Directory -Path $month -Force | Out-Null
        function New-Download([string]$Name, [string]$Comment) {
            New-Item -ItemType File -Path (Join-Path $month $Name) -Force | Out-Null
            if ($Comment) { $global:QvcpTestProbeComments[$Name] = $Comment }
        }
    }

    It 'skips yt-dlp when the file is already tagged for that id' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 0
        $global:QvcpTestProbeCalls.Count | Should -Be 1
    }

    It 'recognises short links and keeps an older comment behind the sigil' {
        New-Download 'Clip [dQw4w9WgXcQ].webm' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]`nold note"

        qvcp -G 'https://youtu.be/dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 0
    }

    It 'runs yt-dlp when the existing file has no SourceURL comment' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' 'just a comment'

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
    }

    It 'runs yt-dlp when the sigil names a different video' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' "[[SourceURL|https://www.youtube.com/watch?v=aaaaaaaaaaa]]"

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
    }

    It 'runs yt-dlp when any copy of the video is untagged' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4'  "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"
        New-Download 'Clip [dQw4w9WgXcQ].webm' $null

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
    }

    It 'ignores a file ytxa has moved aside' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4.ytxa-old' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
        $global:QvcpTestProbeCalls.Count | Should -Be 0
    }

    It 'does not derive an id from a non-YouTube URL' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"

        qvcp -G 'https://example.com/watch?v=dQw4w9WgXcQ' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
        $global:QvcpTestProbeCalls.Count | Should -Be 0
    }

    It 'skips only the tagged URLs in a batch' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"

        qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 'https://www.youtube.com/watch?v=bbbbbbbbbbb' 6>$null

        $global:QvcpTestCalls.Count | Should -Be 1
        $global:QvcpTestCalls[0][-1] | Should -Be 'https://www.youtube.com/watch?v=bbbbbbbbbbb'
    }

    # A profile script can leave Set-StrictMode on for the whole session, and a
    # function's scope inherits it from the caller. No match and a single match
    # are the two cases where the lookup's array does not survive the return.
    It 'works under Set-StrictMode when no copy exists' {
        try {
            Set-StrictMode -Version Latest
            qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null
        }
        finally { Set-StrictMode -Off }

        $global:QvcpTestCalls.Count | Should -Be 1
    }

    It 'works under Set-StrictMode when one tagged copy exists' {
        New-Download 'Clip [dQw4w9WgXcQ].mp4' "[[SourceURL|https://www.youtube.com/watch?v=dQw4w9WgXcQ]]"

        try {
            Set-StrictMode -Version Latest
            qvcp -G 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' 6>$null
        }
        finally { Set-StrictMode -Off }

        $global:QvcpTestCalls.Count | Should -Be 0
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

    It 'streams into ffmpeg as its player, which it never kills, with no temp file' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $sl = $global:QvcpTestCalls[0]
        Get-QvcpArgAfter -Arguments $sl -Flag '--player' | Should -Be 'ffmpeg'
        $sl | Should -Contain '--player-no-close'
        $sl | Should -Contain '--player-verbose'
        $sl | Should -Not -Contain '-o'
        $sl | Should -Not -Contain '-O'
        Get-QvcpArgAfter -Arguments $sl -Flag '--player-args' | Should -BeLike '*{playerinput}*'
        Get-ChildItem -LiteralPath (Get-QvcpMonthFolder) -Name | Should -Be @('My Clip.mp4')
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

    It 'has ffmpeg read stdin and write the mp4 named after the label, with metadata' {
        qvcp 'My Clip' 'https://example.com/stream.m3u8'

        $ff = $global:QvcpTestCalls[1]
        Get-QvcpArgAfter -Arguments $ff -Flag '-i' | Should -Be '-'
        $ff | Should -Contain '-c'
        $ff | Should -Contain 'copy'
        $ff | Should -Contain 'title=My Clip'
        $ff | Should -Contain 'comment=https://example.com/stream.m3u8'
        $ff[-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) 'My Clip.mp4')
    }

    It 'quotes the player arguments so quotes, braces and backslashes survive' {
        $label = "It's {a} \ b}"
        $url   = 'https://example.com/live.m3u8?a=1&b={x}'

        qvcp $label $url

        $ff = $global:QvcpTestCalls[1]
        $ff | Should -Contain "title=$label"
        $ff | Should -Contain "comment=$url"
        $ff[-1] | Should -Be (Join-Path (Get-QvcpMonthFolder) "It's {a} _ b}.mp4")
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
