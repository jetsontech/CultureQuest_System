$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$packs = @(
    @{ name="Global News"; url="https://iptv-org.github.io/iptv/categories/news.m3u" },
    @{ name="Movies Pack"; url="https://iptv-org.github.io/iptv/categories/movies.m3u" },
    @{ name="Sports Pack"; url="https://iptv-org.github.io/iptv/categories/sports.m3u" },
    @{ name="Action Movies"; url="https://aymrgknetzpucldhpkwm.supabase.co/storage/v1/object/public/tmdb/action-movies.m3u" }
)

Write-Host "Starting Bulk Content Ingestion..." -ForegroundColor Cyan

foreach ($pack in $packs) {
    Write-Host ("Syncing " + $pack.name + "...") -ForegroundColor Yellow
    $tempFile = ".\temp_playlist.m3u8"

    try {
        Invoke-WebRequest -Uri $pack.url -OutFile $tempFile -UseBasicParsing

        if (Test-Path ".\import_m3u.ps1") {
            .\import_m3u.ps1 -M3UFile $tempFile -Limit 50 -StartNumber (Get-Random -Minimum 1000 -Maximum 9000)
        } else {
            Write-Host "import_m3u.ps1 not found. Skipping import." -ForegroundColor Red
        }
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
    }
}

Write-Host "Downloading logos locally..." -ForegroundColor Cyan
if (Test-Path ".\scripts\download_logos.py") {
    python .\scripts\download_logos.py
}

if (Test-Path ".\scripts\generate_schedule.py") {
    Write-Host "Updating 72-hour EPG..." -ForegroundColor Cyan
    python .\scripts\generate_schedule.py
} else {
    Write-Host "generate_schedule.py not found. Skipping EPG generation." -ForegroundColor Yellow
}

Write-Host "HANDOVER COMPLETE: Platform synced." -ForegroundColor Green
