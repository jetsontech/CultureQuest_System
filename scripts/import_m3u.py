"""
Import channels from M3U playlist files into the CultureQuest database.

Usage:
    python scripts/import_m3u.py            # full import
    python scripts/import_m3u.py --dry-run  # preview without writing
"""
import re
import sys
import os
import sqlite3

# ── Category mapping ──
CATEGORY_MAP = {
    # Direct matches
    'movies': 'Movies', 'movie': 'Movies', 'classic': 'Movies',
    'news': 'News', 'business': 'News',
    'comedy': 'Comedy',
    'series': 'Drama', 'drama': 'Drama',
    'sports': 'Sports', 'outdoor': 'Sports', 'auto': 'Sports',
    'kids': 'Kids', 'animation': 'Kids', 'family': 'Kids',
    'documentary': 'Documentaries', 'education': 'Documentaries', 'science': 'Documentaries',
    'music': 'Music',
    'cooking': 'Food', 'food': 'Food',
    'travel': 'Travel',
    'entertainment': 'Entertainment', 'general': 'Entertainment',
    'lifestyle': 'Entertainment', 'culture': 'Entertainment',
    'religious': 'Entertainment', 'shop': 'Entertainment',
    'weather': 'News',
    'legislative': 'News',
    'anime': 'Kids',
    'gaming': 'Entertainment',
}


def map_category(raw):
    """Map an M3U group-title to a platform category."""
    if not raw:
        return 'Entertainment'
    # Handle semicolon-separated categories (e.g. "documentary;business")
    parts = [p.strip().lower() for p in raw.split(';')]
    for part in parts:
        if part in CATEGORY_MAP:
            return CATEGORY_MAP[part]
    return 'Entertainment'


def slugify(value):
    """Simple slugifier."""
    slug = value.strip().lower()
    slug = re.sub(r'[^a-z0-9\s-]', '', slug)
    slug = re.sub(r'[\s_]+', '-', slug)
    slug = re.sub(r'-+', '-', slug).strip('-')
    return slug or 'channel'


def parse_m3u(filepath):
    """Parse an M3U file and return a list of channel dicts."""
    channels = []
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith('#EXTINF'):
            # Parse the EXTINF line
            logo_match = re.search(r'tvg-logo="([^"]*)"', line)
            group_match = re.search(r'group-title="([^"]*)"', line)
            # Channel name is after the last comma
            name_match = re.search(r',(.+)$', line)

            logo = logo_match.group(1) if logo_match else ''
            group = group_match.group(1) if group_match else ''
            name = name_match.group(1).strip() if name_match else ''

            # Next non-empty, non-comment line should be the URL
            i += 1
            url = ''
            while i < len(lines):
                candidate = lines[i].strip()
                if candidate and not candidate.startswith('#'):
                    url = candidate
                    break
                i += 1

            if name and url:
                channels.append({
                    'name': name,
                    'slug': slugify(name),
                    'stream_url': url,
                    'logo_url': logo,
                    'category': map_category(group),
                    'raw_category': group,
                })
        i += 1

    return channels


def import_channels(db_path, m3u_files, dry_run=False):
    """Import channels from M3U files into the database."""
    # Parse all M3U files
    all_channels = []
    for f in m3u_files:
        if os.path.exists(f):
            parsed = parse_m3u(f)
            print(f"  Parsed {len(parsed):,} channels from {os.path.basename(f)}")
            all_channels.extend(parsed)
        else:
            print(f"  SKIP: {f} not found")

    # Deduplicate by name (case-insensitive, keep first)
    seen_names = set()
    unique = []
    for ch in all_channels:
        key = ch['name'].lower().strip()
        if key not in seen_names:
            seen_names.add(key)
            unique.append(ch)
    print(f"\n  Total unique channels: {len(unique):,} (deduped from {len(all_channels):,})")

    if dry_run:
        # Show category breakdown
        from collections import Counter
        cats = Counter(ch['category'] for ch in unique)
        print("\n  Category breakdown:")
        for cat, count in cats.most_common(20):
            print(f"    {count:4d}  {cat}")
        return

    # Connect to database
    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row

    # Get existing channel slugs to avoid duplicates
    existing_slugs = set()
    for row in db.execute("SELECT slug FROM channels"):
        existing_slugs.add(row['slug'])

    # Get current max channel number
    max_num = db.execute("SELECT COALESCE(MAX(number), 0) FROM channels").fetchone()[0]

    inserted = 0
    skipped = 0
    for ch in unique:
        slug = ch['slug']

        # Ensure unique slug
        base_slug = slug
        counter = 1
        while slug in existing_slugs:
            slug = f"{base_slug}-{counter}"
            counter += 1

        max_num += 1
        try:
            db.execute("""
                INSERT INTO channels (number, name, slug, description, category,
                    stream_url, logo_url, is_premium, is_active, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, datetime('now'))
            """, (
                max_num,
                ch['name'],
                slug,
                f"Live stream · {ch['category']}",
                ch['category'],
                ch['stream_url'],
                ch['logo_url'],
            ))
            existing_slugs.add(slug)
            inserted += 1
        except Exception as e:
            print(f"    ERROR inserting {ch['name']}: {e}")
            skipped += 1

    db.commit()
    db.close()

    total = db_path and sqlite3.connect(db_path).execute("SELECT COUNT(*) FROM channels WHERE is_active=1").fetchone()[0]
    print(f"\n  DONE Inserted: {inserted:,}")
    print(f"  SKIP Skipped: {skipped:,}")
    print(f"  TV   Total active channels: {total:,}")


if __name__ == '__main__':
    dry_run = '--dry-run' in sys.argv

    # Paths
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    db_path = os.path.join(base_dir, 'instance', 'culturequest.db')

    m3u_files = [
        os.path.join(base_dir, 'us.m3u'),
        os.path.join(os.path.expanduser('~'), 'Downloads', 'publiciptvcom-us.m3u'),
    ]

    mode = "DRY RUN" if dry_run else "LIVE IMPORT"
    print(f"\n{'='*50}")
    print(f"  CultureQuest M3U Channel Import ({mode})")
    print(f"{'='*50}\n")

    import_channels(db_path, m3u_files, dry_run=dry_run)
    print()
