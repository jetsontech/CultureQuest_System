import os
import uuid
import subprocess
import boto3
from botocore.config import Config
from datetime import datetime
from flask import Blueprint, current_app, render_template, request, redirect, url_for, flash, session, send_from_directory, jsonify
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename

from .auth import login_required, admin_required
from .db import get_db
from .services import list_channels, get_channel_by_slug, get_channel_schedule, guide_items, plans

public_bp = Blueprint("public", __name__)
admin_bp = Blueprint("admin", __name__, url_prefix="/admin")
api_bp = Blueprint("api", __name__, url_prefix="/api")

@public_bp.route("/health")
def health_check():
    return "CultureQuest is ALIVE!"



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
            rows.append({"name": name, "channels": grouped[name][:30]})
    return rows


def current_user_id():
    return session.get("user_id")

@public_bp.route("/game")
@login_required
def game_index():
    return current_app.send_static_file("game/index.html")

@public_bp.route("/api/game/state", methods=["GET", "POST"])
def game_state():
    user_id = session.get("user_id")
    if not user_id:
        return jsonify({"error": "Unauthorized"}), 401

    db = get_db()
    
    if request.method == "GET":
        state = db.execute("SELECT * FROM user_game_state WHERE user_id = ?", (user_id,)).fetchone()
        if not state:
            return jsonify({"gold": 0, "xp": 0, "level": 1, "unlocked_artifacts": [], "dig_count": 0})
        
        import json
        return jsonify({
            "gold": state["gold"],
            "xp": state["xp"],
            "level": state["level"],
            "unlocked_artifacts": json.loads(state["unlocked_artifacts"]),
            "dig_count": state["dig_count"]
        })
        
    else: # POST
        import json
        from datetime import datetime
        data = request.json
        gold = data.get("gold", 0)
        xp = data.get("xp", 0)
        level = data.get("level", 1)
        unlocked_artifacts = json.dumps(data.get("unlocked_artifacts", []))
        dig_count = data.get("dig_count", 0)
        now = datetime.utcnow().isoformat()
        
        state = db.execute("SELECT id FROM user_game_state WHERE user_id = ?", (user_id,)).fetchone()
        if state:
            db.execute("""
                UPDATE user_game_state 
                SET gold=?, xp=?, level=?, unlocked_artifacts=?, dig_count=?, updated_at=?
                WHERE user_id=?
            """, (gold, xp, level, unlocked_artifacts, dig_count, now, user_id))
        else:
            db.execute("""
                INSERT INTO user_game_state (user_id, gold, xp, level, unlocked_artifacts, dig_count, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (user_id, gold, xp, level, unlocked_artifacts, dig_count, now))
            
        db.commit()
        return jsonify({"status": "ok"})


@public_bp.route("/")
def home():
    db = get_db()
    rows = db.execute("SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC LIMIT 500").fetchall()
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
    guide = guide_items()
    return render_template("beacon.html", channels=channels, category_rows=category_rows, guide=guide)


@public_bp.route("/categories/<category_name>")
def category_page(category_name):
    db = get_db()
    rows = db.execute("SELECT * FROM channels WHERE is_active = 1 ORDER BY number ASC").fetchall()
    channels = rows_to_dicts(rows)
    filtered = [c for c in channels if categorize_channel(c).lower() == category_name.lower()]
    return render_template("category_page.html", category_name=category_name, channels=filtered)




@public_bp.route("/search")
def search_channels():
    q = request.args.get("q", "").strip()
    db = get_db()

    if not q:
        rows = []
    else:
        like = f"%{q}%"
        rows = db.execute(
            """
            SELECT *
            FROM channels
            WHERE is_active = 1
              AND (
                    name LIKE ?
                 OR slug LIKE ?
                 OR category LIKE ?
                 OR description LIKE ?
              )
            ORDER BY number ASC
            LIMIT 100
            """,
            (like, like, like, like),
        ).fetchall()

    return render_template("search.html", query=q, channels=rows_to_dicts(rows))




@public_bp.route("/channel/<slug>")
def channel_detail(slug):
    channel_row = get_channel_by_slug(slug)
    if not channel_row:
        flash("Channel not found.", "danger")
        return redirect(url_for("public.beacon"))

    channel = row_to_dict(channel_row)
    schedule = get_channel_schedule(channel["id"])
        # Correctly route live stream play requests
    guide = next((x for x in guide_items() if x['slug'] == slug), None)
    if guide and not guide.get('stream_url'):
        # Fallback to local HLS directory if stream_url is empty
        guide['stream_url'] = f"/static/uploads/{slug}/index.m3u8"

    play_url = ""
    if channel.get("stream_url") and str(channel.get("stream_url")).strip():
        stream_url = normalize_local_stream_url(channel["stream_url"].strip())
        if (
            stream_url.startswith(request.host_url.rstrip("/"))
            or stream_url.startswith("https://culturequest.vip/")
            or stream_url.startswith("http://culturequest.vip/")
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
            or fallback.startswith("https://culturequest.vip/")
            or fallback.startswith("http://culturequest.vip/")
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
@admin_required
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
@admin_required
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
            upload_file.stream.seek(0); file.stream.seek(0); file.save(dest)
            uploaded_public_url = url_for("public.serve_uploads", filename=filename)
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
@admin_required
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
@admin_required
def delete_channel(channel_id):
    db = get_db()
    db.execute("DELETE FROM channels WHERE id=?", (channel_id,))
    db.commit()
    flash("Channel deleted.", "info")
    return redirect(url_for("admin.channels"))


@admin_bp.route("/assets", methods=["GET", "POST"])
@admin_required
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
            file.stream.seek(0); file.stream.seek(0); file.save(dest)
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
@admin_required
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
@admin_required
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
@admin_required
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


@api_bp.route("/upload-multipart", methods=["POST"])
@login_required
def upload_multipart():
    data = request.json
    action = data.get("action")
    bucket = os.getenv("S3_BUCKET_NAME")
    
    s3 = get_s3_client()
    if not s3 or not bucket:
        return jsonify({"error": "S3 not configured"}), 500
        
    if action == "create":
        filename = data.get("filename")
        content_type = data.get("contentType", "video/mp4")
        key = f"uploads/{uuid.uuid4()}-{filename}"
        
        response = s3.create_multipart_upload(
            Bucket=bucket,
            Key=key,
            ContentType=content_type
        )
        return jsonify({
            "uploadId": response["UploadId"],
            "key": key
        })
        
    elif action == "sign-part":
        key = data.get("key")
        upload_id = data.get("uploadId")
        part_number = data.get("partNumber")
        
        params = {
            'Bucket': bucket,
            'Key': key,
            'UploadId': upload_id,
            'PartNumber': part_number
        }
        url = s3.generate_presigned_url(
            'upload_part',
            Params=params,
            ExpiresIn=3600
        )
        return jsonify({"signedUrl": url})
        
    elif action == "complete":
        key = data.get("key")
        upload_id = data.get("uploadId")
        parts = data.get("parts") # List of {'ETag': ..., 'PartNumber': ...}
        
        # Ensure parts are sorted
        parts.sort(key=lambda x: x['PartNumber'])
        
        s3.complete_multipart_upload(
            Bucket=bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={'Parts': parts}
        )
        
        public_domain = os.getenv("S3_PUBLIC_DOMAIN")
        if public_domain:
            public_url = f"{public_domain.rstrip('/')}/{key}"
        else:
            public_url = f"{os.getenv('S3_ENDPOINT').rstrip('/')}/{bucket}/{key}"
            
        return jsonify({"publicUrl": public_url})
        
    return jsonify({"error": "Invalid action"}), 400


def get_s3_client():
    endpoint = os.getenv("S3_ENDPOINT")
    access_key = os.getenv("S3_ACCESS_KEY_ID")
    secret_key = os.getenv("S3_SECRET_ACCESS_KEY")
    region = os.getenv("S3_REGION", "auto")
    
    if not all([endpoint, access_key, secret_key]):
        return None
        
    return boto3.client(
        's3',
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name=region,
        config=Config(signature_version='s3v4')
    )
























@public_bp.route('/creator-upload', methods=['POST'])
def creator_upload():
    import os, uuid, subprocess
    from werkzeug.utils import secure_filename
    from .db import get_db

    title = request.form.get('title')
    category = request.form.get('category', 'Creators')
    file = request.files.get('file')
    public_url = request.form.get('public_url')

    if not title or (not file and not public_url):
        return jsonify({"error": "Missing title or media source"}), 400

    slug = slugify(title) + "-" + str(uuid.uuid4())[:4]
    upload_dir = os.path.join(os.getcwd(), 'app', 'static', 'uploads', slug)
    os.makedirs(upload_dir, exist_ok=True)
    
    source_input = ""

    # Case 1: Traditional direct file upload
    if file:
        filename = secure_filename(file.filename)
        temp_input = os.path.join(upload_dir, filename)
        file.stream.seek(0)
        file.save(temp_input)
        source_input = temp_input
    # Case 2: Multipart S3 upload already completed
    else:
        source_input = public_url

    # 2. Register the channel in DB immediately
    stream_url = f"/static/uploads/{slug}/index.m3u8"
    db = get_db()
    db.execute("""
        INSERT INTO channels (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
        VALUES ((SELECT COALESCE(MAX(number),0)+1 FROM channels), ?, ?, ?, ?, ?, 0, 1, datetime('now'))
    """, (title, slug, 'User uploaded content', category, stream_url))
    db.commit()

    # 3. Convert to HLS using FFmpeg in the background
    output_m3u8 = os.path.join(upload_dir, 'index.m3u8')
    ffmpeg_cmd = [
        'ffmpeg', '-y', '-i', source_input,
        '-vf', "scale='min(1920,iw)':-2",
        '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'main', '-level', '4.1',
        '-c:a', 'aac', '-ac', '2', '-b:a', '128k',
        '-f', 'hls', '-hls_time', '6', '-hls_list_size', '0',
        '-hls_segment_filename', os.path.join(upload_dir, 'seg_%03d.ts'),
        output_m3u8
    ]

    subprocess.Popen(ffmpeg_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    return jsonify({"status": "ok", "slug": slug, "message": f"{title} is encoding in the background."}), 200











@admin_bp.route('/assets/<int:asset_id>/delete', methods=['POST'])
@admin_required
def delete_asset(asset_id):
    from .db import get_db
    import os
    db = get_db()
    row = db.execute('SELECT * FROM assets WHERE id=?', (asset_id,)).fetchone()
    if row and row['file_path'] and os.path.exists(row['file_path']):
        try:
            os.remove(row['file_path'])
        except: pass
    db.execute('DELETE FROM assets WHERE id=?', (asset_id,))
    db.commit()
    flash('Asset and associated file removed.', 'info')
    return redirect(url_for('admin.assets'))




@public_bp.route('/uploads/<path:filename>')
def serve_uploads(filename):
    import os
    from flask import send_from_directory
    return send_from_directory(os.path.join(os.getcwd(), 'app', 'static', 'uploads'), filename)


# Register slugify for templates
@public_bp.app_context_processor
def inject_slugify():
    return dict(slugify=slugify)




@public_bp.route('/uploads/<slug>/<filename>')
def serve_hls_segments(slug, filename):
    import os
    from flask import send_from_directory
    # This ensures files like index.m3u8 and segment_000.ts are reachable
    target_dir = os.path.join(os.getcwd(), 'app', 'static', 'uploads', slug)
    return send_from_directory(target_dir, filename)


















@public_bp.route('/api/encoding-status/<slug>')
def encoding_status(slug):
    from .services import get_encoding_progress
    count = get_encoding_progress(slug)
    return jsonify({'segments': count, 'status': 'encoding' if count > 0 else 'starting'})

















@public_bp.route('/epg')
def epg():
    db = get_db()
    rows = db.execute('''
        SELECT
            s.starts_at,
            s.ends_at,
            c.name AS channel_name,
            COALESCE(s.title_override, a.title) AS program_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        WHERE s.ends_at >= datetime('now')
        ORDER BY c.number ASC, s.starts_at ASC
        LIMIT 500
    ''').fetchall()
    return render_template('epg.html', epg=rows)














@public_bp.route('/streams/<path:filename>')
def streams(filename):
    import os
    from flask import send_from_directory
    return send_from_directory(os.path.join(os.getcwd(), 'streams'), filename)
