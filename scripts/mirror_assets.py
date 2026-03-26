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
