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
    Write-Host "Wrote $Path" -ForegroundColor Green
}

function Run-PythonFile {
    param([string]$Path)
    if (Get-Command python -ErrorAction SilentlyContinue) {
        & python $Path
        return $LASTEXITCODE
    }
    & py $Path
    return $LASTEXITCODE
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Master Fix + Run" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------
# app\views.py
# ---------------------------------
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


@public_bp.route("/")
def home():
    db = get_db()
    rows = db.execute(
        """
        SELECT *
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        LIMIT 12
        """
    ).fetchall()
    channels = rows_to_dicts(rows)

    return render_template(
        "home.html",
        guide=channels,
        channels=channels,
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
        """
    ).fetchall()

    channels = rows_to_dicts(rows)

    return render_template(
        "beacon.html",
        guide=channels,
        channels=channels,
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

    # Priority 1: DB stream URL
    if channel.get("stream_url") and str(channel.get("stream_url")).strip():
        play_url = channel["stream_url"]

    # Priority 2: guide fallback
    elif guide and guide.get("stream_url") and str(guide.get("stream_url")).strip():
        play_url = guide["stream_url"]

    # Priority 3: scheduled asset
    else:
        db = get_db()
        current_asset = db.execute(
            """
            SELECT a.*
            FROM schedules s
            JOIN assets a ON a.id = s.asset_id
            WHERE s.channel_id = ?
              AND s.starts_at <= datetime('now')
              AND s.ends_at >= datetime('now')
            ORDER BY s.starts_at ASC
            LIMIT 1
            """,
            (channel["id"],),
        ).fetchone()

        if current_asset:
            current_asset = dict(current_asset)
            if current_asset.get("public_url"):
                play_url = current_asset["public_url"]
            elif current_asset.get("file_path"):
                play_url = url_for(
                    "public.uploaded_file",
                    filename=os.path.basename(current_asset["file_path"]),
                )

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
        user = db.execute(
            "SELECT * FROM users WHERE email = ?",
            (email,),
        ).fetchone()

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
        "premium_channels": db.execute(
            "SELECT COUNT(*) AS c FROM channels WHERE is_premium = 1"
        ).fetchone()["c"],
    }
    return render_template(
        "admin_dashboard.html",
        stats=stats,
        guide=guide_items()[:8],
    )


@admin_bp.route("/channels", methods=["GET", "POST"])
@login_required
def channels():
    db = get_db()

    if request.method == "POST":
        name = request.form["name"].strip()
        slug = slugify(request.form.get("slug") or name)
        number = int(request.form["number"])
        category = request.form["category"].strip()
        description = request.form.get("description", "").strip()
        stream_url = request.form.get("stream_url", "").strip()
        is_premium = 1 if request.form.get("is_premium") else 0
        now = datetime.utcnow().isoformat()

        try:
            db.execute(
                """
                INSERT INTO channels
                (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                """,
                (
                    number,
                    name,
                    slug,
                    description,
                    category,
                    stream_url,
                    is_premium,
                    now,
                ),
            )
            db.commit()
            flash("Channel created.", "success")
        except Exception as exc:
            flash(f"Unable to create channel: {exc}", "danger")

        return redirect(url_for("admin.channels"))

    rows = db.execute("SELECT * FROM channels ORDER BY number ASC").fetchall()
    return render_template("admin_channels.html", channels=rows)


@admin_bp.route("/channels/<int:channel_id>/edit", methods=["POST"])
@login_required
def edit_channel(channel_id):
    db = get_db()
    name = request.form["name"].strip()
    slug = slugify(request.form.get("slug") or name)
    number = int(request.form["number"])
    category = request.form["category"].strip()
    description = request.form.get("description", "").strip()
    stream_url = request.form.get("stream_url", "").strip()
    is_premium = 1 if request.form.get("is_premium") else 0
    is_active = 1 if request.form.get("is_active") else 0

    db.execute(
        """
        UPDATE channels
        SET number=?, name=?, slug=?, description=?, category=?, stream_url=?, is_premium=?, is_active=?
        WHERE id=?
        """,
        (
            number,
            name,
            slug,
            description,
            category,
            stream_url,
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


@admin_bp.route("/assets", methods=["GET", "POST"])
@login_required
def assets():
    db = get_db()

    if request.method == "POST":
        title = request.form["title"].strip()
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

        db.execute(
            """
            INSERT INTO assets
            (title, slug, description, file_path, public_url, duration_seconds, media_type, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                title,
                slug,
                description,
                file_path,
                public_url,
                duration_seconds,
                media_type,
                datetime.utcnow().isoformat(),
            ),
        )
        db.commit()
        flash("Asset added to media library.", "success")
        return redirect(url_for("admin.assets"))

    rows = db.execute("SELECT * FROM assets ORDER BY id DESC").fetchall()
    return render_template("admin_assets.html", assets=rows)


@admin_bp.route("/assets/<int:asset_id>/delete", methods=["POST"])
@login_required
def delete_asset(asset_id):
    db = get_db()
    row = db.execute("SELECT * FROM assets WHERE id=?", (asset_id,)).fetchone()

    if row and row["file_path"] and os.path.exists(row["file_path"]):
        os.remove(row["file_path"])

    db.execute("DELETE FROM assets WHERE id=?", (asset_id,))
    db.commit()
    flash("Asset removed.", "info")
    return redirect(url_for("admin.assets"))


@admin_bp.route("/schedules", methods=["GET", "POST"])
@login_required
def schedules():
    db = get_db()

    if request.method == "POST":
        channel_id = int(request.form["channel_id"])
        asset_id = int(request.form["asset_id"])
        starts_at = request.form["starts_at"]
        ends_at = request.form["ends_at"]
        title_override = request.form.get("title_override", "").strip() or None

        db.execute(
            """
            INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override)
            VALUES (?, ?, ?, ?, ?)
            """,
            (channel_id, asset_id, starts_at, ends_at, title_override),
        )
        db.commit()
        flash("Schedule block added.", "success")
        return redirect(url_for("admin.schedules"))

    rows = db.execute(
        """
        SELECT s.*, c.name AS channel_name, a.title AS asset_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        ORDER BY s.starts_at ASC
        """
    ).fetchall()

    channels = db.execute(
        "SELECT id, name, number FROM channels ORDER BY number ASC"
    ).fetchall()
    assets = db.execute("SELECT id, title FROM assets ORDER BY id DESC").fetchall()

    return render_template(
        "admin_schedules.html",
        schedules=rows,
        channels=channels,
        assets=assets,
    )


@admin_bp.route("/schedules/<int:schedule_id>/delete", methods=["POST"])
@login_required
def delete_schedule(schedule_id):
    db = get_db()
    db.execute("DELETE FROM schedules WHERE id=?", (schedule_id,))
    db.commit()
    flash("Schedule removed.", "info")
    return redirect(url_for("admin.schedules"))


@admin_bp.route("/plans", methods=["GET", "POST"])
@login_required
def manage_plans():
    db = get_db()

    if request.method == "POST":
        db.execute(
            """
            INSERT INTO plans (name, slug, price_cents, billing_interval, description, is_active)
            VALUES (?, ?, ?, ?, ?, 1)
            """,
            (
                request.form["name"].strip(),
                slugify(request.form.get("slug") or request.form["name"]),
                int(request.form["price_cents"]),
                request.form["billing_interval"],
                request.form.get("description", "").strip(),
            ),
        )
        db.commit()
        flash("Plan created.", "success")
        return redirect(url_for("admin.manage_plans"))

    rows = db.execute("SELECT * FROM plans ORDER BY price_cents ASC").fetchall()
    return render_template("admin_plans.html", plans=rows)


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

# ---------------------------------
# app\templates\base.html
# ---------------------------------
$baseHtml = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
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

# ---------------------------------
# app\templates\beacon.html
# ---------------------------------
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Verified active channels ready to watch.</p>
  </div>
  <span class="pill">{{ channels|length }} Channels</span>
</div>

<div class="grid-2 top-gap-sm">
  <div class="card">
    <h2>Channel Guide</h2>
    <p class="muted">Pick a channel and start watching. Use the channel page remote to move up and down.</p>
  </div>

  <div class="card">
    <h2>Quick Start</h2>
    <div class="actions top-gap-sm">
      {% if channels and channels|length > 0 %}
        <a class="btn btn-primary" href="{{ url_for('public.channel_detail', slug=channels[0]['slug']) }}">Watch First Channel</a>
      {% endif %}
      <a class="btn" href="{{ url_for('public.epg') }}">Open Guide</a>
    </div>
  </div>
</div>

<div class="guide-shell top-gap">
  <div class="guide-row guide-head">
    <div>Channel</div>
    <div>Name</div>
    <div>Category</div>
    <div>Watch</div>
  </div>

  {% for channel in channels %}
  <div class="guide-row">
    <div>CH {{ channel['number'] }}</div>
    <div>
      <strong>{{ channel['name'] }}</strong>
      {% if channel['description'] %}
        <div class="muted top-gap-sm">{{ channel['description'] }}</div>
      {% endif %}
    </div>
    <div>{{ channel['category'] or 'Live' }}</div>
    <div>
      <a class="btn btn-small btn-primary" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        Watch
      </a>
    </div>
  </div>
  {% endfor %}
</div>
{% endblock %}
'@

Write-Utf8File ".\app\templates\beacon.html" $beaconHtml

# ---------------------------------
# app\templates\channel_detail.html
# ---------------------------------
$channelDetailHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · {{ channel["name"] }}{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>{{ channel["name"] }}</h1>
    <p class="muted">{{ channel["description"] or "Live channel" }}</p>
  </div>
  <span class="pill">CH {{ channel["number"] }}</span>
</div>

<div class="actions top-gap-sm">
  {% if previous_slug %}
    <a id="prev-channel-link" class="btn" href="{{ url_for('public.channel_detail', slug=previous_slug) }}">◀ Previous</a>
  {% endif %}

  <a class="btn" href="{{ url_for('public.beacon') }}">Guide</a>

  {% if next_slug %}
    <a id="next-channel-link" class="btn btn-primary" href="{{ url_for('public.channel_detail', slug=next_slug) }}">Next ▶</a>
  {% endif %}
</div>

<div class="player-layout top-gap">
  <div class="card player-card">
    {% if play_url %}
      <video id="video" class="player" controls autoplay playsinline></video>

      <div class="top-gap-sm">
        <div class="muted">Stream URL</div>
        <div class="break">{{ play_url }}</div>
      </div>

      <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
      <script>
        const video = document.getElementById("video");
        const src = {{ play_url|tojson }};

        const STORAGE_MUTE_KEY = "culturequest_muted";
        const STORAGE_VOLUME_KEY = "culturequest_volume";

        function loadPlayerPrefs() {
          const savedMuted = localStorage.getItem(STORAGE_MUTE_KEY);
          const savedVolume = localStorage.getItem(STORAGE_VOLUME_KEY);

          if (savedMuted !== null) {
            video.muted = savedMuted === "true";
          } else {
            video.muted = false;
          }

          if (savedVolume !== null) {
            const vol = parseFloat(savedVolume);
            if (!Number.isNaN(vol) && vol >= 0 && vol <= 1) {
              video.volume = vol;
            }
          } else {
            video.volume = 1.0;
          }
        }

        function savePlayerPrefs() {
          localStorage.setItem(STORAGE_MUTE_KEY, String(video.muted));
          localStorage.setItem(STORAGE_VOLUME_KEY, String(video.volume));
        }

        function showError(message) {
          let box = document.getElementById("player-error");
          if (!box) {
            box = document.createElement("div");
            box.id = "player-error";
            box.className = "flash danger top-gap-sm";
            video.parentNode.appendChild(box);
          }
          box.textContent = message;
        }

        loadPlayerPrefs();
        video.addEventListener("volumechange", savePlayerPrefs);

        if (!src) {
          showError("No stream URL was provided.");
        } else if (window.Hls && Hls.isSupported()) {
          const hls = new Hls({
            enableWorker: true,
            lowLatencyMode: false
          });

          hls.loadSource(src);
          hls.attachMedia(video);

          hls.on(Hls.Events.MANIFEST_PARSED, function () {
            video.play().catch(() => {});
          });

          hls.on(Hls.Events.ERROR, function (event, data) {
            console.log("HLS error:", data);

            if (data && data.fatal) {
              if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                showError("Network or CORS error loading stream.");
              } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                showError("Media decode error. Stream may be incompatible.");
              } else {
                showError("Fatal HLS error. Stream may be blocked or unavailable.");
              }
            }
          });
        } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
          video.src = src;
          video.addEventListener("loadedmetadata", function () {
            video.play().catch(() => {});
          });
        } else {
          showError("This browser cannot play HLS directly.");
        }

        document.addEventListener("keydown", function (e) {
          if (e.key === "ArrowLeft") {
            const prev = document.getElementById("prev-channel-link");
            if (prev) window.location.href = prev.href;
          }

          if (e.key === "ArrowRight") {
            const next = document.getElementById("next-channel-link");
            if (next) window.location.href = next.href;
          }
        });
      </script>
    {% else %}
      <div class="placeholder">No active stream configured yet.</div>
    {% endif %}
  </div>

  <div class="card side-info">
    <h3>Channel Info</h3>
    <p><strong>Name:</strong> {{ channel["name"] }}</p>
    <p><strong>Number:</strong> {{ channel["number"] }}</p>
    <p><strong>Category:</strong> {{ channel["category"] or "Live" }}</p>

    <div class="top-gap">
      <h3>Channel Remote</h3>
      <div class="actions top-gap-sm">
        {% if previous_slug %}
          <a class="btn" href="{{ url_for('public.channel_detail', slug=previous_slug) }}">Channel -</a>
        {% endif %}
        {% if next_slug %}
          <a class="btn btn-primary" href="{{ url_for('public.channel_detail', slug=next_slug) }}">Channel +</a>
        {% endif %}
      </div>
      <p class="muted top-gap-sm">Use keyboard left/right arrows too.</p>
    </div>
  </div>
</div>
{% endblock %}
'@

Write-Utf8File ".\app\templates\channel_detail.html" $channelDetailHtml

# ---------------------------------
# Promote verified US channels
# ---------------------------------
$promotePy = @'
import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute("UPDATE channels SET is_active = 0 WHERE number < 500")
cur.execute("UPDATE channels SET is_active = 1 WHERE number >= 500")

db.commit()
db.close()

print("Disabled old channels below 500 and kept US verified channels active.")
'@

Write-Utf8File ".\promote_us_channels.py" $promotePy

Write-Host ""
Write-Host "Promoting verified US channels..." -ForegroundColor Yellow
Run-PythonFile ".\promote_us_channels.py"

Write-Host ""
Write-Host "Starting Flask..." -ForegroundColor Yellow
if (Get-Command python -ErrorAction SilentlyContinue) {
    & python .\run.py
} else {
    & py .\run.py
}