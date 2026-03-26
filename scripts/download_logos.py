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
