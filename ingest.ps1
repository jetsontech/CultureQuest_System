param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$VideoFile
)

$ErrorActionPreference = "Stop"

function Normalize-Name {
    param([string]$Name)
    $n = $Name.ToLower()
    $n = $n -replace '\.[^.]+$',''
    $n = $n -replace '[^a-z0-9]+','-'
    $n = $n.Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = "stream" }
    return $n
}

Write-Host "=================================" -ForegroundColor Cyan
Write-Host " CultureQuest Video Ingest" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan

if (!(Test-Path $VideoFile)) {
    throw "Input video not found: $VideoFile"
}

$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue)
if (-not $ffmpeg) {
    throw "FFmpeg is not in PATH. Run: ffmpeg -version"
}

$fullInput = [System.IO.Path]::GetFullPath($VideoFile)
$name = [System.IO.Path]::GetFileNameWithoutExtension($fullInput)
$slug = Normalize-Name $name

$streamsRoot = Join-Path $PSScriptRoot "streams"
$outputDir   = Join-Path $streamsRoot $slug
$playlist    = Join-Path $outputDir "index.m3u8"
$segments    = Join-Path $outputDir "segment_%03d.ts"

if (Test-Path $outputDir) {
    Remove-Item $outputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Write-Host "Input file:  $fullInput"
Write-Host "Stream slug: $slug"
Write-Host "Output dir:  $outputDir"
Write-Host ""

$args = @(
    "-y",
    "-i", $fullInput,
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-profile:v", "baseline",
    "-level", "3.0",
    "-c:a", "aac",
    "-ar", "48000",
    "-b:a", "128k",
    "-start_number", "0",
    "-hls_time", "6",
    "-hls_list_size", "0",
    "-hls_segment_filename", $segments,
    "-f", "hls",
    $playlist
)

Write-Host "Running FFmpeg..." -ForegroundColor Yellow
& ffmpeg @args

if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "HLS stream created successfully." -ForegroundColor Green
Write-Host "Playlist file: $playlist"
Write-Host "Stream URL:    http://127.0.0.1:5000/streams/$slug/index.m3u8" -ForegroundColor Green
