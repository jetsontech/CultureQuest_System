$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Content | Set-Content -Path $Path -Encoding utf8
    Write-Host ("Wrote " + $Path) -ForegroundColor Green
}

function Ensure-LineInFile {
    param(
        [string]$Path,
        [string]$Line
    )
    if (!(Test-Path $Path)) {
        $Line | Set-Content -Path $Path -Encoding utf8
        return
    }
    $content = Get-Content $Path -Raw
    if ($content -notmatch [regex]::Escape($Line)) {
        Add-Content -Path $Path -Value $Line
        Write-Host ("Added to " + $Path + ": " + $Line) -ForegroundColor Green
    }
}

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   CultureQuest 2026 Core Installer   " -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

Ensure-LineInFile ".\requirements.txt" "requests"

# ---------------------------------------------------
# 1) Liquid Glass CSS layer
# ---------------------------------------------------
if (Test-Path ".\app\static\style.css") {
    $css = Get-Content ".\app\static\style.css" -Raw
    if ($css -notmatch "2026 Liquid Glass Architecture") {
        Add-Content ".\app\static\style.css" @'

/* 2026 Liquid Glass Architecture */
:root {
  --glass: rgba(255, 255, 255, 0.03);
  --glass-border: rgba(255, 255, 255, 0.08);
  --glass-shine: rgba(255, 255, 255, 0.12);
  --accent: #e50914;
}

body {
  background: radial-gradient(circle at 50% -20%, #1a2132 0%, #05070a 70%);
  color: #f0f2f5;
  font-family: Inter, 'Segoe UI', Arial, sans-serif;
}

.rail-card {
  flex: 0 0 260px;
  background: var(--glass);
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  border: 1px solid var(--glass-border);
  border-top: 1px solid var(--glass-shine);
  border-radius: 20px;
  padding: 12px;
  transition: all 0.4s cubic-bezier(0.165, 0.84, 0.44, 1);
}

.rail-card:hover {
  transform: translateY(-8px) scale(1.02);
  background: rgba(255, 255, 255, 0.06);
  border-color: rgba(255, 255, 255, 0.2);
}

.live-badge.pulse {
  background: var(--accent);
  animation: pulse-red 2s infinite;
}

@keyframes pulse-red {
  0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(229, 9, 20, 0.7); }
  70% { transform: scale(1); box-shadow: 0 0 0 10px rgba(229, 9, 20, 0); }
  100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(229, 9, 20, 0.7); }
}

.glass-blur{
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
}

.glass-card{
  background: linear-gradient(180deg, rgba(255,255,255,.12), rgba(255,255,255,.05));
  border: 1px solid rgba(255,255,255,.12);
  box-shadow: 0 18px 60px rgba(0,0,0,.28);
}

.scrolling-rail{
  display:flex;
  gap:16px;
  overflow-x:auto;
  padding-bottom:8px;
  scroll-behavior:smooth;
}

.scrolling-rail::-webkit-scrollbar{
  height:10px;
}

.scrolling-rail::-webkit-scrollbar-thumb{
  background:rgba(255,255,255,.12);
  border-radius:999px;
}

.rail-poster{
  height:150px;
  position:relative;
  border-radius:18px;
  background:linear-gradient(135deg,#263246,#101722);
  margin-bottom:10px;
}

.rail-meta h3{
  margin:0 0 8px 0;
  font-size:1rem;
}

.rail-meta p{
  margin:0;
  color:#aeb7ca;
  font-size:.92rem;
}
'@
        Write-Host "Updated app\static\style.css" -ForegroundColor Green
    } else {
        Write-Host "Liquid Glass CSS already present." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------
# 2) mirror_assets.py
# ---------------------------------------------------
$mirrorAssets = @'
import os
import sqlite3
import requests

DB = r".\instance\culturequest.db"
LOGO_DIR = r".\app\static\logos"

def mirror_logos():
    os.makedirs(LOGO_DIR, exist_ok=True)

    conn = sqlite3.connect(DB)
    cur = conn.cursor()

    cols = [r[1] for r in cur.execute("PRAGMA table_info(channels)").fetchall()]
    if "logo_url" not in cols:
        cur.execute("ALTER TABLE channels ADD COLUMN logo_url TEXT DEFAULT ''")
        conn.commit()

    channels = cur.execute(
        "SELECT id, logo_url FROM channels WHERE logo_url LIKE 'http%'"
    ).fetchall()

    for cid, url in channels:
        try:
            filename = f"ch_{cid}.png"
            path = os.path.join(LOGO_DIR, filename)
            if not os.path.exists(path):
                r = requests.get(url, timeout=5)
                r.raise_for_status()
                with open(path, "wb") as f:
                    f.write(r.content)
            cur.execute(
                "UPDATE channels SET logo_url = ? WHERE id = ?",
                (f"/static/logos/{filename}", cid),
            )
        except Exception:
            continue

    conn.commit()
    conn.close()

if __name__ == "__main__":
    mirror_logos()
'@
Write-Utf8File ".\scripts\mirror_assets.py" $mirrorAssets

# ---------------------------------------------------
# 3) master_sync.ps1
# ---------------------------------------------------
$masterSync = @'
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
'@
Write-Utf8File ".\master_sync.ps1" $masterSync

# ---------------------------------------------------
# 4) Patch channel_detail.html for lowLatencyMode true
# ---------------------------------------------------
if (Test-Path ".\app\templates\channel_detail.html") {
    $html = Get-Content ".\app\templates\channel_detail.html" -Raw
    $orig = $html

    $html = $html -replace 'lowLatencyMode:\s*false', 'lowLatencyMode: true'

    if ($html -ne $orig) {
        Set-Content ".\app\templates\channel_detail.html" -Value $html -Encoding utf8
        Write-Host "Updated channel_detail.html lowLatencyMode=true" -ForegroundColor Green
    } else {
        Write-Host "channel_detail.html already patched or setting not found." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------
# 5) Patch hls_proxy.py for CORS + header spoofing if present
# ---------------------------------------------------
if (Test-Path ".\app\hls_proxy.py") {
    $proxy = Get-Content ".\app\hls_proxy.py" -Raw
    $origProxy = $proxy

    if ($proxy -notmatch 'User-Agent') {
        $proxy = $proxy -replace 'SESSION = requests\.Session\(\)', @'
SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "Mozilla/5.0",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9"
})
'@
    }

    if ($proxy -notmatch 'Access-Control-Allow-Origin') {
        $proxy = $proxy -replace 'return Response\(resp\.content, content_type=content_type\)', 'return Response(resp.content, content_type=content_type, headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"})'
        $proxy = $proxy -replace 'return Response\(new_manifest, content_type="application/vnd\.apple\.mpegurl"\)', 'return Response(new_manifest, content_type="application/vnd.apple.mpegurl", headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"})'
        $proxy = $proxy -replace 'return Response\(\s*"\n"\.join\(out_lines\),\s*content_type="application/vnd\.apple\.mpegurl"\s*\)', 'return Response("\n".join(out_lines), content_type="application/vnd.apple.mpegurl", headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"})'
    }

    if ($proxy -ne $origProxy) {
        Set-Content ".\app\hls_proxy.py" -Value $proxy -Encoding utf8
        Write-Host "Patched app\hls_proxy.py for CORS/header spoofing" -ForegroundColor Green
    } else {
        Write-Host "app\hls_proxy.py already patched or pattern not found." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------
# 6) Install requirements
# ---------------------------------------------------
Write-Host ""
Write-Host "Installing requirements..." -ForegroundColor Yellow
pip install -r .\requirements.txt

Write-Host ""
Write-Host "2026 core installed." -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  .\master_sync.ps1"
Write-Host "  py .\run.py"