$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Content | Set-Content -Path $Path -Encoding utf8
    Write-Host ("Wrote " + $Path) -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " CultureQuest One-Click TV Stage Upgrade" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------
# app/views.py
# ----------------------------
$viewsPy = @'
import os
from datetime import datetime
from flask import (
    Blueprint,
    current_app,
    render_template,
    request,
    redirect,
    url_for,
    flash,
    session,
    send_from_directory,
    jsonify,
)
from werkzeug.security import check_password_hash
from werkzeug.utils import secure_filename

from .auth import login_required
from .db import get_db
from .services import (
    list_channels,
    get_channel_by_slug,
    get_channel_schedule,
    guide_items,
    plans,
)

public_bp = Blueprint("public", __name__)
admin_bp = Blueprint("admin", __name__, url_prefix="/admin")
api_bp = Blueprint("api", __name__, url_prefix="/api")


def slugify(value: str) -> str:
    return value.strip().lower().replace(" ", "-").replace("_", "-")


def row_to_dict(row):
    if row is None:
        return None
    return dict(row)


def rows_to_dicts(rows):
    return [dict(r) for r in rows]


def normalize_local_stream_url(stream_url: str) -> str:
    if not stream_url:
        return stream_url
    stream_url = stream_url.strip()
    if "/streams/" in stream_url:
        idx = stream_url.find("/streams/")
        path = stream_url[idx:]
        return request.host_url.rstrip("/") + path
    if "/uploads/" in stream_url:
        idx = stream_url.find("/uploads/")
        path = stream_url[idx:]
        return request.host_url.rstrip("/") + path
    return stream_url


def get_pluto_style_categories():
    return [
        "Featured",
        "News",
        "Movies",
        "TV",
        "Comedy",
        "Drama",
        "Crime",
        "Reality",
        "Documentary",
        "Sports",
        "Games",
        "Kids",
        "Family",
        "Anime",
        "Music",
        "Entertainment",
        "Lifestyle",
        "Food",
        "Travel",
        "Science",
        "History",
        "Community",
        "Creators",
        "Faith",
        "International",
        "Local",
    ]


def categorize_channel(channel):
    text = " ".join(
        [
            str(channel.get("name", "")),
            str(channel.get("description", "")),
            str(channel.get("category", "")),
        ]
    ).lower()

    rules = [
        ("Games", ["game", "gaming", "esports", "arcade"]),
        ("Sports", ["sport", "mma", "boxing", "fight", "soccer", "football", "baseball", "basketball", "golf"]),
        ("News", ["news", "headline", "breaking"]),
        ("Movies", ["movie", "cinema", "films"]),
        ("TV", ["tv", "series", "shows"]),
        ("Comedy", ["comedy", "funny", "laugh"]),
        ("Drama", ["drama"]),
        ("Crime", ["crime", "police", "investigation"]),
        ("Reality", ["reality"]),
        ("Documentary", ["documentary", "docs", "history", "nature"]),
        ("Kids", ["kids", "baby", "cartoon", "children"]),
        ("Anime", ["anime"]),
        ("Music", ["music", "concert"]),
        ("Food", ["food", "cooking", "kitchen"]),
        ("Travel", ["travel"]),
        ("Science", ["science", "space", "tech"]),
        ("Lifestyle", ["lifestyle", "home", "garden", "fashion"]),
        ("Entertainment", ["entertainment", "celebrity", "showbiz"]),
        ("Faith", ["faith", "religious", "church", "worship"]),
        ("International", ["international", "world", "global"]),
        ("Community", ["community"]),
        ("Creators", ["creator", "creators"]),
        ("Local", ["local"]),
    ]

    for label, needles in rules:
        if any(n in text for n in needles):
            return label

    return channel.get("category") or "Featured"


def build_category_rows(channels):
    category_order = get_pluto_style_categories()
    rows = {name: [] for name in category_order}

    for ch in channels:
        label = categorize_channel(ch)
        if label not in rows:
            rows[label] = []
        rows[label].append(ch)

    ordered = []
    for name in category_order:
        if rows.get(name):
            ordered.append({"name": name, "channels": rows[name][:12]})

    leftovers = [k for k, v in rows.items() if k not in category_order and v]
    for name in leftovers:
        ordered.append({"name": name, "channels": rows[name][:12]})

    return ordered


@public_bp.route("/")
def home():
    db = get_db()
    rows = db.execute(
        """
        SELECT *
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        LIMIT 60
        """
    ).fetchall()
    channels = rows_to_dicts(rows)
    category_rows = build_category_rows(channels)

    featured = channels[:8]

    return render_template(
        "home.html",
        channels=channels,
        featured=featured,
        category_rows=category_rows,
        plans=plans(),
    )


