function ytup {
    <#
    .SYNOPSIS
        Updates the YouTube download toolchain: yt-dlp (winget) and the
        bgutil PO token provider (git checkout + plugin zip), keeping the
        provider's two halves on the same release.

    .DESCRIPTION
        Three steps, each reported as it runs; a failure in one does not stop
        the others, and a single error at the end lists what failed.

        1. yt-dlp: 'winget upgrade' on the nightly package. A copy that has
           since self-updated with 'yt-dlp -U' fails winget's modified-file
           check, so that case is retried with --force.
        2. Provider: the latest bgutil-ytdlp-pot-provider release tag is
           checked out under -ProviderHome (cloned if absent) and its Deno
           dependencies installed.
        3. Plugin: the matching plugin zip from the same release replaces the
           one in yt-dlp's plugin folder.

    .EXAMPLE
        ytup
        Update everything and print the resulting versions.

    .EXAMPLE
        ytup -SkipProvider
        yt-dlp only.
    #>
    [CmdletBinding()]
    param(
        # winget package id for yt-dlp.
        [string]$WingetId = 'yt-dlp.yt-dlp.nightly',

        # Checkout of Brainicism/bgutil-ytdlp-pot-provider. This default is
        # the plugin's default server_home, so no extractor args are needed.
        [string]$ProviderHome = (Join-Path $HOME 'bgutil-ytdlp-pot-provider'),

        # yt-dlp plugin folder that receives the provider's plugin zip.
        [string]$PluginDir = (Join-Path $env:APPDATA 'yt-dlp\plugins'),

        [switch]$SkipYtDlp,
        [switch]$SkipProvider
    )

    $PROVIDER_REPO = 'Brainicism/bgutil-ytdlp-pot-provider'
    $PLUGIN_ZIP    = 'bgutil-ytdlp-pot-provider.zip'

    $failed = [System.Collections.Generic.List[string]]::new()
    $versions = [ordered]@{}

    # Runs one step, returning whatever the body outputs (nothing, on
    # failure). The body runs in a child scope, so it cannot assign to the
    # caller's variables; anything it needs to hand back must be output.
    function Step([string]$Name, [scriptblock]$Body) {
        Write-Host "==> $Name" -ForegroundColor Cyan
        try {
            & $Body
        }
        catch {
            Write-Warning "$Name failed: $_"
            $failed.Add("$Name`: $_")
        }
    }

    # ---- 1. yt-dlp ---------------------------------------------------------

    if (-not $SkipYtDlp) {
        Step "yt-dlp ($WingetId)" {
            if (-not (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
                throw "winget not found on PATH"
            }
            $out = @(& winget upgrade --id $WingetId 2>&1 | ForEach-Object { "$_" })
            $out | Write-Host
            $text = $out -join "`n"
            if ($text -match 'Portable package as it has been modified') {
                # The exe self-updated at some point, so its hash no longer
                # matches winget's record. winget's own instruction is --force.
                Write-Host '    modified by a previous yt-dlp -U; retrying with --force'
                $out = @(& winget upgrade --id $WingetId --force 2>&1 | ForEach-Object { "$_" })
                $out | Write-Host
                $text = $out -join "`n"
            }
            if ($text -notmatch 'Successfully installed|No available upgrade found|No newer package versions|is up to date') {
                throw "winget did not report success (exit code $LASTEXITCODE)"
            }
            if (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue) {
                $versions['yt-dlp'] = (& yt-dlp --version 2>&1 | Select-Object -First 1)
            }
        }
    }

    # ---- 2 + 3. PO token provider -------------------------------------------

    if (-not $SkipProvider) {
        $release = Step "provider release lookup ($PROVIDER_REPO)" {
            $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$PROVIDER_REPO/releases/latest" -Headers @{ 'User-Agent' = 'ytup' }
            if (-not $r.tag_name) {
                throw "no tag_name in the GitHub release response"
            }
            Write-Host "    latest release: $($r.tag_name)"
            $r
        }

        if ($release) {
            $tag = [string]$release.tag_name

            Step "provider checkout ($ProviderHome @ $tag)" {
                foreach ($tool in 'git', 'deno') {
                    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
                        throw "$tool not found on PATH"
                    }
                }
                if (Test-Path -LiteralPath (Join-Path $ProviderHome '.git') -PathType Container) {
                    & git -C $ProviderHome fetch --quiet --tags origin 2>&1 | ForEach-Object { "$_" } | Write-Host
                    if ($LASTEXITCODE -ne 0) { throw "git fetch exited $LASTEXITCODE" }
                    & git -C $ProviderHome checkout --quiet $tag 2>&1 | ForEach-Object { "$_" } | Write-Host
                    if ($LASTEXITCODE -ne 0) { throw "git checkout $tag exited $LASTEXITCODE" }
                }
                else {
                    & git clone --quiet --single-branch --branch $tag "https://github.com/$PROVIDER_REPO.git" $ProviderHome 2>&1 | ForEach-Object { "$_" } | Write-Host
                    if ($LASTEXITCODE -ne 0) { throw "git clone exited $LASTEXITCODE" }
                }

                # 'deno install' resolves deno.json from the working directory,
                # and the script provider expects node_modules under server\.
                $server = Join-Path $ProviderHome 'server'
                Push-Location -LiteralPath $server
                try {
                    & deno install --allow-scripts=npm:canvas --frozen 2>&1 | ForEach-Object { "$_" } | Write-Host
                    if ($LASTEXITCODE -ne 0) { throw "deno install exited $LASTEXITCODE" }
                }
                finally {
                    Pop-Location
                }
                $versions['provider'] = $tag
            }

            Step "plugin zip ($PluginDir)" {
                $asset = @($release.assets | Where-Object name -eq $PLUGIN_ZIP)
                if ($asset.Count -ne 1) {
                    throw "release $tag has no asset named $PLUGIN_ZIP"
                }
                if (-not (Test-Path -LiteralPath $PluginDir -PathType Container)) {
                    [void][System.IO.Directory]::CreateDirectory($PluginDir)
                }
                $dest = Join-Path $PluginDir $PLUGIN_ZIP
                Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $dest -Headers @{ 'User-Agent' = 'ytup' }
                $versions['plugin'] = Get-YtupPluginVersion -ZipPath $dest
                if ($versions['plugin'] -ne $tag) {
                    Write-Warning "plugin zip reports version '$($versions['plugin'])' but the release tag is '$tag'"
                }
            }
        }
    }

    # ---- Summary -----------------------------------------------------------

    Write-Host '==> versions' -ForegroundColor Cyan
    foreach ($kv in $versions.GetEnumerator()) {
        Write-Host ("    {0,-10} {1}" -f $kv.Key, $kv.Value)
    }

    if ($failed.Count -gt 0) {
        throw ("ytup: {0} step(s) failed:`n  {1}" -f $failed.Count, ($failed -join "`n  "))
    }
}

# The plugin declares its version in getpot_bgutil.py; reading it back from
# the zip is how ytup confirms the two halves of the provider match.
function Get-YtupPluginVersion {
    param([Parameter(Mandatory)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like '*/getpot_bgutil.py' } | Select-Object -First 1
        if (-not $entry) { return $null }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try {
            $m = [regex]::Match($reader.ReadToEnd(), "__version__\s*=\s*['""](?<v>[^'""]+)['""]")
            if ($m.Success) { $m.Groups['v'].Value } else { $null }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
}
