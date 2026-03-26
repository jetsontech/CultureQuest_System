import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute("UPDATE channels SET is_active = 1")
db.commit()
db.close()

print("All channels activated.")
