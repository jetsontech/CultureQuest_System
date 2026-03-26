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
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Speed Fix" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# 1) Keep only healthy channels active
$promoteHealthy = @'
import sqlite3

db = sqlite3.connect(r".\instance\culturequest.db")
cur = db.cursor()

cur.execute("UPDATE channels SET is_active = 0")
cur.execute("UPDATE channels SET is_active = 1 WHERE health_status = 'healthy'")

db.commit()
db.close()

print("Only healthy channels left active.")
'@
Write-Utf8File ".\promote_healthy_only.py" $promoteHealthy

if (Get-Command python -ErrorAction SilentlyContinue) {
    & python .\promote_healthy_only.py
} else {
    & py .\promote_healthy_only.py
}

# 2) Fast beacon route
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
        SELECT id, number, name, slug, description, category, health_status
        FROM channels
        WHERE is_active = 1
        ORDER BY number ASC
        LIMIT 48
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
    }
    return render_template(
        "admin_dashboard.html",
        stats=stats,
        guide=[],
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

# 3) Faster beacon template
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Healthy channels only.</p>
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
    <div><span class="pill">{{ channel['health_status'] or 'healthy' }}</span></div>
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

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Run next:" -ForegroundColor Green
Write-Host "  py .\run.py"
Write-Host "Then open:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/beacon"