@public_bp.route("/beacon")
def beacon():
    db = get_db()
    rows = db.execute(
        """
        SELECT *
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        LIMIT 120
        """
    ).fetchall()
    channels = rows_to_dicts(rows)
    category_rows = build_category_rows(channels)

    return render_template(
        "beacon.html",
        channels=channels,
        category_rows=category_rows,
    )


@public_bp.route("/categories/<category_name>")
def category_page(category_name):
    db = get_db()
    rows = db.execute(
        """
        SELECT *
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        """
    ).fetchall()
    channels = rows_to_dicts(rows)

    filtered = [c for c in channels if categorize_channel(c).lower() == category_name.lower()]
    return render_template(
        "category_page.html",
        category_name=category_name,
        channels=filtered,
    )


@public_bp.route("/epg")
def epg():
    db = get_db()
    rows = db.execute(
        """
        SELECT
            s.starts_at,
            s.ends_at,
            c.name AS channel_name,
            COALESCE(s.title_override, a.title) AS program_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        ORDER BY s.starts_at ASC
        LIMIT 500
        """
    ).fetchall()
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
    channel_list_rows = db.execute(
        """
        SELECT slug, number, name
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        """
    ).fetchall()
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

    return render_template(
        "channel_detail.html",
        channel=channel,
        schedule=schedule,
        play_url=play_url,
        guide=guide,
        previous_slug=previous_slug,
        next_slug=next_slug,
    )


@public_bp.route("/watch/<slug>")
def watch(slug):
    return channel_detail(slug)


@public_bp.route("/premium")
def premium():
    return render_template("premium.html", plans=plans())


