import sqlite3
import ssl
import urllib.request
import urllib.error
from datetime import datetime

DB = r".\instance\culturequest.db"

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE


def fetch(url, limit=4096):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "*/*",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=12, context=ssl_ctx) as resp:
        body = resp.read(limit)
        status = getattr(resp, "status", 200)
        content_type = resp.headers.get("Content-Type", "")
    return status, content_type, body


db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row
cur = db.cursor()

rows = cur.execute("""
    SELECT id, slug, name, stream_url, fallback_stream_url
    FROM channels
    ORDER BY number ASC
""").fetchall()

healthy = 0
manifest_ok = 0
relay_needed = 0
offline = 0

for row in rows:
    url = (row["stream_url"] or "").strip()
    fallback = (row["fallback_stream_url"] or "").strip()

    status_value = "offline"
    detail = "blank stream_url"
    needs_relay = 0
    active = 0

    urls_to_try = [u for u in [url, fallback] if u]

    for candidate in urls_to_try:
        try:
            status, content_type, body = fetch(candidate)
            text = body.decode("utf-8", errors="ignore")

            if status == 200 and ("#EXTM3U" in text or "mpegurl" in content_type.lower()):
                status_value = "manifest_ok"
                detail = f"manifest reachable via {candidate}"
                needs_relay = 1
                active = 1

                # crude segment hint
                if ".ts" in text or ".m4s" in text or "#EXTINF" in text:
                    status_value = "healthy"
                    detail = f"manifest + segments hinted via {candidate}"
                    needs_relay = 0

                break

        except Exception as e:
            detail = str(e)[:180]

    if status_value == "healthy":
        healthy += 1
    elif status_value == "manifest_ok":
        manifest_ok += 1
        needs_relay = 1
    elif status_value == "relay_needed":
        relay_needed += 1
    else:
        offline += 1

    if status_value == "manifest_ok":
        relay_needed += 1

    cur.execute(
        """
        UPDATE channels
        SET health_status = ?,
            health_detail = ?,
            needs_relay = ?,
            is_active = ?,
            last_health_check = ?
        WHERE id = ?
        """,
        (
            status_value,
            detail,
            needs_relay,
            active,
            datetime.utcnow().isoformat(timespec="seconds"),
            row["id"],
        ),
    )

db.commit()
db.close()

print(f"healthy={healthy}")
print(f"manifest_ok={manifest_ok}")
print(f"relay_needed={relay_needed}")
print(f"offline={offline}")
