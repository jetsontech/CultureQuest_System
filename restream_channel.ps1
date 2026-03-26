param(
    [Parameter(Mandatory=$true)]
    [string]$Slug,

    [Parameter(Mandatory=$true)]
    [string]$SourceUrl
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$streamRoot = Join-Path $PSScriptRoot "streams"
$targetDir = Join-Path $streamRoot $Slug
$playlist = Join-Path $targetDir "index.m3u8"

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Restream Channel" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Slug      : $Slug"
Write-Host "Source    : $SourceUrl"
Write-Host "Output    : $playlist"
Write-Host ""

# kill older ffmpeg writing this same stream folder if needed
Get-Process ffmpeg -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path) { }
    } catch {}
}

$ffArgs = @(
    "-y",
    "-i", $SourceUrl,
    "-c", "copy",
    "-f", "hls",
    "-hls_time", "4",
    "-hls_list_size", "10",
    "-hls_flags", "delete_segments+append_list",
    "-hls_segment_filename", (Join-Path $targetDir "seg_%05d.ts"),
    $playlist
)

Write-Host "Starting FFmpeg restream..." -ForegroundColor Yellow
$proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffArgs -PassThru -WindowStyle Minimized

Write-Host ""
Write-Host "FFmpeg PID: $($proc.Id)" -ForegroundColor Green
Write-Host "Local stream URL:" -ForegroundColor Green
Write-Host "http://127.0.0.1:5000/streams/$Slug/index.m3u8"