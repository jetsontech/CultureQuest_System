import sqlite3
import sys

if len(sys.argv) != 3:
    print("Usage: python set_channel_local_stream.py <slug> <local_url>")
    sys.exit(1)

slug = sys.argv[1]
local_url = sys.argv[2]

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute(
    "UPDATE channels SET stream_url = ? WHERE slug = ?",
    (local_url, slug)
)

db.commit()
db.close()

print(f"Updated {slug} -> {local_url}")