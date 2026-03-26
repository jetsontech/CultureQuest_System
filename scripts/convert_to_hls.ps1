param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(Mandatory=$true)][string]$OutputName
)

function Normalize-Name {
    param([string]$Name)
    $n = $Name.ToLower()
    $n = $n -replace '\.[^.]+$',''
    $n = $n -replace '[^a-z0-9]+','-'
    $n = $n.Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = "stream" }
    return $n
}

$normalizedName = Normalize-Name $OutputName
$outputDir = Join-Path $PSScriptRoot "..\streams\$normalizedName"
$outputDir = [System.IO.Path]::GetFullPath($outputDir)

if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$playlistPath = Join-Path $outputDir "index.m3u8"
$segmentPattern = Join-Path $outputDir "segment_%03d.ts"

Write-Host "Input file: $InputFile"
Write-Host "Output dir: $outputDir"

& ffmpeg `
  -y `
  -i "$InputFile" `
  -c:v libx264 `
  -profile:v baseline `
  -level 3.0 `
  -c:a aac `
  -ar 48000 `
  -b:a 128k `
  -start_number 0 `
  -hls_time 6 `
  -hls_list_size 0 `
  -hls_segment_filename "$segmentPattern" `
  -f hls `
  "$playlistPath"

if ($LASTEXITCODE -ne 0) {
    Write-Error "FFmpeg failed."
    exit 1
}

Write-Host ""
Write-Host "HLS stream created successfully."
Write-Host "Local playlist: $playlistPath"
Write-Host "Web URL: http://127.0.0.1:5000/streams/$normalizedName/index.m3u8"
