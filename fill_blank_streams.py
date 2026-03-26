import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
db.row_factory = sqlite3.Row
cur = db.cursor()

mapping = {
    "beacon-movies": "https://amchls.wns.live/hls/stream.m3u8",
    "beacon-news": "https://rtatv.akamaized.net/Content/HLS/Live/channel(RTA2)/index.m3u8",
    "beacon-sports": "https://rtatv.akamaized.net/Content/HLS/Live/channel(RTA3)/index.m3u8",
    "beacon-docs": "https://hls.afintl.com/hls/stream.m3u8",
    "beacon-music": "https://albportal.net/albkanalemusic.m3u8",
    "beacon-kids": "https://magicstream.ddns.net/magicstream/stream.m3u8",
    "beacon-faith": "https://live.relentlessinnovations.net:1936/imantv/imantv/index.m3u8",
    "beacon-action": "https://live1.mediadesk.al/cnatvlive.m3u8",
    "beacon-drama": "https://gjirafa-video-live.gjirafa.net/gjvideo-live/2dw-zuf-1c9-pxu/index.m3u8",
    "beacon-comedy": "https://stream.syritv.al/live/syritv/playlist.m3u8",
}

updated = 0

for slug, stream_url in mapping.items():
    cur.execute("""
        UPDATE channels
        SET stream_url = ?
        WHERE slug = ? AND (stream_url IS NULL OR TRIM(stream_url) = '')
    """, (stream_url, slug))
    updated += cur.rowcount

db.commit()
db.close()

print(f"Updated blank stream URLs: {updated}")
