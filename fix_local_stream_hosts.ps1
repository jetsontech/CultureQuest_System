$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CultureQuest Cleanup Stream Errors Fix" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Disable demo/jam channels and weak ones
@'
import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

# disable demo/jam channels
cur.execute("""
    UPDATE channels
    SET is_active = 0
    WHERE
        lower(name) LIKE '%demo%'
        OR lower(slug) LIKE '%demo%'
        OR lower(stream_url) LIKE '%/streams/jam/%'
""")

# disable anything not healthy
cur.execute("""
    UPDATE channels
    SET is_active = 0
    WHERE health_status IS NOT NULL
      AND health_status NOT IN ('healthy')
""")

# keep healthy channels active
cur.execute("""
    UPDATE channels
    SET is_active = 1
    WHERE health_status = 'healthy'
""")

db.commit()
db.close()

print("Disabled demo/jam and non-healthy channels.")
'@ | Set-Content .\cleanup_channels.py -Encoding utf8

python .\cleanup_channels.py

Write-Host ""
Write-Host "Cleanup complete." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Green
Write-Host "py .\run.py"