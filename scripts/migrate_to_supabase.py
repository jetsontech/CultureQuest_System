import sqlite3
import os
import sys
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

# Load credentials
load_dotenv()

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
    
    tables = ['users', 'channels', 'assets', 'schedules', 'plans', 'user_game_state']
    
    for table in tables:
        print(f"  Migrating table: {table}...")
        
        # 1. Fetch from SQLite
        sl_cur.execute(f"SELECT * FROM {table}")
        rows = sl_cur.fetchall()
        if not rows:
            print(f"    - No data in {table}, skipping.")
            continue
            
        colnames = rows[0].keys()
        
        # 2. Insert into PostgreSQL
        # We use ON CONFLICT DO NOTHING to avoid duplicates if re-run
        placeholders = ",".join(["%s"] * len(colnames))
        query = f"INSERT INTO {table} ({','.join(colnames)}) VALUES ({placeholders}) ON CONFLICT DO NOTHING"
        
        data = [tuple(row) for row in rows]
        pg_cur.executemany(query, data)
        print(f"    - Success: {len(rows)} rows processed.")
        
    pg_conn.commit()
    print("\nMigration Complete!")
    print("Your CultureQuest data is now live on Supabase.")
    
    sl_conn.close()
    pg_conn.close()

if __name__ == "__main__":
    migrate()
