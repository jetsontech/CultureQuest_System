import sqlite3

def run():
    print("Connecting to instance/culturequest.db...")
    conn = sqlite3.connect('instance/culturequest.db')
    cursor = conn.cursor()
    
    # Update channels stream_urls
    cursor.execute("""
        UPDATE channels 
        SET stream_url = REPLACE(stream_url, 'http://127.0.0.1:5000', 'https://culturequest.vip')
        WHERE stream_url LIKE '%127.0.0.1:5000%';
    """)
    
    cursor.execute("""
        UPDATE channels 
        SET stream_url = REPLACE(stream_url, 'http://localhost:5000', 'https://culturequest.vip')
        WHERE stream_url LIKE '%localhost:5000%';
    """)
    
    cursor.execute("""
        UPDATE channels 
        SET fallback_stream_url = REPLACE(fallback_stream_url, 'http://127.0.0.1:5000', 'https://culturequest.vip')
        WHERE fallback_stream_url LIKE '%127.0.0.1:5000%';
    """)
    
    cursor.execute("""
        UPDATE channels 
        SET fallback_stream_url = REPLACE(fallback_stream_url, 'http://localhost:5000', 'https://culturequest.vip')
        WHERE fallback_stream_url LIKE '%localhost:5000%';
    """)
    
    print(f"Updated {conn.total_changes} rows in the database.")
    
    conn.commit()
    conn.close()

if __name__ == '__main__':
    run()
