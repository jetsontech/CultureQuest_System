import os, sqlite3, requests

# --- CONFIGURATION ---
TMDB_API_KEY = "c7485ede1976facaf70c83743ac3c7a2"
DB_PATH = 'instance/culturequest.db'

def get_smart_meta(query):
    try:
        url = f"https://api.themoviedb.org/3/search/multi?api_key={TMDB_API_KEY}&query={query}"
        data = requests.get(url, timeout=5).json()
        if data.get('results'):
            best_match = data['results'][0]
            return {
                'title': best_match.get('title') or best_match.get('name'),
                'overview': best_match.get('overview'),
                'poster': f"https://image.tmdb.org/t/p/w500{best_match.get('poster_path')}"
            }
    except: return None

def enrich_guide():
    if not os.path.exists(DB_PATH): return
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    
    channels = cur.execute("SELECT id, name FROM channels").fetchall()
    for cid, name in channels:
        meta = get_smart_meta(name)
        if meta:
            cur.execute("""
                UPDATE channels 
                SET now_playing = ?, description = ?, poster_url = ? 
                WHERE id = ?
            """, (meta['title'], meta['overview'], meta['poster'], cid))
            print(f"Enriched: {name} -> {meta['title']}")
    conn.commit()
    conn.close()

if __name__ == "__main__": enrich_guide()
