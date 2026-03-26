$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Run-Python {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & python @PyArgs
        return $LASTEXITCODE
    }
    & py @PyArgs
    return $LASTEXITCODE
}

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Stage 2 Upgrade" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# ---------------------------
# 1) Write schedule generator
# ---------------------------
$schedulePy = @'
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
import itertools

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "instance" / "culturequest.db"

conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# Clear only future schedules so reruns are deterministic
cur.execute("DELETE FROM schedules WHERE starts_at >= datetime('now')")

channels = cur.execute("""
    SELECT id, number, name, slug, category, is_active
    FROM channels
    WHERE is_active = 1
    ORDER BY number ASC
""").fetchall()

assets = cur.execute("""
    SELECT id, title, file_path, public_url, duration_seconds, media_type
    FROM assets
    WHERE COALESCE(media_type, 'video') IN ('video', 'audio')
    ORDER BY id ASC
""").fetchall()

if not channels:
    print("No active channels found.")
    conn.commit()
    conn.close()
    raise SystemExit(0)

if not assets:
    print("No assets found. Upload some media first in Admin > Assets.")
    conn.commit()
    conn.close()
    raise SystemExit(0)

# Basic asset pools by rough title/category heuristics
def classify(asset):
    t = (asset["title"] or "").lower()
    if any(x in t for x in ["sport", "game", "match", "recap"]):
        return "Sports"
    if any(x in t for x in ["news", "report", "update"]):
        return "News"
    if any(x in t for x in ["doc", "history", "story"]):
        return "Documentary"
    if any(x in t for x in ["kid", "family", "cartoon"]):
        return "Kids"
    if any(x in t for x in ["music", "concert", "jam"]):
        return "Music"
    if any(x in t for x in ["faith", "church", "gospel"]):
        return "Faith"
    return "General"

asset_buckets = {}
for a in assets:
    key = classify(a)
    asset_buckets.setdefault(key, []).append(a)
    asset_buckets.setdefault("General", []).append(a)

def channel_pool(channel):
    category = (channel["category"] or "General").strip()
    pool = asset_buckets.get(category)
    if pool and len(pool) > 0:
        return pool
    return asset_buckets.get("General", assets)

# Round to current half-hour
now = datetime.utcnow().replace(second=0, microsecond=0)
minute = 0 if now.minute < 30 else 30
cursor0 = now.replace(minute=minute)

HOURS_AHEAD = 72

created = 0

for channel in channels:
    pool = channel_pool(channel)
    cycler = itertools.cycle(pool)
    cursor = cursor0
    end_limit = cursor0 + timedelta(hours=HOURS_AHEAD)

    while cursor < end_limit:
        asset = next(cycler)
        dur = int(asset["duration_seconds"] or 1800)
        if dur < 60:
            dur = 60
        end_time = cursor + timedelta(seconds=dur)

        cur.execute("""
            INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override)
            VALUES (?, ?, ?, ?, ?)
        """, (
            channel["id"],
            asset["id"],
            cursor.isoformat(timespec="minutes"),
            end_time.isoformat(timespec="minutes"),
            None
        ))
        created += 1
        cursor = end_time

conn.commit()
conn.close()
print(f"Schedule rows created: {created}")
'@
Set-Content .\scripts\generate_schedule.py -Value $schedulePy -Encoding utf8

# ---------------------------
# 2) Write channel pack creator
# ---------------------------
$packPy = @'
import sqlite3
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "instance" / "culturequest.db"

PACK = [
    ("Beacon Movies", "Movies"),
    ("Beacon Series", "General"),
    ("Beacon News", "News"),
    ("Beacon Sports", "Sports"),
    ("Beacon Docs", "Documentary"),
    ("Beacon Music", "Music"),
    ("Beacon Kids", "Kids"),
    ("Beacon Faith", "Faith"),
    ("World View", "Documentary"),
    ("Community One", "Community"),
    ("Creator One", "Creators"),
    ("Night Lounge", "Music"),
    ("History Loop", "Documentary"),
    ("Family Time", "Kids"),
    ("Sports Recap", "Sports"),
    ("News Wire", "News"),
    ("Indie Replay", "General"),
    ("Creator Spotlight", "Creators"),
    ("Culture Stories", "Documentary"),
    ("Live Showcase", "General"),
]

def slugify(value: str) -> str:
    import re
    s = value.strip().lower()
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s or 'channel'

conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

rows = cur.execute("SELECT COALESCE(MAX(number), 199) AS m FROM channels").fetchone()
next_number = int(rows["m"]) + 1
created = 0
updated = 0

for name, category in PACK:
    slug = slugify(name)
    existing = cur.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()
    if existing:
        cur.execute("""
            UPDATE channels
            SET name=?, category=?, description=?, is_active=1
            WHERE slug=?
        """, (name, category, f"{name} scheduled channel", slug))
        updated += 1
    else:
        cur.execute("""
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?)
        """, (
            next_number,
            name,
            slug,
            f"{name} scheduled channel",
            category,
            "",
            datetime.utcnow().isoformat(timespec="seconds")
        ))
        next_number += 1
        created += 1

