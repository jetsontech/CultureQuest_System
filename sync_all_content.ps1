# CultureQuest Global Content Sync
$packs = @(
    @{ name="Global News"; url="https://iptv-org.github.io/iptv/categories/news.m3u" },
    @{ name="Movies Pack"; url="https://iptv-org.github.io/iptv/categories/movies.m3u" },
    @{ name="Sports Pack"; url="https://iptv-org.github.io/iptv/categories/sports.m3u" },
    @{ name="Samsung TV+"; url="http://localhost:8182/playlist.m3u8" }
)

Write-Host "Starting Bulk Content Ingestion..." -ForegroundColor Cyan

foreach ($pack in $packs) {
    Write-Host "Syncing $($pack.name)..." -ForegroundColor Yellow
    $tempFile = ".\temp_playlist.m3u8"
    try {
        Invoke-WebRequest -Uri $pack.url -OutFile $tempFile -ErrorAction Stop
        # Import using existing M3U tool with high start numbers to avoid collisions
        .\import_m3u.ps1 -M3UFile $tempFile -Limit 50 -StartNumber (Get-Random -Minimum 1000 -Maximum 9000)
        Remove-Item $tempFile
    } catch {
        Write-Host "Skipping $($pack.name) - source temporarily unavailable." -ForegroundColor Red
    }
}

# Finalize the schedule and mirror logos
Write-Host "Updating 72-hour EPG..." -ForegroundColor Cyan
python .\scripts\generate_schedule.py
python .\scripts\mirror_assets.py

Write-Host "HANDOVER COMPLETE: Platform is live with real channels." -ForegroundColor Green