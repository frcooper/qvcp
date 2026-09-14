#Requires -Version 7.0

# Tests for the `ytup` PowerShell helper.
#
# `winget`, `git`, `deno` and `yt-dlp` are global stub functions that record
# their arguments (and, for deno, the working directory) and answer from
# per-test tables. The GitHub calls are Pester mocks: Invoke-RestMethod hands
# back a canned release, Invoke-WebRequest writes a real zip so the version
# reader is exercised too. Everything lands in a temp folder.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'ytup.ps1')

    $global:YtupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ytup-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:YtupRoot -Force | Out-Null

    function global:winget {
        $global:YtupCalls += , (@('winget') + [string[]]$args)
        $global:LASTEXITCODE = 0
        # First call answers with $YtupWingetFirst, later calls with $YtupWingetThen.
        if ((Get-YtupCalls 'winget').Count -eq 1) { $global:YtupWingetFirst } else { $global:YtupWingetThen }
    }

    function global:git {
        $global:YtupCalls += , (@('git') + [string[]]$args)
        $global:LASTEXITCODE = $global:YtupGitExit
        if ($args[0] -eq 'clone' -and $global:YtupGitExit -eq 0) {
            # A clone leaves behind what the later steps need: a .git marker
            # and the server folder deno is run from.
            $dest = [string]$args[-1]
            New-Item -ItemType Directory -Path (Join-Path $dest '.git')   -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dest 'server') -Force | Out-Null
        }
    }

    function global:deno {
        $global:YtupCalls += , (@('deno') + [string[]]$args)
        $global:YtupDenoCwd = (Get-Location).Path
        $global:LASTEXITCODE = 0
    }

    function global:yt-dlp {
        $global:YtupCalls += , (@('yt-dlp') + [string[]]$args)
        $global:LASTEXITCODE = 0
        '2026.08.30.232658'
    }

    function global:Reset-YtupState {
        $global:YtupCalls       = @()
        $global:YtupWingetFirst = 'Successfully installed'
        $global:YtupWingetThen  = 'Successfully installed'
        $global:YtupGitExit     = 0
        $global:YtupDenoCwd     = $null
        $global:YtupHome        = Join-Path $global:YtupRoot 'provider'
        $global:YtupPlugins     = Join-Path $global:YtupRoot 'plugins'
        Get-ChildItem -LiteralPath $global:YtupRoot -Force | Remove-Item -Recurse -Force
    }

    # Built with a loop and returned behind a unary comma: piping the outer
    # array through Where-Object would unroll each inner argument array into
    # its strings.
    function global:Get-YtupCalls([string]$Tool) {
        $out = @()
        foreach ($call in $global:YtupCalls) {
            if ($call[0] -eq $Tool) { $out += , $call }
        }
        return , $out
    }

    # Writes a plugin zip whose getpot_bgutil.py declares the given version,
    # the way the real release asset does.
    function global:New-YtupPluginZip([string]$Path, [string]$Version) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry  = $zip.CreateEntry('yt_dlp_plugins/extractor/getpot_bgutil.py')
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try { $writer.Write("__version__ = '$Version'`n") } finally { $writer.Dispose() }
        }
        finally {
            $zip.Dispose()
        }
    }

    function global:New-YtupRelease([string]$Tag, [bool]$WithAsset = $true) {
        $assets = @()
        if ($WithAsset) {
            $assets += [pscustomobject]@{ name = 'bgutil-ytdlp-pot-provider.zip'; browser_download_url = "https://example.invalid/$Tag/bgutil-ytdlp-pot-provider.zip" }
        }
        [pscustomobject]@{ tag_name = $Tag; assets = $assets }
    }
}

