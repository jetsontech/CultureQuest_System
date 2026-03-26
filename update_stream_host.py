import sqlite3

OLD = "127.0.0.1"
NEW = "10.0.0.9"   # change to your PC IP

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute(
    "UPDATE channels SET stream_url = REPLACE(stream_url, ?, ?)",
    (OLD, NEW)
)

db.commit()
db.close()

print("Updated stream URLs to network IP.")