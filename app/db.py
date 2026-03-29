import sqlite3
import os
import re
from datetime import datetime, timedelta
import click
from flask import current_app, g
from werkzeug.security import generate_password_hash

# Schema compatible with both SQLite and PostgreSQL
SCHEMA = r'''
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS channels (
    id SERIAL PRIMARY KEY,
    number INTEGER UNIQUE NOT NULL,
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    description TEXT,
    category TEXT NOT NULL,
    logo_url TEXT,
    poster_url TEXT,
    stream_url TEXT,
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

CREATE TABLE IF NOT EXISTS cultures (
    id SERIAL PRIMARY KEY,
    artifact_id TEXT UNIQUE NOT NULL,
    artifact_name TEXT NOT NULL,
    era TEXT NOT NULL,
    rarity TEXT NOT NULL,
    image_url TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS watch_history (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER,
    asset_id INTEGER,
    watched_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    progress_seconds INTEGER DEFAULT 0,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS favorites (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, channel_id),
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY(channel_id) REFERENCES channels(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS recordings (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    channel_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    starts_at TIMESTAMP WITH TIME ZONE NOT NULL,
    ends_at TIMESTAMP WITH TIME ZONE NOT NULL,
    status TEXT NOT NULL DEFAULT 'scheduled',
    output_path TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY(channel_id) REFERENCES channels(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_profiles (
    user_id INTEGER PRIMARY KEY,
    avatar_url TEXT DEFAULT '',
    favorite_genres TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    plan_id INTEGER NOT NULL,
    provider TEXT DEFAULT 'manual',
    provider_ref TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'inactive',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    ends_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY(plan_id) REFERENCES plans(id) ON DELETE CASCADE
);
'''

def transform_query(query, is_postgres):
    """Converts between SQLite and PostgreSQL syntax."""
    if is_postgres:
        q = query.replace('?', '%s')
        q = q.replace('INSERT OR IGNORE', 'INSERT')
        q = q.replace('INTEGER PRIMARY KEY AUTOINCREMENT', 'SERIAL PRIMARY KEY')
        q = q.replace('AUTOINCREMENT', '')
        return q
    else:
        q = query.replace('SERIAL PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT')
        q = q.replace('TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP', 'TEXT NOT NULL')
        return q

class DBWrapper:
    def __init__(self, conn, is_postgres):
        self.conn = conn
        self.is_postgres = is_postgres

    def __getattr__(self, name):
        return getattr(self.conn, name)

    def execute(self, query, params=()):
        q = transform_query(query, self.is_postgres)
        cursor = self.cursor()
        cursor.execute(q, params)
        return cursor

    def commit(self):
        return self.conn.commit()

    def close(self):
        return self.conn.close()

def get_db():
    if 'db' not in g:
        db_url = os.getenv('DATABASE_URL')
        if db_url and db_url.startswith('postgres'):
            import psycopg2
            from psycopg2.extras import RealDictCursor
            conn = psycopg2.connect(db_url)
            g.db = DBWrapper(conn, True)
            g.db_type = 'postgres'
        else:
            db_path = os.path.join(current_app.instance_path, 'culturequest.db')
            os.makedirs(current_app.instance_path, exist_ok=True)
            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            g.db = DBWrapper(conn, False)
            g.db_type = 'sqlite'
    return g.db

def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()

def init_db():
    db = get_db()
    # Execute each statement in SCHEMA
    for statement in SCHEMA.split(';'):
        if statement.strip():
            db.execute(statement)
    db.commit()

@click.command('init-db')
def init_db_command():
    init_db()
    click.echo('Initialized the database.')

def init_app(app):
    app.teardown_appcontext(close_db)
    app.cli.add_command(init_db_command)

def query_db(query, args=(), one=False):
    cur = get_db().execute(query, args)
    rv = [dict(row) for row in cur.fetchall()]
    return (rv[0] if rv else None) if one else rv

def db_execute(query, args=()):
    db = get_db()
    cur = db.execute(query, args)
    db.commit()
    return cur
