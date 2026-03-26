$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "INITIALIZING 2026 CORE..." -ForegroundColor Cyan

$packs = @(
    @{ name="Samsung TV"; url="http://localhost:8182/playlist.m3u8" },
    @{ name="Pluto TV"; url="http://localhost:8080/playlist.m3u8" },
    @{ name="Global News"; url="https://iptv-org.github.io/iptv/categories/news.m3u" },
    @{ name="Action Pack"; url="https://aymrgknetzpucldhpkwm.supabase.co/storage/v1/object/public/tmdb/top-movies.m3u" }
)

foreach ($p in $packs) {
    Write-Host ("Syncing " + $p.name + "...") -ForegroundColor Yellow
    $tmp = ".\temp.m3u8"
    try {
        Invoke-WebRequest -Uri $p.url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        if (Test-Path ".\import_m3u.ps1") {
            .\import_m3u.ps1 -M3UFile $tmp -Limit 50 -StartNumber (Get-Random -Minimum 1000 -Maximum 9000)
        } else {
            Write-Host "import_m3u.ps1 not found. Skipping import." -ForegroundColor Red
        }
    } catch {
        Write-Host ("Skipping " + $p.name + " - Source Offline") -ForegroundColor Red
    } finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force
        }
    }
}

if (Test-Path ".\scripts\mirror_assets.py") {
    python .\scripts\mirror_assets.py
}

if (Test-Path ".\scripts\generate_schedule.py") {
    python .\scripts\generate_schedule.py
} else {
    Write-Host "generate_schedule.py not found. Skipping EPG generation." -ForegroundColor Yellow
}

Write-Host "DEPLOYMENT COMPLETE. CultureQuest is Live." -ForegroundColor Green
Write-Host "Start with .\start.ps1 or py .\run.py" -ForegroundColor Cyan
