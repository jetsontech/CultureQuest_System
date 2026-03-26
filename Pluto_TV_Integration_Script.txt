# CultureQuest Pluto TV Integration Script
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   CultureQuest Pluto TV Integration   " -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# 1. Download Curated Pluto US M3U8 Playlist
$m3uUrl = "https://i.mjh.nz/PlutoTV/us.m3u8"
$m3uPath = ".\pluto_us.m3u8"
Write-Host "Downloading real Pluto TV channels..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $m3uUrl -OutFile $m3uPath

# 2. Run the specialized importer
# This uses your existing 'import_m3u.ps1' to load them into the SQLite DB
if (Test-Path ".\import_m3u.ps1") {
    Write-Host "Mapping channels to CultureQuest categories..." -ForegroundColor Yellow
    .\import_m3u.ps1 -M3UFile $m3uPath -Limit 200 -StartNumber 1000
} else {
    Write-Error "import_m3u.ps1 not found. Please ensure you are in your project root."
    exit
}

# 3. Clean up
Remove-Item $m3uPath
Write-Host ""
Write-Host "DONE! CultureQuest is now loaded with Pluto content." -ForegroundColor Green
Write-Host "Restarting CultureQuest..." -ForegroundColor Cyan
.\start.ps1