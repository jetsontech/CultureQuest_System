$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Utf8File {
    param([string]$Path,[string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Content | Set-Content -Path $Path -Encoding utf8
    Write-Host ("Wrote " + $Path) -ForegroundColor Green
}

function Ensure-LineInFile {
    param([string]$Path,[string]$Line)
    if (!(Test-Path $Path)) { $Line | Set-Content -Path $Path -Encoding utf8; return }
    $content = Get-Content $Path -Raw
    if ($content -notmatch [regex]::Escape($Line)) {
        Add-Content -Path $Path -Value $Line
        Write-Host ("Added to " + $Path + ": " + $Line) -ForegroundColor Green
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CultureQuest Streaming Company Foundation" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Ensure-LineInFile ".\requirements.txt" "requests"
Ensure-LineInFile ".\requirements.txt" "Flask==3.0.3"

# -----------------------------------------------------------------
# db foundation upgrade
# -----------------------------------------------------------------
$dbUpgrade = @'
from .db import get_db

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

    existing = db.execute("PRAGMA table_info(channels)").fetchall()
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
            db.execute(f"ALTER TABLE channels ADD COLUMN {name} {sql_type}")

    seed_categories = [
        'Featured','Movies','Comedy','Drama','Crime','Reality','Documentaries',
        'News','Sports','Kids','Anime','Entertainment','Food','Travel','Music',
        'Latino','Local','Gaming / Games'
    ]
    for name in seed_categories:
        db.execute("INSERT OR IGNORE INTO categories(name) VALUES (?)", (name,))

    db.commit()
'@
Write-Utf8File ".\app\db_upgrade.py" $dbUpgrade

# -----------------------------------------------------------------
# full views (foundation)
# -----------------------------------------------------------------
$viewsPy = @'
import os
from datetime import datetime
from flask import Blueprint, current_app, render_template, request, redirect, url_for, flash, session, send_from_directory, jsonify
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename

from .auth import login_required
from .db import get_db
from .services import list_channels, get_channel_by_slug, get_channel_schedule, guide_items, plans

public_bp = Blueprint("public", __name__)
admin_bp = Blueprint("admin", __name__, url_prefix="/admin")
api_bp = Blueprint("api", __name__, url_prefix="/api")


def slugify(value: str) -> str:
    return value.strip().lower().replace(" ", "-").replace("_", "-")


def row_to_dict(row):
    return dict(row) if row is not None else None


def rows_to_dicts(rows):
    return [dict(r) for r in rows]


def normalize_local_stream_url(stream_url: str) -> str:
    if not stream_url:
        return stream_url
    stream_url = stream_url.strip()
    if "/streams/" in stream_url:
        idx = stream_url.find("/streams/")
        return request.host_url.rstrip("/") + stream_url[idx:]
    if "/uploads/" in stream_url:
        idx = stream_url.find("/uploads/")
        return request.host_url.rstrip("/") + stream_url[idx:]
    return stream_url


def requested_categories():
    return [
        "Featured","Movies","Comedy","Drama","Crime","Reality","Documentaries",
        "News","Sports","Kids","Anime","Entertainment","Food","Travel","Music",
        "Latino","Local","Gaming / Games"
    ]


def categorize_channel(channel):
    text = " ".join([
        str(channel.get("name", "")),
        str(channel.get("description", "")),
        str(channel.get("category", "")),
    ]).lower()

    rules = [
        ("Gaming / Games", ["game", "gaming", "esports", "arcade", "nintendo", "xbox", "playstation"]),
        ("Sports", ["sport", "mma", "boxing", "fight", "football", "soccer", "basketball", "baseball", "golf", "tennis"]),
        ("News", ["news", "headline", "breaking", "weather"]),
        ("Movies", ["movie", "movies", "cinema", "film", "films"]),
        ("Comedy", ["comedy", "funny", "laugh", "sitcom"]),
        ("Drama", ["drama"]),
        ("Crime", ["crime", "police", "investigation", "detective"]),
        ("Reality", ["reality"]),
        ("Documentaries", ["documentary", "documentaries", "docs", "nature", "history", "science"]),
        ("Kids", ["kids", "baby", "cartoon", "children", "family"]),
        ("Anime", ["anime"]),
        ("Entertainment", ["entertainment", "celebrity", "showbiz", "tv", "series", "shows"]),
        ("Food", ["food", "cooking", "kitchen", "recipe"]),
        ("Travel", ["travel", "trip", "tour"]),
        ("Music", ["music", "concert", "radio", "hits"]),
        ("Latino", ["latino", "espanol", "spanish", "latin", "mexico"]),
        ("Local", ["local", "community", "city", "regional"]),
    ]
    for label, needles in rules:
        if any(n in text for n in needles):
            return label
    raw = (channel.get("category") or "").strip().lower()
    mapping = {
        "movie": "Movies", "movies": "Movies", "news": "News", "sports": "Sports",
        "kids": "Kids", "anime": "Anime", "music": "Music", "comedy": "Comedy",
        "drama": "Drama", "crime": "Crime", "reality": "Reality",
        "documentary": "Documentaries", "documentaries": "Documentaries",
        "food": "Food", "travel": "Travel", "latino": "Latino", "local": "Local",
        "gaming": "Gaming / Games", "games": "Gaming / Games", "entertainment": "Entertainment",
    }
    return mapping.get(raw, "Featured")


def build_category_rows(channels):
    grouped = {name: [] for name in requested_categories()}
    for ch in channels:
        grouped.setdefault(categorize_channel(ch), []).append(ch)
    rows = []
    for name in requested_categories():
        if grouped.get(name):
            rows.append({"name": name, "channels": grouped[name][:18]})
    return rows


def current_user_id():
    return session.get("user_id")


@public_bp.route("/")
def home():
    db = get_db()
    rows = db.execute("SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC LIMIT 160").fetchall()
    channels = rows_to_dicts(rows)
    featured = channels[:4]
    category_rows = build_category_rows(channels)
    return render_template("home.html", channels=channels, featured=featured, category_rows=category_rows, plans=plans())


@public_bp.route("/beacon")
def beacon():
    db = get_db()
    rows = db.execute("SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC LIMIT 200").fetchall()
    channels = rows_to_dicts(rows)
    category_rows = build_category_rows(channels)
    return render_template("beacon.html", channels=channels, category_rows=category_rows)


@public_bp.route("/categories/<category_name>")
def category_page(category_name):
    db = get_db()
    rows = db.execute("SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC").fetchall()
    channels = rows_to_dicts(rows)
    filtered = [c for c in channels if categorize_channel(c).lower() == category_name.lower()]
    return render_template("category_page.html", category_name=category_name, channels=filtered)


@public_bp.route("/epg")
def epg():
    db = get_db()
    rows = db.execute("""
        SELECT s.starts_at, s.ends_at, c.name AS channel_name,
               COALESCE(s.title_override, a.title) AS program_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        ORDER BY s.starts_at ASC
        LIMIT 500
    """).fetchall()
    return render_template("epg.html", epg=rows)


@public_bp.route("/channel/<slug>")
def channel_detail(slug):
    channel_row = get_channel_by_slug(slug)
    if not channel_row:
        flash("Channel not found.", "danger")
        return redirect(url_for("public.beacon"))

    channel = row_to_dict(channel_row)
    schedule = get_channel_schedule(channel["id"])
    guide = next((x for x in guide_items() if x["slug"] == slug), None)

    play_url = ""
    if channel.get("stream_url") and str(channel.get("stream_url")).strip():
        stream_url = normalize_local_stream_url(channel["stream_url"].strip())
        if (
            stream_url.startswith(request.host_url.rstrip("/"))
            or stream_url.startswith("http://127.0.0.1:5000/")
            or stream_url.startswith("http://localhost:5000/")
            or "/streams/" in stream_url
            or "/uploads/" in stream_url
            or "/hls/" in stream_url
        ):
            play_url = stream_url
        else:
            play_url = url_for("hls.proxy_manifest", slug=channel["slug"])
    elif channel.get("fallback_stream_url") and str(channel.get("fallback_stream_url")).strip():
        fallback = normalize_local_stream_url(channel["fallback_stream_url"].strip())
        if (
            fallback.startswith(request.host_url.rstrip("/"))
            or fallback.startswith("http://127.0.0.1:5000/")
            or fallback.startswith("http://localhost:5000/")
            or "/streams/" in fallback
            or "/uploads/" in fallback
            or "/hls/" in fallback
        ):
            play_url = fallback
        else:
            play_url = url_for("hls.proxy_manifest", slug=channel["slug"])
    elif guide and guide.get("stream_url") and str(guide.get("stream_url")).strip():
        play_url = guide["stream_url"]

    db = get_db()
    channel_list_rows = db.execute("SELECT slug, number, name FROM channels WHERE is_active = 1 ORDER BY number ASC").fetchall()
    channel_list = rows_to_dicts(channel_list_rows)

    previous_slug = None
    next_slug = None
    for i, row in enumerate(channel_list):
        if row["slug"] == channel["slug"]:
            if i > 0:
                previous_slug = channel_list[i - 1]["slug"]
            if i < len(channel_list) - 1:
                next_slug = channel_list[i + 1]["slug"]
            break

    if current_user_id():
        db.execute(
            "INSERT INTO watch_history (user_id, channel_id, asset_id, watched_at, progress_seconds) VALUES (?, ?, NULL, ?, 0)",
            (current_user_id(), channel["id"], datetime.utcnow().isoformat())
        )
        db.commit()

    return render_template("channel_detail.html", channel=channel, schedule=schedule, play_url=play_url, guide=guide, previous_slug=previous_slug, next_slug=next_slug)


@public_bp.route("/watch/<slug>")
def watch(slug):
    return channel_detail(slug)


@public_bp.route("/premium")
def premium():
    return render_template("premium.html", plans=plans())


@public_bp.route("/creators")
def creators():
    return render_template("creators.html")


@public_bp.route("/favorite/<int:channel_id>", methods=["POST"])
@login_required
def toggle_favorite(channel_id):
    db = get_db()
    user_id = current_user_id()
    existing = db.execute("SELECT id FROM favorites WHERE user_id = ? AND channel_id = ?", (user_id, channel_id)).fetchone()
    if existing:
        db.execute("DELETE FROM favorites WHERE user_id = ? AND channel_id = ?", (user_id, channel_id))
        flash("Removed from favorites.", "info")
    else:
        db.execute("INSERT INTO favorites (user_id, channel_id, created_at) VALUES (?, ?, ?)", (user_id, channel_id, datetime.utcnow().isoformat()))
        flash("Added to favorites.", "success")
    db.commit()
    return redirect(request.referrer or url_for("public.beacon"))


@public_bp.route("/favorites")
@login_required
def favorites_page():
    db = get_db()
    rows = db.execute("""
        SELECT c.*
        FROM favorites f JOIN channels c ON c.id = f.channel_id
        WHERE f.user_id = ?
        ORDER BY c.number ASC
    """, (current_user_id(),)).fetchall()
    return render_template("favorites.html", channels=rows_to_dicts(rows))


@public_bp.route("/history")
@login_required
def history_page():
    db = get_db()
    rows = db.execute("""
        SELECT h.watched_at, c.name, c.slug, c.number
        FROM watch_history h LEFT JOIN channels c ON c.id = h.channel_id
        WHERE h.user_id = ?
        ORDER BY h.watched_at DESC
        LIMIT 100
    """, (current_user_id(),)).fetchall()
    return render_template("history.html", history=rows)


@public_bp.route("/uploads/<path:filename>")
def uploaded_file(filename):
    return send_from_directory(current_app.config["UPLOAD_FOLDER"], filename)


@public_bp.route("/streams/<path:filename>")
def streams(filename):
    return send_from_directory(os.path.join(os.getcwd(), "streams"), filename)


@admin_bp.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        db = get_db()
        user = db.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if not user or not check_password_hash(user["password_hash"], password):
            flash("Invalid credentials.", "danger")
        else:
            session.clear()
            session["user_id"] = user["id"]
            session["display_name"] = user["display_name"]
            session["is_admin"] = bool(user["is_admin"])
            flash("Welcome back.", "success")
            return redirect(url_for("admin.dashboard"))
    return render_template("admin_login.html")


@admin_bp.route("/logout")
def logout():
    session.clear()
    flash("Signed out.", "info")
    return redirect(url_for("public.home"))


@admin_bp.route("/")
@login_required
def dashboard():
    db = get_db()
    stats = {
        "channels": db.execute("SELECT COUNT(*) AS c FROM channels").fetchone()["c"],
        "assets": db.execute("SELECT COUNT(*) AS c FROM assets").fetchone()["c"],
        "schedules": db.execute("SELECT COUNT(*) AS c FROM schedules").fetchone()["c"],
        "favorites": db.execute("SELECT COUNT(*) AS c FROM favorites").fetchone()["c"],
        "recordings": db.execute("SELECT COUNT(*) AS c FROM recordings").fetchone()["c"],
        "subscriptions": db.execute("SELECT COUNT(*) AS c FROM subscriptions").fetchone()["c"],
    }
    return render_template("admin_dashboard.html", stats=stats, guide=[])


@admin_bp.route("/channels", methods=["GET", "POST"])
@login_required
def channels():
    db = get_db()
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        slug = slugify(request.form.get("slug") or name)
        number = int(request.form.get("number") or 0)
        category = request.form.get("category", "").strip()
        description = request.form.get("description", "").strip()
        stream_url = request.form.get("stream_url", "").strip()
        fallback_stream_url = request.form.get("fallback_stream_url", "").strip()
        logo_url = request.form.get("logo_url", "").strip()
        is_premium = 1 if request.form.get("is_premium") else 0
        now = datetime.utcnow().isoformat()
        upload_file = request.files.get("upload_file")

        db.execute("""
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, fallback_stream_url, logo_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        """, (number, name, slug, description, category, stream_url, fallback_stream_url, logo_url, is_premium, now))
        db.commit()
        channel_row = db.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()

        if upload_file and upload_file.filename:
            filename = secure_filename(upload_file.filename)
            dest = os.path.join(current_app.config["UPLOAD_FOLDER"], filename)
            upload_file.save(dest)
            uploaded_public_url = url_for("public.uploaded_file", filename=filename)
            db.execute("""
                INSERT INTO assets
                (title, slug, description, file_path, public_url, duration_seconds, media_type, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (name, slug, description or f"{name} uploaded during channel creation", dest, uploaded_public_url, 0, "video", now))
            if not stream_url:
                db.execute("UPDATE channels SET stream_url = ? WHERE id = ?", (uploaded_public_url, channel_row["id"]))
            db.commit()

        flash("Channel created.", "success")
        return redirect(url_for("admin.channels"))

    rows = db.execute("SELECT * FROM channels ORDER BY number ASC").fetchall()
    return render_template("admin_channels.html", channels=rows)


@admin_bp.route("/channels/<int:channel_id>/edit", methods=["POST"])
@login_required
def edit_channel(channel_id):
    db = get_db()
    number = int(request.form.get("number") or 0)
    name = request.form.get("name", "").strip()
    slug = slugify(request.form.get("slug") or name)
    category = request.form.get("category", "").strip()
    description = request.form.get("description", "").strip()
    stream_url = request.form.get("stream_url", "").strip()
    fallback_stream_url = request.form.get("fallback_stream_url", "").strip()
    logo_url = request.form.get("logo_url", "").strip()
    is_premium = 1 if request.form.get("is_premium") else 0
    is_active = 1 if request.form.get("is_active") else 0

    db.execute("""
        UPDATE channels
        SET number=?, name=?, slug=?, description=?, category=?, stream_url=?, fallback_stream_url=?, logo_url=?, is_premium=?, is_active=?
        WHERE id=?
    """, (number, name, slug, description, category, stream_url, fallback_stream_url, logo_url, is_premium, is_active, channel_id))
    db.commit()
    flash("Channel updated.", "success")
    return redirect(url_for("admin.channels"))


@admin_bp.route("/channels/<int:channel_id>/delete", methods=["POST"])
@login_required
def delete_channel(channel_id):
    db = get_db()
    db.execute("DELETE FROM channels WHERE id=?", (channel_id,))
    db.commit()
    flash("Channel deleted.", "info")
    return redirect(url_for("admin.channels"))


@admin_bp.route("/assets", methods=["GET", "POST"])
@login_required
def assets():
    db = get_db()
    if request.method == "POST":
        title = request.form.get("title", "").strip()
        slug = slugify(request.form.get("slug") or title)
        description = request.form.get("description", "").strip()
        media_type = request.form.get("media_type", "video")
        public_url = request.form.get("public_url", "").strip()
        duration_seconds = int(request.form.get("duration_seconds") or 0)
        file = request.files.get("file")
        file_path = ""
        if file and file.filename:
            filename = secure_filename(file.filename)
            dest = os.path.join(current_app.config["UPLOAD_FOLDER"], filename)
            file.save(dest)
            file_path = dest
        db.execute("""
            INSERT INTO assets
            (title, slug, description, file_path, public_url, duration_seconds, media_type, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (title, slug, description, file_path, public_url, duration_seconds, media_type, datetime.utcnow().isoformat()))
        db.commit()
        flash("Asset added.", "success")
        return redirect(url_for("admin.assets"))
    rows = db.execute("SELECT * FROM assets ORDER BY id DESC").fetchall()
    return render_template("admin_assets.html", assets=rows)


@admin_bp.route("/schedules", methods=["GET", "POST"])
@login_required
def schedules():
    db = get_db()
    if request.method == "POST":
        channel_id = int(request.form.get("channel_id") or 0)
        asset_id = int(request.form.get("asset_id") or 0)
        starts_at = request.form.get("starts_at", "")
        ends_at = request.form.get("ends_at", "")
        title_override = request.form.get("title_override", "").strip() or None
        db.execute("INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override) VALUES (?, ?, ?, ?, ?)", (channel_id, asset_id, starts_at, ends_at, title_override))
        db.commit()
        flash("Schedule block added.", "success")
        return redirect(url_for("admin.schedules"))

    rows = db.execute("""
        SELECT s.*, c.name AS channel_name, a.title AS asset_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        ORDER BY s.starts_at ASC
    """).fetchall()
    channels = db.execute("SELECT id, name, number FROM channels ORDER BY number ASC").fetchall()
    assets = db.execute("SELECT id, title FROM assets ORDER BY id DESC").fetchall()
    return render_template("admin_schedules.html", schedules=rows, channels=channels, assets=assets)


@admin_bp.route("/plans", methods=["GET", "POST"])
@login_required
def manage_plans():
    db = get_db()
    if request.method == "POST":
        db.execute("""
            INSERT INTO plans (name, slug, price_cents, billing_interval, description, is_active)
            VALUES (?, ?, ?, ?, ?, 1)
        """, (
            request.form.get("name", "").strip(),
            slugify(request.form.get("slug") or request.form.get("name", "")),
            int(request.form.get("price_cents") or 0),
            request.form.get("billing_interval", "monthly"),
            request.form.get("description", "").strip(),
        ))
        db.commit()
        flash("Plan created.", "success")
        return redirect(url_for("admin.manage_plans"))
    rows = db.execute("SELECT * FROM plans ORDER BY price_cents ASC").fetchall()
    return render_template("admin_plans.html", plans=rows)


@admin_bp.route("/recordings", methods=["GET", "POST"])
@login_required
def recordings():
    db = get_db()
    if request.method == "POST":
        title = request.form.get("title", "").strip()
        channel_id = int(request.form.get("channel_id") or 0)
        starts_at = request.form.get("starts_at", "")
        ends_at = request.form.get("ends_at", "")
        db.execute(
            "INSERT INTO recordings (user_id, channel_id, title, starts_at, ends_at, status, output_path, created_at) VALUES (?, ?, ?, ?, ?, 'scheduled', '', ?)",
            (current_user_id(), channel_id, title, starts_at, ends_at, datetime.utcnow().isoformat())
        )
        db.commit()
        flash("Recording scheduled.", "success")
        return redirect(url_for("admin.recordings"))
    rows = db.execute("SELECT r.*, c.name AS channel_name FROM recordings r LEFT JOIN channels c ON c.id = r.channel_id ORDER BY r.created_at DESC").fetchall()
    channels = db.execute("SELECT id, name, number FROM channels ORDER BY number ASC").fetchall()
    return render_template("recordings.html", recordings=rows, channels=channels)


@public_bp.route("/signup", methods=["GET", "POST"])
def signup():
    if request.method == "POST":
        db = get_db()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        display_name = request.form.get("display_name", "").strip() or "Viewer"
        existing = db.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if existing:
            flash("Account already exists.", "danger")
        else:
            now = datetime.utcnow().isoformat()
            db.execute("INSERT INTO users (email, password_hash, display_name, is_admin, created_at) VALUES (?, ?, ?, 0, ?)", (email, generate_password_hash(password), display_name, now))
            db.commit()
            flash("Account created. Please sign in.", "success")
            return redirect(url_for("admin.login"))
    return render_template("signup.html")


@api_bp.route("/channels")
def api_channels():
    return jsonify(list_channels())


@api_bp.route("/guide")
def api_guide():
    return jsonify(guide_items())


@api_bp.route("/plans")
def api_plans():
    return jsonify(plans())
'@
Write-Utf8File ".\app\views.py" $viewsPy

# -----------------------------------------------------------------
# __init__.py foundation init
# -----------------------------------------------------------------
$initPy = @'
import os
from flask import Flask
from .db import close_db, init_db_command
from .views import public_bp, admin_bp, api_bp
from .hls_proxy import hls_bp
from .db_upgrade import ensure_platform_foundation


def create_app():
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("CQ_SECRET_KEY", "dev-secret-change-this"),
        DATABASE=os.path.join(app.instance_path, "culturequest.db"),
        UPLOAD_FOLDER=os.path.join(app.instance_path, "uploads"),
        MAX_CONTENT_LENGTH=1024 * 1024 * 1024,
    )

    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    app.teardown_appcontext(close_db)
    app.cli.add_command(init_db_command)

    with app.app_context():
        ensure_platform_foundation()

    app.register_blueprint(public_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(hls_bp)
    return app
'@
Write-Utf8File ".\app\__init__.py" $initPy

# -----------------------------------------------------------------
# Templates: home, beacon, category, favorites, history, signup, recordings
# -----------------------------------------------------------------
$homeHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest{% endblock %}
{% block content %}
<section class="hero-shell glass-blur">
  <div class="hero-panel">
    <div class="hero-copy">
      <div class="eyebrow">CultureQuest Premier</div>
      <h1>The Peak of Streaming</h1>
      <p>Futuristic live channels, originals, premium culture, and category rails in one immersive platform.</p>
      <div class="actions top-gap-sm">
        <a class="btn btn-primary" href="{{ url_for('public.beacon') }}">Watch Live Now</a>
        <a class="btn" href="{{ url_for('public.premium') }}">Explore Plans</a>
      </div>
    </div>
    <div class="hero-side-grid">
      {% for channel in featured %}
      <a class="feature-tile" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }} · {{ channel['category'] or 'Featured' }}</span>
      </a>
      {% endfor %}
    </div>
  </div>
</section>
{% for row in category_rows %}
<section class="top-gap rail-section">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a href="{{ url_for('public.category_page', category_name=row['name']) }}" class="pill">View All</a>
  </div>
  <div class="scrolling-rail">
    {% for channel in row['channels'] %}
      <a href="{{ url_for('public.channel_detail', slug=channel['slug']) }}" class="rail-card glass-card">
        <div class="rail-poster alt-{{ loop.index % 4 }}"><div class="live-badge pulse">LIVE</div></div>
        <div class="rail-meta"><h3>{{ channel['name'] }}</h3><p>{{ channel['description'] or 'Now Streaming' }}</p></div>
      </a>
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\home.html" $homeHtml

$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}
{% block content %}
<div class="section-head"><div><h1>Live TV</h1><p class="muted">Browse modern rails by category.</p></div><span class="pill">{{ channels|length }} Channels</span></div>
{% for row in category_rows %}
<section class="top-gap rail-section">
  <div class="section-head"><h2>{{ row['name'] }}</h2><a href="{{ url_for('public.category_page', category_name=row['name']) }}" class="pill">View All</a></div>
  <div class="scrolling-rail">
    {% for channel in row['channels'] %}
    <a href="{{ url_for('public.channel_detail', slug=channel['slug']) }}" class="rail-card glass-card">
      <div class="rail-poster alt-{{ loop.index % 4 }}"><div class="live-badge pulse">LIVE</div></div>
      <div class="rail-meta"><h3>{{ channel['name'] }}</h3><p>{{ channel['description'] or channel['category'] or 'Now Streaming' }}</p></div>
    </a>
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\beacon.html" $beaconHtml

$categoryHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · {{ category_name }}{% endblock %}
{% block content %}
<div class="section-head"><div><h1>{{ category_name }}</h1><p class="muted">Channels in this category.</p></div><a class="btn" href="{{ url_for('public.beacon') }}">Back to Live TV</a></div>
<div class="browse-grid">
{% for channel in channels %}
  <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
    <strong>{{ channel['name'] }}</strong>
    <span>CH {{ channel['number'] }}</span>
  </a>
{% endfor %}
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\category_page.html" $categoryHtml

$favoritesHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Favorites{% endblock %}
{% block content %}
<div class="section-head"><div><h1>Favorites</h1><p class="muted">Your saved channels.</p></div></div>
<div class="browse-grid">
{% for channel in channels %}
  <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}"><strong>{{ channel['name'] }}</strong><span>CH {{ channel['number'] }}</span></a>
{% endfor %}
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\favorites.html" $favoritesHtml

$historyHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Watch History{% endblock %}
{% block content %}
<div class="section-head"><div><h1>Watch History</h1><p class="muted">Recently watched channels.</p></div></div>
<div class="guide-shell top-gap">
  <div class="guide-row guide-head"><div>Time</div><div>Channel</div><div>Number</div><div>Open</div></div>
  {% for item in history %}
  <div class="guide-row"><div>{{ item['watched_at'] }}</div><div>{{ item['name'] or 'Unknown' }}</div><div>{{ item['number'] or '' }}</div><div>{% if item['slug'] %}<a class="btn btn-small btn-primary" href="{{ url_for('public.channel_detail', slug=item['slug']) }}">Open</a>{% endif %}</div></div>
  {% endfor %}
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\history.html" $historyHtml

$signupHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Sign Up{% endblock %}
{% block content %}
<div class="narrow card auth-card">
  <h1>Create Account</h1>
  <form method="post" class="form-grid top-gap-sm">
    <label>Display Name<input name="display_name" required></label>
    <label>Email<input name="email" type="email" required></label>
    <label>Password<input name="password" type="password" required></label>
    <div class="actions"><button class="btn btn-primary" type="submit">Create Account</button></div>
  </form>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\signup.html" $signupHtml

$recordingsHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Recordings{% endblock %}
{% block content %}
<div class="section-head"><div><h1>Recordings</h1><p class="muted">Schedule and manage recordings.</p></div></div>
<div class="grid-2">
  <div class="card">
    <h2>Schedule Recording</h2>
    <form method="post" class="form-grid top-gap-sm">
      <label>Title<input name="title" required></label>
      <label>Channel<select name="channel_id">{% for c in channels %}<option value="{{ c['id'] }}">CH {{ c['number'] }} · {{ c['name'] }}</option>{% endfor %}</select></label>
      <label>Starts At<input name="starts_at" placeholder="2026-03-23T20:00:00"></label>
      <label>Ends At<input name="ends_at" placeholder="2026-03-23T21:00:00"></label>
      <div class="actions"><button class="btn btn-primary" type="submit">Schedule</button></div>
    </form>
  </div>
  <div class="card">
    <h2>Scheduled Jobs</h2>
    <div class="table">
      {% for r in recordings %}
      <div class="table-row"><div>{{ r['title'] }}</div><div>{{ r['channel_name'] or '' }}</div><div>{{ r['starts_at'] }}</div><div>{{ r['status'] }}</div><div>{{ r['output_path'] }}</div></div>
      {% endfor %}
    </div>
  </div>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\recordings.html" $recordingsHtml

# -----------------------------------------------------------------
# base nav light update for new pages
# -----------------------------------------------------------------
$baseHtml = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#05070a">
  <title>{% block title %}CultureQuest{% endblock %}</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
  <header class="topbar">
    <div class="wrap topbar-inner">
      <a class="brand-wrap" href="{{ url_for('public.home') }}">
        <div class="brand-mark">CQ</div>
        <div>
          <div class="brand">CultureQuest</div>
          <div class="brand-sub">Live TV Platform</div>
        </div>
      </a>
      <nav class="nav">
        <a href="{{ url_for('public.home') }}">Home</a>
        <a href="{{ url_for('public.beacon') }}">Live TV</a>
        <a href="{{ url_for('public.epg') }}">Guide</a>
        <a href="{{ url_for('public.favorites_page') }}">Favorites</a>
        <a href="{{ url_for('public.history_page') }}">History</a>
        <a href="{{ url_for('admin.channels') }}">Channels</a>
      </nav>
    </div>
  </header>
  <main class="main-area">
    <div class="wrap">
      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          <div class="flash-stack">
            {% for category, message in messages %}
              <div class="flash {{ category }}">{{ message }}</div>
            {% endfor %}
          </div>
        {% endif %}
      {% endwith %}
      {% block content %}{% endblock %}
    </div>
  </main>
</body>
</html>
'@
Write-Utf8File ".\app\templates\base.html" $baseHtml

# -----------------------------------------------------------------
# admin dashboard update
# -----------------------------------------------------------------
$adminDash = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Admin{% endblock %}
{% block content %}
<div class="section-head">
  <div>
    <h1>Admin Dashboard</h1>
    <p class="muted">Operations, scheduling, assets, plans, recordings, and subscriptions.</p>
  </div>
</div>
<div class="stats-grid">
  <div class="card stat-card"><div class="stat">{{ stats.channels }}</div><p>Channels</p></div>
  <div class="card stat-card"><div class="stat">{{ stats.assets }}</div><p>Assets</p></div>
  <div class="card stat-card"><div class="stat">{{ stats.schedules }}</div><p>Schedules</p></div>
  <div class="card stat-card"><div class="stat">{{ stats.recordings }}</div><p>Recordings</p></div>
  <div class="card stat-card"><div class="stat">{{ stats.favorites }}</div><p>Favorites</p></div>
  <div class="card stat-card"><div class="stat">{{ stats.subscriptions }}</div><p>Subscriptions</p></div>
</div>
<div class="browse-grid top-gap">
  <a class="browse-card" href="{{ url_for('admin.channels') }}"><strong>Channels</strong><span>Create, edit, publish</span></a>
  <a class="browse-card" href="{{ url_for('admin.schedules') }}"><strong>Schedules</strong><span>Program 24/7 lineups</span></a>
  <a class="browse-card" href="{{ url_for('admin.assets') }}"><strong>Assets</strong><span>Upload and manage content</span></a>
  <a class="browse-card" href="{{ url_for('admin.manage_plans') }}"><strong>Plans</strong><span>Free and premium plans</span></a>
  <a class="browse-card" href="{{ url_for('admin.recordings') }}"><strong>Recordings</strong><span>DVR scheduling</span></a>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\admin_dashboard.html" $adminDash

# -----------------------------------------------------------------
# admin channels template with logo and uploads
# -----------------------------------------------------------------
$adminChannels = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Admin Channels{% endblock %}
{% block content %}
<div class="section-head"><div><h1>Channels</h1><p class="muted">Create, edit, uploads, logos, fallbacks, and category assignment.</p></div></div>
<div class="grid-2">
  <div class="card">
    <h2>Create Channel</h2>
    <form method="post" enctype="multipart/form-data" class="form-grid top-gap-sm">
      <label>Name<input name="name" required></label>
      <label>Slug<input name="slug"></label>
      <label>Number<input name="number" type="number" required></label>
      <label>Category<select name="category" required>{% for c in ['Featured','Movies','Comedy','Drama','Crime','Reality','Documentaries','News','Sports','Kids','Anime','Entertainment','Food','Travel','Music','Latino','Local','Gaming / Games'] %}<option value="{{ c }}">{{ c }}</option>{% endfor %}</select></label>
      <label>Description<textarea name="description"></textarea></label>
      <label>Primary Stream URL<input name="stream_url"></label>
      <label>Fallback Stream URL<input name="fallback_stream_url"></label>
      <label>Logo URL<input name="logo_url"></label>
      <label>Upload Local Video<input name="upload_file" type="file" accept="video/*"></label>
      <label class="checkbox"><input type="checkbox" name="is_premium"> Premium</label>
      <div class="actions"><button class="btn btn-primary" type="submit">Create Channel</button></div>
    </form>
  </div>
  <div class="card">
    <h2>Edit Existing Channels</h2>
    {% for channel in channels %}
    <div class="details-card top-gap-sm">
      <form method="post" action="{{ url_for('admin.edit_channel', channel_id=channel['id']) }}" class="form-grid">
        <label>Number<input name="number" type="number" value="{{ channel['number'] or 0 }}"></label>
        <label>Name<input name="name" value="{{ channel['name'] or '' }}"></label>
        <label>Slug<input name="slug" value="{{ channel['slug'] or '' }}"></label>
        <label>Category<select name="category">{% set current = channel['category'] or 'Featured' %}{% for c in ['Featured','Movies','Comedy','Drama','Crime','Reality','Documentaries','News','Sports','Kids','Anime','Entertainment','Food','Travel','Music','Latino','Local','Gaming / Games'] %}<option value="{{ c }}" {% if current == c %}selected{% endif %}>{{ c }}</option>{% endfor %}</select></label>
        <label>Description<textarea name="description">{{ channel['description'] or '' }}</textarea></label>
        <label>Primary Stream URL<input name="stream_url" value="{{ channel['stream_url'] or '' }}"></label>
        <label>Fallback Stream URL<input name="fallback_stream_url" value="{{ channel['fallback_stream_url'] or '' }}"></label>
        <label>Logo URL<input name="logo_url" value="{{ channel['logo_url'] or '' }}"></label>
        <label class="checkbox"><input type="checkbox" name="is_premium" {% if channel['is_premium'] %}checked{% endif %}> Premium</label>
        <label class="checkbox"><input type="checkbox" name="is_active" {% if channel['is_active'] %}checked{% endif %}> Active</label>
        <div class="actions"><button class="btn btn-primary btn-small" type="submit">Save</button></div>
      </form>
    </div>
    {% endfor %}
  </div>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\admin_channels.html" $adminChannels

# -----------------------------------------------------------------
# architecture doc
# -----------------------------------------------------------------
$archMd = @'
# CultureQuest Platform Architecture

## Platform Layers
- Web app: Flask + Jinja templates
- Playback: HLS.js in browser, local HLS proxy in Flask
- Metadata: SQLite for channels, assets, schedules, users, subscriptions, favorites, history, recordings
- Ingestion: M3U import scripts + mirror assets + schedule generation
- Admin ops: channels, assets, schedules, plans, recordings

## Company-grade roadmap
### Core experience
- Live TV rails
- Favorites
- Watch history
- Category pages
- Mobile-safe UI
- Remote/TV style controls

### Viewer platform
- Sign up / auth
- Free + premium plans
- Continue watching
- Favorites + watch history APIs

### Content ops
- Assets
- Scheduling
- EPG generation/import
- Logo mirroring
- Channel health checks
- Recordings scheduler

### Infra progression
- SQLite now
- PostgreSQL later
- Redis queue later
- FFmpeg workers later
- CDN later
- Payment provider later
- Object storage later

## One-click foundation delivered
This foundation installs the schema, templates, and routes required to evolve CultureQuest from a prototype into a structured streaming company system.
'@
Write-Utf8File ".\docs\CULTUREQUEST_ARCHITECTURE.md" $archMd

Write-Host ""
Write-Host "Installing requirements..." -ForegroundColor Yellow
pip install -r .\requirements.txt

Write-Host ""
Write-Host "Foundation installed." -ForegroundColor Green
Write-Host "Start with:" -ForegroundColor Yellow
Write-Host "  py .\run.py"
