import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

# delete imported channels from number 315 and up
cur.execute("DELETE FROM channels WHERE number >= 315")

db.commit()
db.close()

print("Deleted imported channels with number >= 315")
