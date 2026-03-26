import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute("UPDATE channels SET is_active = 0 WHERE number < 500")
cur.execute("UPDATE channels SET is_active = 1 WHERE number >= 500")

db.commit()
db.close()

print("Disabled old channels below 500 and kept US verified channels active.")
