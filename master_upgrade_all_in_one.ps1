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

function Ensure-LineInFile {
    param(
        [string]$Path,
        [string]$Line
    )
    if (!(Test-Path $Path)) {
        $Line | Set-Content -Path $Path -Encoding utf8
        return
    }
    $content = Get-Content $Path -Raw
    if ($content -notmatch [regex]::Escape($Line)) {
        Add-Content -Path $Path -Value $Line
        Write-Host ("Added to " + $Path + ": " + $Line) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CultureQuest Master Upgrade All-In-One" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Ensure-LineInFile ".\requirements.txt" "requests"

# -----------------------------------------
# app\db_upgrade.py
# -----------------------------------------
$dbUpgrade = @'
from .db import get_db

def ensure_channel_upgrade_columns():
    db = get_db()

    existing = db.execute("PRAGMA table_info(channels)").fetchall()
    cols = {row["name"] for row in existing}

    wanted = {
        "fallback_stream_url": "TEXT",
        "health_status": "TEXT DEFAULT 'unknown'",
        "health_detail": "TEXT DEFAULT ''",
        "needs_relay": "INTEGER DEFAULT 0",
        "last_health_check": "TEXT DEFAULT ''",
        "logo_url": "TEXT DEFAULT ''"
    }

    for name, sql_type in wanted.items():
        if name not in cols:
            db.execute(f"ALTER TABLE channels ADD COLUMN {name} {sql_type}")

    db.commit()
'@
Write-Utf8File ".\app\db_upgrade.py" $dbUpgrade

# -----------------------------------------
# app/hls_proxy.py
# -----------------------------------------
$hlsProxy = @'
import requests
from urllib.parse import urljoin
from flask import Blueprint, Response, abort, request
from .db import get_db

hls_bp = Blueprint("hls", __name__, url_prefix="/hls")

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/122.0.0.0 Safari/537.36"
    ),
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Connection": "keep-alive",
})


def get_channel_by_slug(slug):
    db = get_db()
    return db.execute(
        "SELECT * FROM channels WHERE slug = ? AND is_active = 1",
        (slug,)
    ).fetchone()


def fetch_url(url):
    try:
        resp = SESSION.get(url, timeout=20, allow_redirects=True, stream=False)
        resp.raise_for_status()
        return resp
    except Exception:
        return None


@hls_bp.route("/<slug>/index.m3u8")
def proxy_manifest(slug):
    channel = get_channel_by_slug(slug)
    if not channel:
        abort(404)

    source_url = (channel["stream_url"] or "").strip()
    if not source_url:
        fallback = (channel["fallback_stream_url"] or "").strip()
        if fallback:
            source_url = fallback
        else:
            abort(404)

    resp = fetch_url(source_url)
    if not resp:
        fallback = (channel["fallback_stream_url"] or "").strip()
        if fallback and fallback != source_url:
            resp = fetch_url(fallback)
            source_url = fallback

    if not resp:
        abort(502)

    text = resp.text
    base_url = resp.url

    out_lines = []
    for raw_line in text.splitlines():
        line = raw_line.strip()

        if not line:
            out_lines.append(raw_line)
            continue

        if line.startswith("#EXT-X-KEY:") and 'URI="' in line:
            prefix, rest = line.split('URI="', 1)
            key_uri, suffix = rest.split('"', 1)
            absolute = urljoin(base_url, key_uri)
            proxied = f'/hls/{slug}/segment?url={absolute}'
            out_lines.append(f'{prefix}URI="{proxied}"{suffix}')
            continue

        if line.startswith("#"):
            out_lines.append(raw_line)
            continue

        absolute = urljoin(base_url, line)
        out_lines.append(f"/hls/{slug}/segment?url={absolute}")

    return Response(
        "\n".join(out_lines),
        content_type="application/vnd.apple.mpegurl"
    )


@hls_bp.route("/<slug>/segment")
def proxy_segment(slug):
    channel = get_channel_by_slug(slug)
    if not channel:
        abort(404)

    url = request.args.get("url", "").strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        abort(400)

    resp = fetch_url(url)
    if not resp:
        abort(502)

    content_type = resp.headers.get("Content-Type", "application/octet-stream")
    headers = {
        "Cache-Control": "no-cache",
        "Access-Control-Allow-Origin": "*",
    }
    return Response(resp.content, content_type=content_type, headers=headers)
