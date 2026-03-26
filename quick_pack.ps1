$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$py = @'
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
import itertools
import re

ROOT = Path(__file__).resolve().parent
DB = ROOT / "instance" / "culturequest.db"

PACK = [
    ("Beacon Movies", "Movies"),
    ("Beacon News", "News"),
    ("Beacon Sports", "Sports"),
    ("Beacon Docs", "Documentary"),
    ("Beacon Music", "Music"),
    ("Beacon Kids", "Kids"),
    ("Creator One", "Creators"),
    ("Community One", "Community"),
    ("World View", "Documentary"),
    ("Night Lounge", "Music"),
    ("Family Time", "Kids"),
    ("Sports Recap", "Sports"),
]

def slugify(s):
    s = s.strip().lower()
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s or 'channel'

def classify(title):
    t = (title or "").lower()
    if "sport" in t or "game" in t or "match" in t or "recap" in t:
        return "Sports"
    if "news" in t or "report" in t or "update" in t:
        return "News"
    if "doc" in t or "history" in t or "story" in t:
        return "Documentary"
    if "kid" in t or "family" in t or "cartoon" in t:
        return "Kids"
    if "music" in t or "jam" in t or "concert" in t:
        return "Music"
    return "General"

conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# create/update channels
row = cur.execute("SELECT COALESCE(MAX(number), 100) AS m FROM channels").fetchone()
next_number = int(row["m"]) + 1

for name, category in PACK:
    slug = slugify(name)
    existing = cur.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()
    if existing:
        cur.execute("""
            UPDATE channels
            SET name=?, category=?, description=?, is_active=1
            WHERE slug=?
        """, (name, category, f"{name} scheduled channel", slug))
    else:
        cur.execute("""
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, '', 0, 1, ?)
        """, (next_number, name, slug, f"{name} scheduled channel", category, datetime.utcnow().isoformat(timespec="seconds")))
        next_number += 1

# clear future schedule
cur.execute("DELETE FROM schedules WHERE starts_at >= datetime('now')")

channels = cur.execute("""
    SELECT id, number, name, slug, category
    FROM channels
    WHERE is_active = 1
    ORDER BY number ASC
""").fetchall()

assets = cur.execute("""
    SELECT id, title, duration_seconds, media_type
    FROM assets
    WHERE COALESCE(media_type, 'video') IN ('video', 'audio')
    ORDER BY id ASC
""").fetchall()

if not assets:
    print("No assets found. Upload media first in Admin > Assets.")
    conn.commit()
    conn.close()
    raise SystemExit(0)

buckets = {}
for a in assets:
    key = classify(a["title"])
    buckets.setdefault(key, []).append(a)
    buckets.setdefault("General", []).append(a)

def pool_for(category):
    return buckets.get(category, buckets["General"])

now = datetime.utcnow().replace(second=0, microsecond=0)
minute = 0 if now.minute < 30 else 30
start = now.replace(minute=minute)
end_limit = start + timedelta(hours=48)

count = 0

for ch in channels:
    pool = pool_for(ch["category"] or "General")
    cycler = itertools.cycle(pool)
    cursor = start

    while cursor < end_limit:
        a = next(cycler)
        dur = int(a["duration_seconds"] or 1800)
        if dur < 60:
            dur = 60
        end = cursor + timedelta(seconds=dur)

        cur.execute("""
            INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override)
            VALUES (?, ?, ?, ?, ?)
        """, (ch["id"], a["id"], cursor.isoformat(timespec="minutes"), end.isoformat(timespec="minutes"), None))
        count += 1
        cursor = end

conn.commit()
conn.close()
print(f"Done. Schedule rows created: {count}")
'@

Set-Content .\_quick_pack.py -Value $py -Encoding utf8

if (Get-Command python -ErrorAction SilentlyContinue) {
    python .\_quick_pack.py
} else {
    py .\_quick_pack.py
}

Remove-Item .\_quick_pack.py -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Open these now:" -ForegroundColor Green
Write-Host "http://127.0.0.1:5000/beacon"
Write-Host "http://127.0.0.1:5000/epg"
Write-Host "http://127.0.0.1:5000/admin/assets"