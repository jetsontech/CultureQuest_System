param(
    [string]$PlaylistUrl = "https://iptv-org.github.io/iptv/countries/us.m3u",
    [string]$PlaylistPath = ".\us.m3u",
    [int]$ImportLimit = 200,
    [int]$StartNumber = 500,
    [int]$VerifyLimit = 80
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Run-Python {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)
    if (Get-Command python -ErrorAction SilentlyContinue) {
        & python @PyArgs
        return $LASTEXITCODE
    }
    & py @PyArgs
    return $LASTEXITCODE
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest US Verified Import" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# 1) Download US playlist
Write-Host "Downloading US playlist..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $PlaylistUrl -OutFile $PlaylistPath
Write-Host "Saved: $PlaylistPath" -ForegroundColor Green

# 2) Remove previously imported US test block
$cleanPy = @'
import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

# remove prior imported test range
cur.execute("DELETE FROM channels WHERE number >= 500")
db.commit()
db.close()

print("Deleted channels with number >= 500")
'@
Set-Content .\_clean_us_tmp.py -Value $cleanPy -Encoding utf8
Run-Python ".\_clean_us_tmp.py" | Out-Null
Remove-Item .\_clean_us_tmp.py -Force -ErrorAction SilentlyContinue

# 3) Import M3U into DB
Write-Host "Importing US channels..." -ForegroundColor Yellow
& .\import_m3u.ps1 -M3UFile $PlaylistPath -Limit $ImportLimit -StartNumber $StartNumber

# 4) Verify imported channels
$verifyPy = @"
import sqlite3
import urllib.request
import urllib.error
import ssl
from concurrent.futures import ThreadPoolExecutor, as_completed

DB = r".\instance\culturequest.db"
VERIFY_LIMIT = $VerifyLimit

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row
cur = db.cursor()

rows = cur.execute(
    '''
    SELECT id, number, name, slug, stream_url
    FROM channels
    WHERE number >= 500
    ORDER BY number ASC
    LIMIT ?
    ''',
    (VERIFY_LIMIT,)
).fetchall()

def check_channel(row):
    url = (row["stream_url"] or "").strip()
    if not url:
        return (row["id"], False, "blank")

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "*/*",
        },
        method="GET"
    )

    try:
        with urllib.request.urlopen(req, timeout=10, context=ssl_ctx) as resp:
            status = getattr(resp, "status", 200)
            content_type = resp.headers.get("Content-Type", "")
            body = resp.read(4096)

        text = ""
        try:
            text = body.decode("utf-8", errors="ignore")
        except Exception:
            text = ""

        looks_like_hls = (
            "#EXTM3U" in text
            or ".ts" in text
            or ".m4s" in text
            or "application/vnd.apple.mpegurl" in content_type.lower()
            or "application/x-mpegurl" in content_type.lower()
        )

        ok = status == 200 and looks_like_hls
        reason = f"status={status}, type={content_type or 'unknown'}"
        return (row["id"], ok, reason)

    except Exception as e:
        return (row["id"], False, str(e)[:180])

results = []
with ThreadPoolExecutor(max_workers=10) as ex:
    futs = [ex.submit(check_channel, row) for row in rows]
    for fut in as_completed(futs):
        results.append(fut.result())

ok_count = 0
bad_count = 0

for channel_id, ok, reason in results:
    cur.execute(
        "UPDATE channels SET is_active = ? WHERE id = ?",
        (1 if ok else 0, channel_id)
    )
    if ok:
        ok_count += 1
    else:
        bad_count += 1

db.commit()

working = cur.execute(
    '''
    SELECT number, name, slug, stream_url
    FROM channels
    WHERE number >= 500 AND is_active = 1
    ORDER BY number ASC
    LIMIT 25
    '''
).fetchall()

print(f"Verified OK: {ok_count}")
print(f"Disabled   : {bad_count}")
print("")
print("Top working channels:")
for row in working:
    print(f'{row["number"]} | {row["name"]} | {row["slug"]}')
db.close()
"@

Set-Content .\_verify_us_tmp.py -Value $verifyPy -Encoding utf8
Write-Host "Verifying imported streams..." -ForegroundColor Yellow
Run-Python ".\_verify_us_tmp.py"
Remove-Item .\_verify_us_tmp.py -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Now restart Flask and open:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/beacon"
Write-Host "  http://127.0.0.1:5000/admin/channels"