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

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " CultureQuest Homepage + Sync + Logos Stage" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

Ensure-LineInFile ".\requirements.txt" "requests"

# -------------------------------------------------
# app/templates/home.html
# Restore a stronger original-style homepage
# -------------------------------------------------
$homeHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest{% endblock %}

{% block content %}
<section class="hero-shell">
  <div class="hero-panel">
    <div class="hero-copy">
      <div class="eyebrow">Featured Experience</div>
      <h1>Live now on CultureQuest</h1>
      <p>
        CultureQuest brings together live channels, global news, movies, sports,
        creator content, documentaries, games, and premium add-ons in one TV-style platform.
      </p>
      <div class="actions top-gap-sm">
        <a class="btn btn-primary" href="{{ url_for('public.beacon') }}">Watch Live TV</a>
        <a class="btn" href="{{ url_for('public.epg') }}">Open Guide</a>
      </div>
    </div>

    <div class="hero-side-grid">
      {% for channel in featured %}
      <a class="feature-tile" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }} · {{ channel['category'] or 'Featured' }}</span>
      </a>
      {% endfor %}
    </div>
  </div>
</section>

{% for row in category_rows %}
<section class="top-gap">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a class="pill" href="{{ url_for('public.category_page', category_name=row['name']) }}">View All</a>
  </div>
  <div class="browse-grid">
    {% for channel in row['channels'] %}
      <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        {% if channel.get('logo_url') %}
          <div class="logo-wrap top-gap-sm">
            <img src="{{ channel['logo_url'] }}" alt="{{ channel['name'] }} logo" class="channel-logo">
          </div>
        {% endif %}
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }}{% if channel['category'] %} · {{ channel['category'] }}{% endif %}</span>
      </a>
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\home.html" $homeHtml

# -------------------------------------------------
# app/templates/beacon.html
# TV-style category rails
# -------------------------------------------------
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Browse channels by category, like a modern FAST platform.</p>
  </div>
  <span class="pill">{{ channels|length }} Channels</span>
</div>

{% for row in category_rows %}
<section class="top-gap">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a class="pill" href="{{ url_for('public.category_page', category_name=row['name']) }}">View All</a>
  </div>
  <div class="browse-grid">
    {% for channel in row['channels'] %}
      <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        {% if channel.get('logo_url') %}
          <div class="logo-wrap top-gap-sm">
            <img src="{{ channel['logo_url'] }}" alt="{{ channel['name'] }} logo" class="channel-logo">
          </div>
        {% endif %}
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }}{% if channel['category'] %} · {{ channel['category'] }}{% endif %}</span>
      </a>
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\beacon.html" $beaconHtml

# -------------------------------------------------
# app/templates/category_page.html
# -------------------------------------------------
$categoryPageHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · {{ category_name }}{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>{{ category_name }}</h1>
    <p class="muted">Channels in this category.</p>
  </div>
  <a class="btn" href="{{ url_for('public.beacon') }}">Back to Live TV</a>
</div>

<div class="browse-grid">
  {% for channel in channels %}
    <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
      {% if channel.get('logo_url') %}
        <div class="logo-wrap top-gap-sm">
          <img src="{{ channel['logo_url'] }}" alt="{{ channel['name'] }} logo" class="channel-logo">
        </div>
      {% endif %}
      <strong>{{ channel['name'] }}</strong>
      <span>CH {{ channel['number'] }}</span>
    </a>
  {% endfor %}
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\category_page.html" $categoryPageHtml

# -------------------------------------------------
# app/static/style.css append for logos if missing
# -------------------------------------------------
$cssAppend = @'

.logo-wrap{display:flex;align-items:center;justify-content:flex-start;min-height:48px}
.channel-logo{max-height:42px;max-width:140px;object-fit:contain;border-radius:10px}
'@
if (Test-Path ".\app\static\style.css") {
    $css = Get-Content ".\app\static\style.css" -Raw
    if ($css -notmatch "channel-logo") {
        Add-Content ".\app\static\style.css" $cssAppend
        Write-Host "Updated app\static\style.css" -ForegroundColor Green
    }
}

# -------------------------------------------------
# scripts/download_logos.py
# Download remote logos and rewrite DB to local static files
# -------------------------------------------------
$downloadLogosPy = @'
import os
import re
import sqlite3
from urllib.parse import urlparse
import requests

DB = r".\instance\culturequest.db"
LOGO_DIR = r".\app\static\logos"

os.makedirs(LOGO_DIR, exist_ok=True)

db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row
cur = db.cursor()

# ensure logo_url column exists
cols = [r[1] for r in cur.execute("PRAGMA table_info(channels)").fetchall()]
if "logo_url" not in cols:
    cur.execute("ALTER TABLE channels ADD COLUMN logo_url TEXT DEFAULT ''")
    db.commit()

rows = cur.execute("SELECT id, slug, logo_url FROM channels").fetchall()

downloaded = 0
skipped = 0

for row in rows:
    logo = (row["logo_url"] or "").strip()
    if not logo:
        skipped += 1
        continue

    if logo.startswith("/static/logos/"):
        skipped += 1
        continue

    if not (logo.startswith("http://") or logo.startswith("https://")):
        skipped += 1
        continue

    try:
        resp = requests.get(logo, timeout=15)
        resp.raise_for_status()

        parsed = urlparse(logo)
        ext = os.path.splitext(parsed.path)[1].lower()
        if ext not in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg"]:
            ext = ".png"

        safe = re.sub(r"[^a-zA-Z0-9_-]+", "-", row["slug"]) + ext
        out_path = os.path.join(LOGO_DIR, safe)

        with open(out_path, "wb") as f:
            f.write(resp.content)

        local_url = f"/static/logos/{safe}"
        cur.execute("UPDATE channels SET logo_url = ? WHERE id = ?", (local_url, row["id"]))
        downloaded += 1
    except Exception:
        skipped += 1

db.commit()
db.close()

print(f"downloaded={downloaded}")
print(f"skipped={skipped}")
'@
Write-Utf8File ".\scripts\download_logos.py" $downloadLogosPy

# -------------------------------------------------
# sync_global_content.ps1
# Safer version of your bulk content sync
# -------------------------------------------------
$syncPs1 = @'
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
'@
Write-Utf8File ".\sync_global_content.ps1" $syncPs1

Write-Host ""
Write-Host "Installing requirements..." -ForegroundColor Yellow
pip install -r .\requirements.txt

Write-Host ""
Write-Host "Stage complete." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Yellow
Write-Host "  py .\run.py"
Write-Host ""
Write-Host "Optional content sync:" -ForegroundColor Yellow
Write-Host "  .\sync_global_content.ps1"