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
