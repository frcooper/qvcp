function qvcp {
    [CmdletBinding(DefaultParameterSetName='FFmpeg')]
    param(
        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=0)]
        [string]$Word,

        [Parameter(ParameterSetName='FFmpeg', Mandatory=$true, Position=1)]
        [Parameter(ParameterSetName='YouTube', Mandatory=$true, Position=0)]
        [string]$Url,

        [Parameter(ParameterSetName='YouTube', Mandatory=$true)]
        [switch]$Y
    )

    $originalTitle = $Host.UI.RawUI.WindowTitle
    $ytDlpCookiesPath = 'C:\Users\FRC\Documents\cookies.firefox-private.txt'

    try {
        $Host.UI.RawUI.WindowTitle = $Word

        $now    = Get-Date
        $folder = Join-Path 'X:\in\clips' ('{0:yyyy-MM}' -f $now)

        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            try {
                New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            }
            catch {
                throw "Unable to access output folder '$folder' : $_"
            }
        }

        if ($Y) {
            if (-not (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)) {
                throw "yt-dlp not found on PATH"
            }
            & yt-dlp --cookies $ytDlpCookiesPath -P $folder $Url
        }
        else {
            $safeWord   = ($Word -replace '[\\\/\:\*\?\"\<\>\|]', '_').Trim()
            $baseName   = $safeWord
            $baseFile   = Join-Path $folder ($baseName + '.mp4')
            $outputPath = $baseFile

            if ([System.IO.File]::Exists($baseFile)) {
                $i = 2
                while ($true) {
                    $candidate = Join-Path $folder ("{0}-{1}.mp4" -f $baseName, $i)
                    if (-not [System.IO.File]::Exists($candidate)) {
                        $outputPath = $candidate
                        break
                    }
                    $i++
                }
            }

            & ffmpeg `
                -i $Url `
                -c copy `
                -metadata title="$Word" `
                -metadata comment="$Url" `
                $outputPath
        }
    }
    finally {
        $Host.UI.RawUI.WindowTitle = $originalTitle
    }
}