@public_bp.route("/creators")
def creators():
    return render_template("creators.html")


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
        is_premium = 1 if request.form.get("is_premium") else 0
        now = datetime.utcnow().isoformat()

        upload_file = request.files.get("upload_file")

        db.execute(
            """
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, fallback_stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            """,
            (
                number,
                name,
                slug,
                description,
                category,
                stream_url,
                fallback_stream_url,
                is_premium,
                now,
            ),
        )
        db.commit()

        channel_row = db.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()

        if upload_file and upload_file.filename:
            filename = secure_filename(upload_file.filename)
            dest = os.path.join(current_app.config["UPLOAD_FOLDER"], filename)
            upload_file.save(dest)

            uploaded_public_url = url_for("public.uploaded_file", filename=filename)

            db.execute(
                """
                INSERT INTO assets
                (title, slug, description, file_path, public_url, duration_seconds, media_type, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    name,
                    slug,
                    description or f"{name} uploaded during channel creation",
                    dest,
                    uploaded_public_url,
                    0,
                    "video",
                    now,
                ),
            )

            if not stream_url:
                db.execute(
                    "UPDATE channels SET stream_url = ? WHERE id = ?",
                    (uploaded_public_url, channel_row["id"]),
                )

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
    is_premium = 1 if request.form.get("is_premium") else 0
    is_active = 1 if request.form.get("is_active") else 0

    db.execute(
        """
        UPDATE channels
        SET number=?, name=?, slug=?, description=?, category=?, stream_url=?, fallback_stream_url=?, is_premium=?, is_active=?
        WHERE id=?
        """,
        (
            number,
            name,
            slug,
            description,
            category,
            stream_url,
            fallback_stream_url,
            is_premium,
            is_active,
            channel_id,
        ),
    )
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

# ----------------------------
# app/templates/admin_channels.html
# ----------------------------
$adminChannelsHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Admin Channels{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Channels</h1>
    <p class="muted">Create and edit channels, uploads, fallbacks, and categories.</p>
  </div>
</div>

<div class="grid-2">
  <div class="card">
    <h2>Create Channel</h2>
    <form method="post" enctype="multipart/form-data" class="form-grid top-gap-sm">
      <label>Name
        <input name="name" required>
      </label>

      <label>Slug
        <input name="slug">
      </label>

      <label>Number
        <input name="number" type="number" required>
      </label>

      <label>Category
        <select name="category" required>
          <option value="Featured">Featured</option>
          <option value="News">News</option>
          <option value="Movies">Movies</option>
          <option value="TV">TV</option>
          <option value="Comedy">Comedy</option>
          <option value="Drama">Drama</option>
          <option value="Crime">Crime</option>
          <option value="Reality">Reality</option>
          <option value="Documentary">Documentary</option>
          <option value="Sports">Sports</option>
          <option value="Games">Games</option>
          <option value="Kids">Kids</option>
          <option value="Family">Family</option>
          <option value="Anime">Anime</option>
          <option value="Music">Music</option>
          <option value="Entertainment">Entertainment</option>
          <option value="Lifestyle">Lifestyle</option>
          <option value="Food">Food</option>
          <option value="Travel">Travel</option>
          <option value="Science">Science</option>
          <option value="History">History</option>
          <option value="Community">Community</option>
          <option value="Creators">Creators</option>
          <option value="Faith">Faith</option>
          <option value="International">International</option>
          <option value="Local">Local</option>
        </select>
      </label>

      <label>Description
        <textarea name="description"></textarea>
      </label>

      <label>Primary Stream URL
        <input name="stream_url">
      </label>

      <label>Fallback Stream URL
        <input name="fallback_stream_url">
      </label>

      <label>Upload Local Video
        <input name="upload_file" type="file" accept="video/*">
      </label>

      <label class="checkbox">
        <input type="checkbox" name="is_premium"> Premium
      </label>

      <div class="actions">
        <button class="btn btn-primary" type="submit">Create Channel</button>
      </div>
    </form>
  </div>

  <div class="card">
    <h2>Edit Existing Channels</h2>

    {% for channel in channels %}
    <div class="details-card top-gap-sm">
      <form method="post" action="{{ url_for('admin.edit_channel', channel_id=channel['id']) }}" class="form-grid">
        <label>Number
          <input name="number" type="number" value="{{ channel['number'] or 0 }}">
        </label>

        <label>Name
          <input name="name" value="{{ channel['name'] or '' }}">
        </label>

        <label>Slug
          <input name="slug" value="{{ channel['slug'] or '' }}">
        </label>

        <label>Category
          <select name="category">
            {% set current = channel['category'] or 'Featured' %}
            {% for c in ['Featured','News','Movies','TV','Comedy','Drama','Crime','Reality','Documentary','Sports','Games','Kids','Family','Anime','Music','Entertainment','Lifestyle','Food','Travel','Science','History','Community','Creators','Faith','International','Local'] %}
              <option value="{{ c }}" {% if current == c %}selected{% endif %}>{{ c }}</option>
            {% endfor %}
          </select>
        </label>

        <label>Description
          <textarea name="description">{{ channel['description'] or '' }}</textarea>
        </label>

        <label>Primary Stream URL
          <input name="stream_url" value="{{ channel['stream_url'] or '' }}">
        </label>

        <label>Fallback Stream URL
          <input name="fallback_stream_url" value="{{ channel['fallback_stream_url'] or '' }}">
        </label>

        <label class="checkbox">
          <input type="checkbox" name="is_premium" {% if channel['is_premium'] %}checked{% endif %}> Premium
        </label>

        <label class="checkbox">
          <input type="checkbox" name="is_active" {% if channel['is_active'] %}checked{% endif %}> Active
        </label>

        <div class="actions">
          <button class="btn btn-primary btn-small" type="submit">Save</button>
        </div>
      </form>
    </div>
    {% endfor %}
  </div>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\admin_channels.html" $adminChannelsHtml

# ----------------------------
# app/templates/home.html
# ----------------------------
$homeHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>CultureQuest</h1>
    <p class="muted">TV-style streaming with Pluto-like categories, including Games.</p>
  </div>
</div>

{% if featured %}
<div class="card">
  <h2>Featured Channels</h2>
  <div class="browse-grid top-gap-sm">
    {% for channel in featured %}
      <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }} · {{ channel['category'] or 'Featured' }}</span>
      </a>
    {% endfor %}
  </div>
</div>
{% endif %}

{% for row in category_rows %}
<div class="top-gap">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a class="pill" href="{{ url_for('public.category_page', category_name=row['name']) }}">View All</a>
  </div>
  <div class="browse-grid">
    {% for channel in row['channels'] %}
      <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }}</span>
      </a>
    {% endfor %}
  </div>
</div>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\home.html" $homeHtml

# ----------------------------
# app/templates/beacon.html
# ----------------------------
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Cable-style browsing with category rows.</p>
  </div>
  <span class="pill">{{ channels|length }} Channels</span>
</div>

{% for row in category_rows %}
<div class="top-gap">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a class="pill" href="{{ url_for('public.category_page', category_name=row['name']) }}">View All</a>
  </div>
  <div class="browse-grid">
    {% for channel in row['channels'] %}
      <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }}</span>
      </a>
    {% endfor %}
  </div>
</div>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\beacon.html" $beaconHtml

# ----------------------------
# app/templates/category_page.html
# ----------------------------
$categoryPageHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · {{ category_name }}{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>{{ category_name }}</h1>
    <p class="muted">Channels in this category.</p>
  </div>
  <a class="btn" href="{{ url_for('public.beacon') }}">Back to Live TV</a>
</div>

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
Write-Utf8File ".\app\templates\category_page.html" $categoryPageHtml

Write-Host ""
Write-Host "Stage TV upgrade complete." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Yellow
Write-Host "py .\run.py"