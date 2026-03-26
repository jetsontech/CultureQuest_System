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

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest HLS Proxy Master Fix" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------
# app/hls_proxy.py
# -----------------------------
$hlsProxy = @'
import requests
from urllib.parse import urljoin
from flask import Blueprint, Response, abort, request
from .db import get_db

hls_bp = Blueprint("hls", __name__, url_prefix="/hls")

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "Mozilla/5.0 CultureQuest/1.0",
    "Accept": "*/*",
})


def get_channel_by_slug(slug):
    db = get_db()
    row = db.execute(
        "SELECT * FROM channels WHERE slug = ? AND is_active = 1",
        (slug,)
    ).fetchone()
    return row


def fetch_url(url):
    try:
        resp = SESSION.get(url, timeout=15, allow_redirects=True)
        resp.raise_for_status()
        return resp
    except Exception:
        return None


@hls_bp.route("/<slug>/index.m3u8")
def proxy_manifest(slug):
    channel = get_channel_by_slug(slug)
    if not channel or not channel["stream_url"]:
        abort(404)

    source_url = channel["stream_url"].strip()
    resp = fetch_url(source_url)
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

    new_manifest = "\n".join(out_lines)
    return Response(new_manifest, content_type="application/vnd.apple.mpegurl")


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
    return Response(resp.content, content_type=content_type)
'@
Write-Utf8File ".\app\hls_proxy.py" $hlsProxy

# -----------------------------
# app/__init__.py
# -----------------------------
$initPy = @'
import os
from flask import Flask
from .db import close_db, init_db_command
from .views import public_bp, admin_bp, api_bp
from .hls_proxy import hls_bp


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

    app.register_blueprint(public_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(hls_bp)

    return app
'@
Write-Utf8File ".\app\__init__.py" $initPy

# -----------------------------
# app/views.py
# -----------------------------
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

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Restart with:" -ForegroundColor Green
Write-Host "  py .\run.py"
Write-Host ""
Write-Host "Test with:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/channel/bbc-america"
Write-Host "  http://127.0.0.1:5000/hls/bbc-america/index.m3u8"