AfterAll {
    foreach ($name in 'winget', 'git', 'deno', 'yt-dlp', 'Reset-YtupState', 'Get-YtupCalls', 'New-YtupPluginZip', 'New-YtupRelease') {
        Remove-Item -Path "function:$name" -ErrorAction SilentlyContinue
    }
    if ($global:YtupRoot -and (Test-Path -LiteralPath $global:YtupRoot)) {
        Remove-Item -LiteralPath $global:YtupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name YtupRoot, YtupCalls, YtupWingetFirst, YtupWingetThen, YtupGitExit,
        YtupDenoCwd, YtupHome, YtupPlugins -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ytup' {

    BeforeEach {
        Reset-YtupState
        Mock Invoke-RestMethod { New-YtupRelease '2.0.0' }
        Mock Invoke-WebRequest { New-YtupPluginZip -Path $OutFile -Version '2.0.0' }
    }

    Context 'yt-dlp via winget' {

        It 'upgrades the nightly package by id, without --force when winget is happy' {
            ytup -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            $calls = Get-YtupCalls 'winget'
            $calls.Count | Should -Be 1
            $calls[0] | Should -Contain 'upgrade'
            $calls[0] | Should -Contain 'yt-dlp.yt-dlp.nightly'
            $calls[0] | Should -Not -Contain '--force'
        }

        It 'retries with --force when the portable package was modified by yt-dlp -U' {
            $global:YtupWingetFirst = 'Unable to remove Portable package as it has been modified; to override this check use --force'
            $global:YtupWingetThen  = 'Portable package has been modified; proceeding due to --force', 'Successfully installed'

            ytup -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            $calls = Get-YtupCalls 'winget'
            $calls.Count | Should -Be 2
            $calls[1] | Should -Contain '--force'
        }

        It 'treats "no available upgrade" as success' {
            $global:YtupWingetFirst = 'No available upgrade found.', 'No newer package versions are available from the configured sources.'

            { ytup -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null } | Should -Not -Throw
        }

        It 'reports a winget failure at the end but still updates the provider' {
            $global:YtupWingetFirst = 'Installer failed with exit code: 1'

            { ytup -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins -WarningAction SilentlyContinue 6>$null } |
                Should -Throw -ExpectedMessage '*1 step(s) failed*yt-dlp (yt-dlp.yt-dlp.nightly)*'
            (Get-YtupCalls 'git').Count  | Should -BeGreaterThan 0
            (Get-YtupCalls 'deno').Count | Should -Be 1
        }

        It '-SkipYtDlp never calls winget' {
            ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            (Get-YtupCalls 'winget').Count | Should -Be 0
        }
    }

    Context 'PO token provider' {

        It 'clones the latest release tag when the checkout is absent, then runs deno install in server\' {
            ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            $git = Get-YtupCalls 'git'
            $git.Count | Should -Be 1
            $git[0] | Should -Contain 'clone'
            $git[0] | Should -Contain '--branch'
            $git[0] | Should -Contain '2.0.0'
            $git[0][-1] | Should -Be $global:YtupHome

            $deno = Get-YtupCalls 'deno'
            $deno.Count | Should -Be 1
            $deno[0] | Should -Contain 'install'
            $deno[0] | Should -Contain '--frozen'
            $deno[0] | Should -Contain '--allow-scripts=npm:canvas'
            $global:YtupDenoCwd | Should -Be (Join-Path $global:YtupHome 'server')
        }

        It 'fetches and checks out the tag when the checkout already exists' {
            New-Item -ItemType Directory -Path (Join-Path $global:YtupHome '.git')   -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $global:YtupHome 'server') -Force | Out-Null

            ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            $git = Get-YtupCalls 'git'
            $git.Count | Should -Be 2
            $git[0] | Should -Contain 'fetch'
            $git[0] | Should -Contain '--tags'
            $git[1] | Should -Contain 'checkout'
            $git[1] | Should -Contain '2.0.0'
            $git | ForEach-Object { $_ | Should -Contain $global:YtupHome }
        }

        It 'downloads the matching plugin zip into the plugin folder and reads its version back' {
            ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            $zip = Join-Path $global:YtupPlugins 'bgutil-ytdlp-pot-provider.zip'
            Test-Path -LiteralPath $zip -PathType Leaf | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/2.0.0/bgutil-ytdlp-pot-provider.zip' }
            Get-YtupPluginVersion -ZipPath $zip | Should -Be '2.0.0'
        }

        It 'skips checkout and plugin when the release lookup fails' {
            Mock Invoke-RestMethod { throw 'rate limited' }

            { ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins -WarningAction SilentlyContinue 6>$null } |
                Should -Throw -ExpectedMessage '*release lookup*rate limited*'
            (Get-YtupCalls 'git').Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'fails the plugin step when the release has no plugin zip, but still updates the checkout' {
            Mock Invoke-RestMethod { New-YtupRelease '2.1.0' $false }

            { ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins -WarningAction SilentlyContinue 6>$null } |
                Should -Throw -ExpectedMessage '*no asset named bgutil-ytdlp-pot-provider.zip*'
            (Get-YtupCalls 'git')[0] | Should -Contain '2.1.0'
        }

        It 'reports a git failure and does not run deno' {
            $global:YtupGitExit = 128

            { ytup -SkipYtDlp -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins -WarningAction SilentlyContinue 6>$null } |
                Should -Throw -ExpectedMessage '*git clone exited 128*'
            (Get-YtupCalls 'deno').Count | Should -Be 0
        }

        It '-SkipProvider touches neither GitHub nor git' {
            ytup -SkipProvider -ProviderHome $global:YtupHome -PluginDir $global:YtupPlugins 6>$null

            (Get-YtupCalls 'git').Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }
}