conn.commit()
conn.close()
print(f"Channels created: {created}")
print(f"Channels updated: {updated}")
'@
Set-Content .\scripts\create_channel_pack.py -Value $packPy -Encoding utf8

# ---------------------------
# 3) Write EPG template
# ---------------------------
$epgTemplate = @'
{% extends "base.html" %}
{% block title %}CultureQuest · EPG{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>EPG</h1>
    <p class="muted">Electronic program guide for scheduled channels.</p>
  </div>
  <span class="pill">72 Hours</span>
</div>

<div class="guide-shell">
  <div class="guide-row guide-head">
    <div>Channel</div>
    <div>Start</div>
    <div>End</div>
    <div>Program</div>
  </div>

  {% for row in epg %}
  <div class="guide-row">
    <div>{{ row['channel_name'] }}</div>
    <div>{{ row['starts_at'] }}</div>
    <div>{{ row['ends_at'] }}</div>
    <div>{{ row['program_title'] }}</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@
Set-Content .\app\templates\epg.html -Value $epgTemplate -Encoding utf8

# ---------------------------
# 4) Patch views.py
# ---------------------------
$viewsPath = ".\app\views.py"
$views = Get-Content $viewsPath -Raw

# Add EPG route if missing
if ($views -notmatch "@public_bp\.route\('/epg'\)") {
    $epgRoute = @"

@public_bp.route('/epg')
def epg():
    db = get_db()
    rows = db.execute('''
        SELECT
            s.starts_at,
            s.ends_at,
            c.name AS channel_name,
            COALESCE(s.title_override, a.title) AS program_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        WHERE s.ends_at >= datetime('now')
        ORDER BY c.number ASC, s.starts_at ASC
        LIMIT 500
    ''').fetchall()
    return render_template('epg.html', epg=rows)
"@
    $views += $epgRoute
}

# Replace channel_detail route with scheduled-playback-aware version
$pattern = "(?s)@public_bp\.route\('/channel/<slug>'\).*?return render_template\('channel_detail'.*?\n"
$replacement = @"
@public_bp.route('/channel/<slug>')
def channel_detail(slug):
    channel = get_channel_by_slug(slug)
    if not channel:
        flash('Channel not found.', 'danger')
        return redirect(url_for('public.beacon'))

    schedule = get_channel_schedule(channel['id'])
    guide = next((x for x in guide_items() if x['slug'] == slug), None)

    play_url = ''
    if guide and guide.get('stream_url'):
        play_url = guide['stream_url']
    elif channel.get('stream_url'):
        play_url = channel['stream_url']
    else:
        db = get_db()
        current_asset = db.execute('''
            SELECT a.*
            FROM schedules s
            JOIN assets a ON a.id = s.asset_id
            WHERE s.channel_id = ?
              AND s.starts_at <= datetime('now')
              AND s.ends_at >= datetime('now')
            ORDER BY s.starts_at ASC
            LIMIT 1
        ''', (channel['id'],)).fetchone()

        if current_asset:
            if current_asset['public_url']:
                play_url = current_asset['public_url']
            elif current_asset['file_path']:
                play_url = url_for('public.uploaded_file', filename=os.path.basename(current_asset['file_path']))

    return render_template('channel_detail.html', channel=channel, schedule=schedule, play_url=play_url, guide=guide)
"@

$views = [regex]::Replace($views, $pattern, $replacement)

# Make beacon route pass guide only, already correct in your app, keep safe
Set-Content $viewsPath -Value $views -Encoding utf8

# ---------------------------
# 5) Add EPG nav link in base.html if missing
# ---------------------------
$basePath = ".\app\templates\base.html"
$base = Get-Content $basePath -Raw
if ($base -notmatch "url_for\('public\.epg'\)") {
    $base = $base -replace "<a href=""\{\{ url_for\('public\.premium'\) \}\}"">Premium</a>", "<a href=""{{ url_for('public.premium') }}"">Premium</a>`r`n        <a href=""{{ url_for('public.epg') }}"">EPG</a>"
    Set-Content $basePath -Value $base -Encoding utf8
}

# ---------------------------
# 6) Run channel pack + scheduler
# ---------------------------
Write-Host "Creating channel pack..." -ForegroundColor Yellow
Run-Python ".\scripts\create_channel_pack.py"

Write-Host "Generating 72-hour schedules..." -ForegroundColor Yellow
Run-Python ".\scripts\generate_schedule.py"

Write-Host ""
Write-Host "Stage 2 upgrade complete." -ForegroundColor Green
Write-Host "Open these pages:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/beacon"
Write-Host "  http://127.0.0.1:5000/epg"
Write-Host "  http://127.0.0.1:5000/admin/assets"
Write-Host "  http://127.0.0.1:5000/admin/schedules"
Write-Host ""
Write-Host "Important: distinct channels require multiple uploaded assets or multiple real stream URLs." -ForegroundColor Yellow