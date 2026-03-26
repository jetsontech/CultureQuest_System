param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(Mandatory=$true)][string]$OutputDir
)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
ffmpeg -y -i $InputFile `
  -c:v libx264 `
  -preset veryfast `
  -c:a aac `
  -b:a 128k `
  -f hls `
  -hls_time 6 `
  -hls_list_size 0 `
  -hls_segment_filename "$OutputDir/segment_%03d.ts" `
  "$OutputDir/index.m3u8"
