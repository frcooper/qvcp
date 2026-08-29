#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the qvcp Pester suite.

.EXAMPLE
    ./tests/run-tests.ps1
    ./tests/run-tests.ps1 -Verbosity Normal
#>
[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Detailed',

    # Set a non-zero exit code on failure. Useful in CI; off by default so a
    # failing run does not kill an interactive shell.
    [switch]$ExitOnFailure
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell ships Pester 3.x, which cannot parse this suite.
$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    throw "Pester 5+ is required. Install it with: Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck"
}

Import-Module -Name $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path         = $PSScriptRoot
$config.Run.Exit         = [bool]$ExitOnFailure
$config.Output.Verbosity = $Verbosity

Invoke-Pester -Configuration $config
