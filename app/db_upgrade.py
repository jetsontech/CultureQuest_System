from .db import get_db, db_execute, query_db
from flask import g

def ensure_platform_foundation():
    db = get_db()

    db.execute("""
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        display_name TEXT NOT NULL,
        is_admin INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS user_profiles (
        user_id INTEGER PRIMARY KEY,
        avatar_url TEXT DEFAULT '',
        favorite_genres TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id)
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS favorites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        channel_id INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(user_id, channel_id),
        FOREIGN KEY(user_id) REFERENCES users(id),
        FOREIGN KEY(channel_id) REFERENCES channels(id)
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS watch_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        channel_id INTEGER,
        asset_id INTEGER,
        watched_at TEXT NOT NULL,
        progress_seconds INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(user_id) REFERENCES users(id)
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS subscriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        plan_id INTEGER NOT NULL,
        provider TEXT DEFAULT 'manual',
        provider_ref TEXT DEFAULT '',
        status TEXT NOT NULL DEFAULT 'inactive',
        started_at TEXT DEFAULT '',
        ends_at TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id),
        FOREIGN KEY(plan_id) REFERENCES plans(id)
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS recordings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        channel_id INTEGER,
        title TEXT NOT NULL,
        starts_at TEXT DEFAULT '',
        ends_at TEXT DEFAULT '',
        status TEXT NOT NULL DEFAULT 'scheduled',
        output_path TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id)
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL
    )
    """)

    db.execute("""
    CREATE TABLE IF NOT EXISTS user_game_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER UNIQUE NOT NULL,
        gold INTEGER NOT NULL DEFAULT 0,
        xp INTEGER NOT NULL DEFAULT 0,
        level INTEGER NOT NULL DEFAULT 1,
        unlocked_artifacts TEXT NOT NULL DEFAULT '[]',
        dig_count INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
    )
    """)

    is_pg = g.get('db_type') == 'postgres'
    
    if is_pg:
        # PostgreSQL equivalent for checking columns
        existing = query_db("""
            SELECT column_name as name 
            FROM information_schema.columns 
            WHERE table_name = 'channels'
        """)
    else:
        existing = db_execute("PRAGMA table_info(channels)").fetchall()
    
    cols = {row['name'] for row in existing}
    wanted = {
        'fallback_stream_url': "TEXT DEFAULT ''",
        'logo_url': "TEXT DEFAULT ''",
        'health_status': "TEXT DEFAULT 'unknown'",
        'health_detail': "TEXT DEFAULT ''",
        'needs_relay': "INTEGER DEFAULT 0",
        'last_health_check': "TEXT DEFAULT ''",
    }
    for name, sql_type in wanted.items():
        if name not in cols:
            db_execute(f"ALTER TABLE channels ADD COLUMN {name} {sql_type}")

    seed_categories = [
        'Featured','Movies','Comedy','Drama','Crime','Reality','Documentaries',
        'News','Sports','Kids','Anime','Entertainment','Food','Travel','Music',
        'Latino','Local','Gaming / Games'
    ]
    for name in seed_categories:
        try:
            db_execute("INSERT INTO categories(name) VALUES (?)", (name,))
        except: pass

    db.execute("""
    CREATE TABLE IF NOT EXISTS cultures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        artifact_id TEXT UNIQUE NOT NULL,
        artifact_name TEXT NOT NULL,
        era TEXT NOT NULL,
        rarity TEXT NOT NULL,
        image_url TEXT NOT NULL
    )
    """)
    
    # Seed cultures
    seeds = [
        ('egypt_mask', 'Golden Mask of Tutankhamun', 'Ancient Egypt (1323 BC)', 'Legendary', 'https://images.unsplash.com/photo-1599118900389-236b28906606?auto=format&fit=crop&q=80&w=400'),
        ('maya_calendar', 'Maya Calendar Stone', 'Maya Civilization (900 AD)', 'Epic', 'https://images.unsplash.com/photo-1518709268805-4e9042af9f23?auto=format&fit=crop&q=80&w=400'),
        ('greece_vase', 'Attic Black-Figure Vase', 'Ancient Greece (530 BC)', 'Rare', 'https://images.unsplash.com/photo-1576016770956-debb63d92058?auto=format&fit=crop&q=80&w=400'),
        ('japan_samurai', 'Ancient Samurai Armor', 'Edo Period Japan (1700 AD)', 'Legendary', 'https://images.unsplash.com/photo-1549465220-1a8b9238cd48?auto=format&fit=crop&q=80&w=400'),
        ('benin_bronze', 'Benin Bronze Plaque', 'Kingdom of Benin (16th Century)', 'Epic', 'https://images.unsplash.com/photo-1615880484746-a114bebc0f8b?auto=format&fit=crop&q=80&w=400')
    ]
    for aid, name, era, rarity, url in seeds:
        try:
            db.execute("INSERT OR IGNORE INTO cultures (artifact_id, artifact_name, era, rarity, image_url) VALUES (?, ?, ?, ?, ?)", (aid, name, era, rarity, url))
        except: pass

    db.commit()
