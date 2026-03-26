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
