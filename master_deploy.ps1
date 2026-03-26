# CultureQuest Master Execution v2.0
Write-Host "INITIALIZING 2026 LIQUID GLASS CORE..." -ForegroundColor Cyan

# 1. content ingestion (Samsung TV+, Tubi, and Global Lists)
$packs = @(
    @{ name="Samsung TV+"; url="http://localhost:8182/playlist.m3u8" },
    @{ name="Tubi Live"; url="http://localhost:7779/playlist.m3u8" },
    @{ name="Movies Pack"; url="https://iptv-org.github.io/iptv/categories/movies.m3u" },
    @{ name="Global News"; url="https://iptv-org.github.io/iptv/categories/news.m3u" }
)

foreach ($p in $packs) {
    Write-Host "Syncing $($p.name)..." -ForegroundColor Yellow
    $tmp = ".\temp.m3u8"
    try {
        Invoke-WebRequest -Uri $p.url -OutFile $tmp -ErrorAction Stop
        .\import_m3u.ps1 -M3UFile $tmp -Limit 50 -StartNumber (Get-Random -Min 1000 -Max 9000)
        Remove-Item $tmp
    } catch { Write-Host "Skipping $($p.name) - Source requires active Docker or is offline." -ForegroundColor Red }
}

# 2. Logic Calibration
Write-Host "Mirroring logos for local hosting..." -ForegroundColor Cyan
python .\scripts\mirror_assets.py

Write-Host "Enriching EPG with TMDB Metadata..." -ForegroundColor Cyan
python .\scripts\smart_meta.py

Write-Host "Updating 72-hour Schedule..." -ForegroundColor Cyan
python .\scripts\generate_schedule.py

# 3. Final Launch
Write-Host "MASTER DEPLOYMENT COMPLETE. CultureQuest is Live." -ForegroundColor Green
.\start.ps1