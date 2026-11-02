# Shared by qvcp.ps1 and ytxa.ps1, which import it from their own folder.
# Everything the two have to agree on lives here: where downloads go, which
# cookies file is used, how a file is matched to its YouTube id, and the shape
# of the [[SourceURL|...]] comment.

$script:COOKIES_FILE = 'cookies.firefox-private.txt'

$script:YOUTUBE_HOSTS = @(
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com'
)

# yt-dlp's default output template ends in " [%(id)s].%(ext)s". Only the
# bracketed form is matched: an 11-character id can appear by chance in any
# title, so a bare match would flood ytxa's report with false positives.
$script:ID_IN_NAME   = '\[(?<id>[A-Za-z0-9_-]{11})\]$'
$script:ID_IN_URL    = '(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/)(?<id>[A-Za-z0-9_-]{11})'
$script:SOURCE_SIGIL = '\[\[SourceURL\|(?<url>.*?)\]\]'
$script:VIDEO_EXT    = @('.mp4', '.mkv', '.webm', '.mov', '.m4v')

function Get-QvcpOutputRoot {
    if ([string]::IsNullOrWhiteSpace($env:QVCP_OUTPUT_ROOT)) { 'X:\in\clips' } else { $env:QVCP_OUTPUT_ROOT }
}

# Where the cookies file is expected; whether it has to exist is the
# caller's call.
function Get-QvcpCookiesPath {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) $script:COOKIES_FILE
}

function Test-QvcpYouTubeUrl([string]$Url) {
    $uri = $null
    [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $script:YOUTUBE_HOSTS -contains $uri.Host.ToLowerInvariant()
}

# The video id in a URL, or $null. No host check: the sigil only ever holds
# yt-dlp's webpage_url, and callers that need one use Test-QvcpYouTubeUrl.
function Get-QvcpUrlId([string]$Url) {
    $m = [regex]::Match($Url, $script:ID_IN_URL)
    if ($m.Success) { $m.Groups['id'].Value } else { $null }
}

# The id from a file's base name (no extension), or $null.
function Get-QvcpNameId([string]$BaseName) {
    $m = [regex]::Match($BaseName, $script:ID_IN_NAME)
    if ($m.Success) { $m.Groups['id'].Value } else { $null }
}

function Test-QvcpVideoFile([System.IO.FileInfo]$File) {
    $script:VIDEO_EXT -contains $File.Extension.ToLowerInvariant()
}

# Video files directly in $Folder whose name ends in "[<id>]", newest first.
function Find-QvcpDownload([string]$Folder, [string]$Id) {
    $suffix = "[$Id]"
    @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { (Test-QvcpVideoFile $_) -and $_.BaseName.EndsWith($suffix, [StringComparison]::Ordinal) } |
        Sort-Object LastWriteTime -Descending)
}

# The sigil for a URL. qvcp passes yt-dlp's '%(webpage_url)s' template here to
# build its --parse-metadata rule, so both writers produce the same shape.
function Format-QvcpSourceSigil([string]$Url) {
    "[[SourceURL|$Url]]"
}

# The URL inside a comment's sigil, or $null.
function Get-QvcpSourceUrl([string]$Comment) {
    $m = [regex]::Match($Comment, $script:SOURCE_SIGIL)
    if ($m.Success) { $m.Groups['url'].Value } else { $null }
}

# The comment from an ffprobe format.tags object. mp4 stores it as 'comment',
# mkv as 'COMMENT', so the key is matched case-insensitively.
function Get-QvcpCommentTag([object]$Tags) {
    $comment = $null
    if ($Tags) {
        foreach ($prop in $Tags.PSObject.Properties) {
            if ($prop.Name -ieq 'comment') { $comment = [string]$prop.Value }
        }
    }
    $comment
}

# A file's comment tag via ffprobe, or $null when there is none or ffprobe
# cannot read the file. ffprobe gets '-i <file>' so a name starting with '-'
# is not read as an option.
function Read-QvcpComment([string]$Path) {
    $text = & ffprobe -v error -show_entries 'format_tags' -of json -i $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $text) { return $null }
    Get-QvcpCommentTag (($text -join "`n") | ConvertFrom-Json).format.tags
}

# True when the comment's sigil names the given id.
function Test-QvcpSourceComment([string]$Comment, [string]$Id) {
    $url = Get-QvcpSourceUrl $Comment
    [bool]$url -and (Get-QvcpUrlId $url) -ceq $Id
}

Export-ModuleMember -Function *-Qvcp*