'@
Write-Utf8File ".\app\hls_proxy.py" $hlsProxy

# -----------------------------------------
# app/__init__.py
# -----------------------------------------
$initPy = @'
import os
from flask import Flask
from .db import close_db, init_db_command
from .views import public_bp, admin_bp, api_bp
from .hls_proxy import hls_bp
from .db_upgrade import ensure_channel_upgrade_columns


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
        ensure_channel_upgrade_columns()

    app.register_blueprint(public_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(hls_bp)

    return app
'@
Write-Utf8File ".\app\__init__.py" $initPy

# -----------------------------------------
# app/views.py
# -----------------------------------------
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
        ORDER BY
            CASE health_status
                WHEN 'healthy' THEN 1
                WHEN 'manifest_ok' THEN 2
                WHEN 'relay_needed' THEN 3
                ELSE 4
            END,
            number ASC
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

    if channel.get("stream_url") and str(channel.get("stream_url")).strip():
        stream_url = channel["stream_url"].strip()

        if (
            stream_url.startswith("http://127.0.0.1:5000/")
            or stream_url.startswith("http://localhost:5000/")
            or "/streams/" in stream_url
            or "/hls/" in stream_url
        ):
            play_url = stream_url
        else:
            play_url = url_for("hls.proxy_manifest", slug=channel["slug"])

    elif channel.get("fallback_stream_url") and str(channel.get("fallback_stream_url")).strip():
        fallback = channel["fallback_stream_url"].strip()
        if (
            fallback.startswith("http://127.0.0.1:5000/")
            or fallback.startswith("http://localhost:5000/")
            or "/streams/" in fallback
            or "/hls/" in fallback
        ):
            play_url = fallback
        else:
            play_url = url_for("hls.proxy_manifest", slug=channel["slug"])

    elif guide and guide.get("stream_url") and str(guide.get("stream_url")).strip():
        play_url = guide["stream_url"]

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
        "healthy_channels": db.execute(
            "SELECT COUNT(*) AS c FROM channels WHERE health_status = 'healthy'"
        ).fetchone()["c"],
        "relay_channels": db.execute(
            "SELECT COUNT(*) AS c FROM channels WHERE needs_relay = 1"
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
        fallback_stream_url = request.form.get("fallback_stream_url", "").strip()
        is_premium = 1 if request.form.get("is_premium") else 0
        now = datetime.utcnow().isoformat()

        try:
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

# -----------------------------------------
# app/templates/beacon.html
# -----------------------------------------
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Healthy channels are shown first. Relay-needed channels still appear if active.</p>
  </div>
  <span class="pill">{{ channels|length }} Channels</span>
</div>

<div class="guide-shell top-gap">
  <div class="guide-row guide-head">
    <div>Channel</div>
    <div>Name</div>
    <div>Status</div>
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
    <div>
      {% if channel['health_status'] == 'healthy' %}
        <span class="pill">Healthy</span>
      {% elif channel['health_status'] == 'manifest_ok' %}
        <span class="pill">Manifest OK</span>
      {% elif channel['health_status'] == 'relay_needed' %}
        <span class="pill">Relay</span>
      {% else %}
        <span class="pill">Unknown</span>
      {% endif %}
    </div>
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

# -----------------------------------------
# app/templates/channel_detail.html
# -----------------------------------------
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
        <div class="muted">Playback URL</div>
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

          video.muted = savedMuted === null ? false : savedMuted === "true";

          if (savedVolume !== null) {
            const vol = parseFloat(savedVolume);
            if (!Number.isNaN(vol) && vol >= 0 && vol <= 1) {
              video.volume = vol;
            } else {
              video.volume = 1.0;
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
            lowLatencyMode: false,
            backBufferLength: 90,
            manifestLoadingMaxRetry: 6,
            levelLoadingMaxRetry: 6,
            fragLoadingMaxRetry: 6
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
                showError("Stream network error. Source may block playback or be temporarily unavailable.");
                hls.startLoad();
              } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                showError("Media decode error. Trying recovery...");
                hls.recoverMediaError();
              } else {
                showError("Fatal playback error. This channel may be blocked or offline.");
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

          if (e.key.toLowerCase() === "m") {
            video.muted = !video.muted;
            savePlayerPrefs();
          }

          if (e.key.toLowerCase() === "f") {
            if (video.requestFullscreen) {
              video.requestFullscreen();
            }
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
    <p><strong>Status:</strong> {{ channel["health_status"] or "unknown" }}</p>

    <div class="top-gap">
      <h3>Remote</h3>
      <div class="actions top-gap-sm">
        {% if previous_slug %}
          <a class="btn" href="{{ url_for('public.channel_detail', slug=previous_slug) }}">Channel -</a>
        {% endif %}
        {% if next_slug %}
          <a class="btn btn-primary" href="{{ url_for('public.channel_detail', slug=next_slug) }}">Channel +</a>
        {% endif %}
      </div>
      <p class="muted top-gap-sm">Keys: ← → channel, M mute, F fullscreen</p>
    </div>
  </div>
</div>
{% endblock %}
'@
Write-Utf8File ".\app\templates\channel_detail.html" $channelDetailHtml

# -----------------------------------------
# scripts/channel_health_check.py
# -----------------------------------------
$healthCheck = @'
import sqlite3
import ssl
import urllib.request
import urllib.error
from datetime import datetime

DB = r".\instance\culturequest.db"

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE


def fetch(url, limit=4096):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "*/*",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=12, context=ssl_ctx) as resp:
        body = resp.read(limit)
        status = getattr(resp, "status", 200)
        content_type = resp.headers.get("Content-Type", "")
    return status, content_type, body


db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row
cur = db.cursor()

rows = cur.execute("""
    SELECT id, slug, name, stream_url, fallback_stream_url
    FROM channels
    ORDER BY number ASC
""").fetchall()

healthy = 0
manifest_ok = 0
relay_needed = 0
offline = 0

for row in rows:
    url = (row["stream_url"] or "").strip()
    fallback = (row["fallback_stream_url"] or "").strip()

    status_value = "offline"
    detail = "blank stream_url"
    needs_relay = 0
    active = 0

    urls_to_try = [u for u in [url, fallback] if u]

    for candidate in urls_to_try:
        try:
            status, content_type, body = fetch(candidate)
            text = body.decode("utf-8", errors="ignore")

            if status == 200 and ("#EXTM3U" in text or "mpegurl" in content_type.lower()):
                status_value = "manifest_ok"
                detail = f"manifest reachable via {candidate}"
                needs_relay = 1
                active = 1

                # crude segment hint
                if ".ts" in text or ".m4s" in text or "#EXTINF" in text:
                    status_value = "healthy"
                    detail = f"manifest + segments hinted via {candidate}"
                    needs_relay = 0

                break

        except Exception as e:
            detail = str(e)[:180]

    if status_value == "healthy":
        healthy += 1
    elif status_value == "manifest_ok":
        manifest_ok += 1
        needs_relay = 1
    elif status_value == "relay_needed":
        relay_needed += 1
    else:
        offline += 1

    if status_value == "manifest_ok":
        relay_needed += 1

    cur.execute(
        """
        UPDATE channels
        SET health_status = ?,
            health_detail = ?,
            needs_relay = ?,
            is_active = ?,
            last_health_check = ?
        WHERE id = ?
        """,
        (
            status_value,
            detail,
            needs_relay,
            active,
            datetime.utcnow().isoformat(timespec="seconds"),
            row["id"],
        ),
    )

db.commit()
db.close()

print(f"healthy={healthy}")
print(f"manifest_ok={manifest_ok}")
print(f"relay_needed={relay_needed}")
print(f"offline={offline}")
'@
Write-Utf8File ".\scripts\channel_health_check.py" $healthCheck

Write-Host ""
Write-Host "Installing requirements..." -ForegroundColor Yellow
pip install -r .\requirements.txt

Write-Host ""
Write-Host "Running channel health check..." -ForegroundColor Yellow
if (Get-Command python -ErrorAction SilentlyContinue) {
    & python .\scripts\channel_health_check.py
} else {
    & py .\scripts\channel_health_check.py
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Green
Write-Host "  py .\run.py"
Write-Host ""
Write-Host "Then test:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/beacon"
Write-Host "  http://127.0.0.1:5000/channel/bbc-america"
Write-Host "  http://127.0.0.1:5000/hls/bbc-america/index.m3u8"