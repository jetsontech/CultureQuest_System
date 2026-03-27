import sqlite3
import os
import sys
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

# Load credentials
load_dotenv()

# Drop in reverse order of dependencies, Create in order
SCHEMA = r'''
-- DROP EXISTING TABLES (Reverse Order)
DROP TABLE IF EXISTS user_game_state CASCADE;
DROP TABLE IF EXISTS recordings CASCADE;
DROP TABLE IF EXISTS subscriptions CASCADE;
DROP TABLE IF EXISTS watch_history CASCADE;
DROP TABLE IF EXISTS favorites CASCADE;
DROP TABLE IF EXISTS schedules CASCADE;
DROP TABLE IF EXISTS assets CASCADE;
DROP TABLE IF EXISTS plans CASCADE;
DROP TABLE IF EXISTS channels CASCADE;
DROP TABLE IF EXISTS user_profiles CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS categories CASCADE;

-- CREATE TABLES
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_profiles (
    user_id INTEGER PRIMARY KEY,
    avatar_url TEXT DEFAULT '',
    favorite_genres TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS channels (
    id SERIAL PRIMARY KEY,
    number INTEGER UNIQUE NOT NULL,
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    description TEXT,
    category TEXT NOT NULL,
    logo_url TEXT DEFAULT '',
    poster_url TEXT,
    stream_url TEXT,
    fallback_stream_url TEXT DEFAULT '',
    health_status TEXT DEFAULT 'unknown',
    health_detail TEXT DEFAULT '',
    needs_relay INTEGER DEFAULT 0,
    last_health_check TEXT DEFAULT '',
    now_playing TEXT DEFAULT '',
    is_premium INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS assets (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    description TEXT,
    file_path TEXT,
    public_url TEXT,
    duration_seconds INTEGER DEFAULT 0,
    media_type TEXT NOT NULL DEFAULT 'video',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS schedules (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL,
    asset_id INTEGER NOT NULL,
    starts_at TIMESTAMP WITH TIME ZONE NOT NULL,
    ends_at TIMESTAMP WITH TIME ZONE NOT NULL,
    title_override TEXT,
    FOREIGN KEY(channel_id) REFERENCES channels(id) ON DELETE CASCADE,
    FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS plans (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    price_cents INTEGER NOT NULL,
    billing_interval TEXT NOT NULL,
    description TEXT,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS favorites (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, channel_id),
    FOREIGN KEY(user_id) REFERENCES users(id),
    FOREIGN KEY(channel_id) REFERENCES channels(id)
);

CREATE TABLE IF NOT EXISTS watch_history (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER,
    asset_id INTEGER,
    watched_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    progress_seconds INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    plan_id INTEGER NOT NULL,
    provider TEXT DEFAULT 'manual',
    provider_ref TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'inactive',
    started_at TEXT DEFAULT '',
    ends_at TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id),
    FOREIGN KEY(plan_id) REFERENCES plans(id)
);

CREATE TABLE IF NOT EXISTS recordings (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER,
    title TEXT NOT NULL,
    starts_at TEXT DEFAULT '',
    ends_at TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'scheduled',
    output_path TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS user_game_state (
    id SERIAL PRIMARY KEY,
    user_id INTEGER UNIQUE NOT NULL,
    gold INTEGER NOT NULL DEFAULT 0,
    xp INTEGER NOT NULL DEFAULT 0,
    level INTEGER NOT NULL DEFAULT 1,
    unlocked_artifacts TEXT NOT NULL DEFAULT '[]',
    dig_count INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);
'''

# Specialized queries to skip orphans during migration
QUERIES = {
    'schedules': 'SELECT * FROM schedules WHERE channel_id IN (SELECT id FROM channels) AND asset_id IN (SELECT id FROM assets)',
    'favorites': 'SELECT * FROM favorites WHERE user_id IN (SELECT id FROM users) AND channel_id IN (SELECT id FROM channels)',
    'watch_history': 'SELECT * FROM watch_history WHERE user_id IN (SELECT id FROM users)',
    'subscriptions': 'SELECT * FROM subscriptions WHERE user_id IN (SELECT id FROM users) AND plan_id IN (SELECT id FROM plans)',
    'recordings': 'SELECT * FROM recordings WHERE user_id IN (SELECT id FROM users)',
    'user_game_state': 'SELECT * FROM user_game_state WHERE user_id IN (SELECT id FROM users)',
    'user_profiles': 'SELECT * FROM user_profiles WHERE user_id IN (SELECT id FROM users)',
}

def migrate():
    sqlite_path = os.path.join("instance", "culturequest.db")
    db_url = os.getenv("DATABASE_URL")
    
    if not os.path.exists(sqlite_path):
        print(f"Error: {sqlite_path} not found.")
        return
    
    if not db_url:
        print("Error: DATABASE_URL not set in .env")
        return
        
    print(f"Connecting to Local SQLite: {sqlite_path}")
    sl_conn = sqlite3.connect(sqlite_path)
    sl_conn.row_factory = sqlite3.Row
    sl_cur = sl_conn.cursor()
    
    print(f"Connecting to Supabase PostgreSQL...")
    if db_url.startswith("postgres://"):
        db_url = db_url.replace("postgres://", "postgresql://", 1)
    
    pg_conn = psycopg2.connect(db_url)
    pg_cur = pg_conn.cursor()
    
    print("Purging and Re-initialising Full Production Schema on Supabase...")
    pg_cur.execute(SCHEMA)
    pg_conn.commit()

    # Migration Order is important for Foreign Keys
    tables = [
        'users', 'user_profiles', 'channels', 'assets', 'schedules', 
        'plans', 'favorites', 'watch_history', 'subscriptions', 
        'recordings', 'categories', 'user_game_state'
    ]
    
    for table in tables:
        print(f"  Migrating table: {table}...")
        
        # 1. Fetch from SQLite (Safe search for orphans)
        query_sql = QUERIES.get(table, f"SELECT * FROM {table}")
        
        try:
            sl_cur.execute(query_sql)
            rows = sl_cur.fetchall()
        except:
            print(f"    - Table {table} does not exist locally, skipping.")
            continue

        if not rows:
            print(f"    - No data in {table}, skipping.")
            continue
            
        colnames = rows[0].keys()
        
        # 2. Insert into PostgreSQL
        placeholders = ",".join(["%s"] * len(colnames))
        insert_sql = f"INSERT INTO {table} ({','.join(colnames)}) VALUES ({placeholders})"
        
        data = [tuple(row) for row in rows]
        try:
            pg_cur.executemany(insert_sql, data)
            pg_conn.commit()  # Individual table commit for resilience
            print(f"    - Success: {len(rows)} rows processed.")
        except Exception as e:
            print(f"    - Error migrating {table}: {e}")
            pg_conn.rollback()
            continue
        
    pg_conn.commit()
    print("\nMigration Complete!")
    print("Your CultureQuest data is now live on Supabase.")
    
    sl_conn.close()
    pg_conn.close()

if __name__ == "__main__":
    migrate()
