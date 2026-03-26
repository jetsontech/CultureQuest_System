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
'''

def transform_query(query, is_postgres):
    """Converts SQLite '?' placeholders to PostgreSQL '%s' if needed."""
    if is_postgres:
        return query.replace('?', '%s').replace('INSERT OR IGNORE', 'INSERT').replace('AUTOINCREMENT', '')
    return query.replace('SERIAL PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT').replace('TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP', 'TEXT NOT NULL')

class DBWrapper:
    def __init__(self, conn, is_postgres):
        self.conn = conn
        self.is_postgres = is_postgres

    def execute(self, query, params=()):
        q = transform_query(query, self.is_postgres)
        cursor = self.conn.cursor()
        try:
            cursor.execute(q, params)
        except Exception as e:
            if not self.is_postgres and 'UNIQUE constraint failed' in str(e):
                pass # Emulate INSERT OR IGNORE for SQLite if transform didn't catch it
            else:
                raise e
        return cursor

    def commit(self):
        self.conn.commit()

    def close(self):
        self.conn.close()

    def fetchone(self, cursor):
        row = cursor.fetchone()
        if not row: return None
        if self.is_postgres:
            colnames = [desc[0] for desc in cursor.description]
            return dict(zip(colnames, row))
        return row

    def fetchall(self, cursor):
        rows = cursor.fetchall()
        if self.is_postgres:
            colnames = [desc[0] for desc in cursor.description]
            return [dict(zip(colnames, row)) for row in rows]
        return rows

def get_db():
    if 'db' not in g:
        db_url = os.getenv('DATABASE_URL')
        if db_url and db_url.startswith('postgres'):
            import psycopg2
            from psycopg2.extras import RealDictCursor
            # Fix for common SQLAlchemy/Vercel postgresql:// vs postgres://
            if db_url.startswith("postgres://"):
                db_url = db_url.replace("postgres://", "postgresql://", 1)
            
            conn = psycopg2.connect(db_url)
            g.db_type = 'postgres'
            g.db = conn
        else:
            conn = sqlite3.connect(current_app.config['DATABASE'])
            conn.row_factory = sqlite3.Row
            conn.execute('PRAGMA foreign_keys = ON')
            g.db_type = 'sqlite'
            g.db = conn
            
    return g.db

def query_db(query, args=(), one=False):
    is_pg = g.get('db_type') == 'postgres'
    q = transform_query(query, is_pg)
    
    db = get_db()
    if is_pg:
        from psycopg2.extras import RealDictCursor
        cur = db.cursor(cursor_factory=RealDictCursor)
    else:
        cur = db.execute(q, args)
        
    if is_pg:
        cur.execute(q, args)
        
    rv = cur.fetchall()
    cur.close()
    return (rv[0] if rv else None) if one else rv

def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()

def db_execute(query, args=()):
    is_pg = g.get('db_type') == 'postgres'
    q = transform_query(query, is_pg)
    db = get_db()
    if is_pg:
        cur = db.cursor()
        cur.execute(q, args)
        return cur
    else:
        return db.execute(q, args)

def init_db():
    db = get_db()
    is_pg = g.get('db_type') == 'postgres'
    final_schema = transform_query(SCHEMA, is_pg)
    if is_pg:
        cur = db.cursor()
        cur.execute(final_schema)
        cur.close()
    else:
        db.executescript(final_schema)
    db.commit()

def seed_defaults():
    db = get_db()
    is_pg = g.get('db_type') == 'postgres'
    now = datetime.utcnow()
    
    # Use helper for specific queries
    def execute(q, p=()):
        q_trans = transform_query(q, is_pg)
        if is_pg:
            cur = db.cursor()
            cur.execute(q_trans, p)
            return cur
        else:
            return db.execute(q_trans, p)

    # Admin User
    admin = query_db('SELECT id FROM users WHERE email = ?', ('admin@culturequest.local',), one=True)
    if not admin:
        execute(
            'INSERT INTO users (email, password_hash, display_name, is_admin, created_at) VALUES (?, ?, ?, ?, ?)',
            ('admin@culturequest.local', generate_password_hash('ChangeMe123!'), 'CultureQuest Admin', 1, now)
        )

    # Channels
    channels = [
        (101, 'Beacon Movies', 'beacon-movies', '24/7 movies and featured films.', 'Movies', '', '', '', 0, 1, now),
        (102, 'Beacon Action', 'beacon-action', 'Action and thrillers around the clock.', 'Movies', '', '', '', 0, 1, now),
        (103, 'Beacon Drama', 'beacon-drama', 'Drama and premium storytelling.', 'Drama', '', '', '', 0, 1, now),
        (111, 'Creator One', 'creator-one', 'Featured creator channel.', 'Creators', '', '', '', 0, 1, now)
    ]
    for row in channels:
        try:
            execute('''
            INSERT INTO channels
            (number, name, slug, description, category, logo_url, poster_url, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', row)
        except: pass # Simple ignore for seed

    db.commit()

@click.command('init-db')
def init_db_command():
    init_db()
    seed_defaults()
    click.echo('Initialized the database.')
