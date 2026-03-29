from datetime import datetime
from flask import url_for
from .db import get_db


def _make_upload_url(file_path):
    if not file_path:
        return ''
    filename = file_path.split('/')[-1].split('\\')[-1]
    return url_for('public.serve_uploads', filename=filename)


def list_channels():
    db = get_db()
    return [dict(r) for r in db.execute('SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC').fetchall()]


def get_channel_by_slug(slug):
    db = get_db()
    row = db.execute('SELECT * FROM channels WHERE slug = ?', (slug,)).fetchone()
    return dict(row) if row else None


def get_channel_schedule(channel_id):
    db = get_db()
    rows = db.execute('''
        SELECT s.*, a.title AS asset_title, a.file_path, a.public_url
        FROM schedules s JOIN assets a ON a.id = s.asset_id
        WHERE s.channel_id = ?
        ORDER BY s.starts_at ASC
    ''', (channel_id,)).fetchall()
    out = []
    for r in rows:
        item = dict(r)
        item['play_url'] = item['public_url'] or (_make_upload_url(item['file_path']) if item['file_path'] else '')
        out.append(item)
    return out


def guide_items():
    db = get_db()
    
    # 1. Fetch channels with current programs explicitly
    channels_with_current = db.execute('''
        SELECT 
            ch.id, ch.number, ch.name, ch.slug, ch.category, ch.description, ch.is_premium, ch.stream_url,
            s.title_override, a.title AS asset_title, a.file_path, a.public_url
        FROM channels ch
        LEFT JOIN schedules s ON s.channel_id = ch.id AND s.starts_at <= CURRENT_TIMESTAMP AND s.ends_at >= CURRENT_TIMESTAMP
        LEFT JOIN assets a ON a.id = s.asset_id
        WHERE ch.is_active = 1
        ORDER BY ch.number ASC
    ''').fetchall()

    # 2. Fetch all upcoming programs grouped by channel
    upcoming_rows = db.execute('''
        SELECT s.channel_id, s.title_override, a.title AS asset_title
        FROM schedules s
        JOIN assets a ON a.id = s.asset_id
        WHERE s.starts_at > CURRENT_TIMESTAMP
        ORDER BY s.starts_at ASC
    ''').fetchall()

    upcoming_map = {}
    for r in upcoming_rows:
        cid = r['channel_id']
        if cid not in upcoming_map:
            upcoming_map[cid] = r

    items = []
    for ch in channels_with_current:
        play_url = ch['stream_url'] or ''
        now_playing = None
        if ch['asset_title']:
            play_url = ch['public_url'] or (_make_upload_url(ch['file_path']) if ch['file_path'] else play_url)
            now_playing = ch['title_override'] or ch['asset_title']
            
        upcoming = upcoming_map.get(ch['id'])
        
        items.append({
            'number': ch['number'],
            'name': ch['name'],
            'slug': ch['slug'],
            'category': ch['category'],
            'description': ch['description'],
            'is_premium': ch['is_premium'],
            'stream_url': play_url,
            'now_playing': now_playing,
            'up_next': (upcoming['title_override'] or upcoming['asset_title']) if upcoming else None,
        })
    return items


def plans():
    db = get_db()
    return [dict(r) for r in db.execute('SELECT * FROM plans WHERE is_active = 1 ORDER BY price_cents ASC').fetchall()]





def get_encoding_progress(slug):
    import os
    # Check how many .ts segments exist in the upload folder
    target_dir = os.path.join(os.getcwd(), 'app', 'static', 'uploads', slug)
    if not os.path.exists(target_dir):
        return 0
    segments = [f for f in os.listdir(target_dir) if f.endswith('.ts')]
    return len(segments)
