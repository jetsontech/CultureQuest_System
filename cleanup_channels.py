import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

# disable demo/jam channels
cur.execute("""
    UPDATE channels
    SET is_active = 0
    WHERE
        lower(name) LIKE '%demo%'
        OR lower(slug) LIKE '%demo%'
        OR lower(stream_url) LIKE '%/streams/jam/%'
""")

# disable anything not healthy
cur.execute("""
    UPDATE channels
    SET is_active = 0
    WHERE health_status IS NOT NULL
      AND health_status NOT IN ('healthy')
""")

# keep healthy channels active
cur.execute("""
    UPDATE channels
    SET is_active = 1
    WHERE health_status = 'healthy'
""")

db.commit()
db.close()

print("Disabled demo/jam and non-healthy channels.")
