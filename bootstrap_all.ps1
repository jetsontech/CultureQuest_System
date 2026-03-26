param(
    [Parameter(Mandatory=$true)]
    [string]$M3UFile,

    [int]$Limit = 150,
    [int]$StartNumber = 300
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Test-CommandExists {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

function Run-Python {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)
    if (Test-CommandExists "python") {
        & python @PyArgs
        return $LASTEXITCODE
    }
    & py @PyArgs
    return $LASTEXITCODE
}

function Ensure-Dir {
    param([string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Ensure-Utf8 {
    param([string[]]$Files)
    foreach ($f in $Files) {
        if (Test-Path $f) {
            $content = Get-Content $f -Raw
            Set-Content $f -Value $content -Encoding utf8
            Write-Host "UTF8 OK: $f"
        }
    }
}

Ensure-Dir ".\app\templates"
Ensure-Dir ".\scripts"
Ensure-Dir ".\instance"

# -----------------------------
# Fresh epg.html
# -----------------------------
@'
{% extends "base.html" %}
{% block title %}CultureQuest · EPG{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>EPG</h1>
    <p class="muted">Electronic program guide for scheduled channels.</p>
  </div>
  <span class="pill">Live Schedule</span>
</div>

{% if epg and epg|length > 0 %}
<div class="guide-shell">
  <div class="guide-row guide-head">
    <div>Channel</div>
    <div>Start</div>
    <div>End</div>
    <div>Program</div>
  </div>

  {% for row in epg %}
  <div class="guide-row">
    <div>{{ row['channel_name'] }}</div>
    <div>{{ row['starts_at'] }}</div>
    <div>{{ row['ends_at'] }}</div>
    <div>{{ row['program_title'] }}</div>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="card">
  <h2>No schedule data yet</h2>
  <p class="muted">Upload assets and generate schedules to populate the electronic program guide.</p>
  <div class="actions top-gap-sm">
    <a class="btn btn-primary" href="{{ url_for('admin.assets') }}">Upload Assets</a>
    <a class="btn" href="{{ url_for('admin.schedules') }}">Manage Schedules</a>
    <a class="btn" href="{{ url_for('public.beacon') }}">Back to Beacon</a>
  </div>
</div>
{% endif %}
{% endblock %}
'@ | Set-Content .\app\templates\epg.html -Encoding utf8

# -----------------------------
# Fresh views.py
# -----------------------------
@'
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


def slugify(value):
    return value.strip().lower().replace(" ", "-").replace("_", "-")


@public_bp.route("/")
def home():
    return render_template("home.html", guide=guide_items()[:6], plans=plans())


@public_bp.route("/beacon")
def beacon():
    return render_template("beacon.html", guide=guide_items())


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
        WHERE s.ends_at >= datetime('now')
        ORDER BY c.number ASC, s.starts_at ASC
        LIMIT 500
        """
    ).fetchall()
    return render_template("epg.html", epg=rows)


@public_bp.route("/channel/<slug>")
def channel_detail(slug):
    channel = get_channel_by_slug(slug)
    if not channel:
        flash("Channel not found.", "danger")
        return redirect(url_for("public.beacon"))

    schedule = get_channel_schedule(channel["id"])
    guide = next((x for x in guide_items() if x["slug"] == slug), None)

    play_url = ""
    if guide and guide.get("stream_url"):
        play_url = guide["stream_url"]
    elif channel.get("stream_url"):
        play_url = channel["stream_url"]
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
            if current_asset["public_url"]:
                play_url = current_asset["public_url"]
            elif current_asset["file_path"]:
                play_url = url_for(
                    "public.uploaded_file",
                    filename=os.path.basename(current_asset["file_path"]),
                )

    return render_template(
        "channel_detail.html",
        channel=channel,
        schedule=schedule,
        play_url=play_url,
        guide=guide,
    )


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
        "channels": db.execute("SELECT COUNT(*) c FROM channels").fetchone()["c"],
        "assets": db.execute("SELECT COUNT(*) c FROM assets").fetchone()["c"],
        "schedules": db.execute("SELECT COUNT(*) c FROM schedules").fetchone()["c"],
        "premium_channels": db.execute(
            "SELECT COUNT(*) c FROM channels WHERE is_premium = 1"
        ).fetchone()["c"],
    }
    return render_template("admin_dashboard.html", stats=stats, guide=guide_items()[:8])


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
                (number, name, slug, description, category, stream_url, is_premium, now),
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
'@ | Set-Content .\app\views.py -Encoding utf8

# -----------------------------
# Fresh import_m3u.ps1
# -----------------------------
@'
param(
    [Parameter(Mandatory=$true)]
    [string]$M3UFile,

    [string]$OutCsv = ".\channels_from_m3u.csv",

    [int]$Limit = 200,

    [int]$StartNumber = 300
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Test-CommandExists {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

function Run-Python {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)

    if (Test-CommandExists "python") {
        & python @PyArgs
        return $LASTEXITCODE
    }

    & py @PyArgs
    return $LASTEXITCODE
}

if (!(Test-Path $M3UFile)) {
    throw "M3U file not found: $M3UFile"
}

$dbPath = Join-Path $PSScriptRoot "instance\culturequest.db"
if (!(Test-Path $dbPath)) {
    throw "Database not found: $dbPath"
}

$lines = Get-Content $M3UFile
$rows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()

    if ($line -like "#EXTINF:*") {
        $name = ""
        $category = "Live"

        if ($line -match 'group-title="([^"]+)"') {
            $category = $matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($category)) {
                $category = "Live"
            }
        }

        if ($line -match ',(.*)$') {
            $name = $matches[1].Trim()
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "Channel-$($rows.Count + 1)"
        }

        $urlIndex = $i + 1
        if ($urlIndex -lt $lines.Count) {
            $url = $lines[$urlIndex].Trim()
            if ($url -match '^https?://') {
                $rows.Add([pscustomobject]@{
                    name        = $name
                    category    = $category
                    stream_url  = $url
                    is_premium  = "false"
                    is_active   = "true"
                })
            }
        }
    }

    if ($rows.Count -ge $Limit) {
        break
    }
}

if ($rows.Count -eq 0) {
    throw "No stream entries were parsed from the M3U."
}

$rows | Export-Csv -NoTypeInformation -Encoding utf8 $OutCsv

$tmpPy = Join-Path $PSScriptRoot "_cq_import_m3u_tmp.py"

$py = @"
import csv
import sqlite3
from pathlib import Path
import re

db_path = Path(r"$dbPath")
csv_path = Path(r"$OutCsv")
start_number = int($StartNumber)

def slugify(value: str) -> str:
    s = (value or "").strip().lower()
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s or "channel"

def as_bool(v, default=False):
    if v is None:
        return default
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "y", "on")

with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

existing_numbers = {row["number"] for row in cur.execute("SELECT number FROM channels").fetchall()}

def next_number():
    global start_number
    while start_number in existing_numbers:
        start_number += 1
    n = start_number
    existing_numbers.add(n)
    start_number += 1
    return n

created = 0
updated = 0
skipped = 0

for raw in rows:
    name = str(raw.get("name", "")).strip()
    stream_url = str(raw.get("stream_url", "")).strip()
    category = str(raw.get("category", "")).strip() or "Live"

    if not name or not stream_url:
        skipped += 1
        continue

    slug = slugify(name)
    existing = cur.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()

    if existing:
        cur.execute(
            '''
            UPDATE channels
            SET name = ?, category = ?, description = ?, stream_url = ?, is_premium = ?, is_active = ?
            WHERE slug = ?
            ''',
            (
                name,
                category,
                f"{name} imported from M3U",
                stream_url,
                1 if as_bool(raw.get("is_premium"), False) else 0,
                1 if as_bool(raw.get("is_active"), True) else 0,
                slug
            )
        )
        updated += 1
    else:
        number = next_number()
        cur.execute(
            '''
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ''',
            (
                number,
                name,
                slug,
                f"{name} imported from M3U",
                category,
                stream_url,
                1 if as_bool(raw.get("is_premium"), False) else 0,
                1 if as_bool(raw.get("is_active"), True) else 0
            )
        )
        created += 1

conn.commit()
conn.close()

print(f"Created: {created}")
print(f"Updated: {updated}")
print(f"Skipped: {skipped}")
"@

Set-Content $tmpPy -Value $py -Encoding utf8
Run-Python $tmpPy
$exit = $LASTEXITCODE
Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

if ($exit -ne 0) {
    throw "Import failed."
}
'@ | Set-Content .\import_m3u.ps1 -Encoding utf8

# -----------------------------
# Fresh scheduler
# -----------------------------
@'
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
import itertools

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "instance" / "culturequest.db"

conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

cur.execute("DELETE FROM schedules WHERE starts_at >= datetime('now')")

channels = cur.execute("""
    SELECT id, number, name, slug, category, is_active
    FROM channels
    WHERE is_active = 1
    ORDER BY number ASC
""").fetchall()

assets = cur.execute("""
    SELECT id, title, file_path, public_url, duration_seconds, media_type
    FROM assets
    WHERE COALESCE(media_type, 'video') IN ('video', 'audio')
    ORDER BY id ASC
""").fetchall()

if not channels:
    print("No active channels found.")
    conn.close()
    raise SystemExit

if not assets:
    print("No assets found. Upload assets first.")
    conn.close()
    raise SystemExit

def classify(asset):
    t = (asset["title"] or "").lower()
    if "sport" in t or "game" in t or "match" in t or "recap" in t:
        return "Sports"
    if "news" in t or "report" in t or "update" in t:
        return "News"
    if "doc" in t or "history" in t or "story" in t:
        return "Documentary"
    if "kid" in t or "family" in t or "cartoon" in t:
        return "Kids"
    if "music" in t or "jam" in t or "concert" in t:
        return "Music"
    return "General"

asset_buckets = {}
for a in assets:
    key = classify(a)
    asset_buckets.setdefault(key, []).append(a)
    asset_buckets.setdefault("General", []).append(a)

def pool_for(ch):
    category = ch["category"] or "General"
    return asset_buckets.get(category, asset_buckets["General"])

now = datetime.utcnow().replace(second=0, microsecond=0)
minute = 0 if now.minute < 30 else 30
start = now.replace(minute=minute)
end_limit = start + timedelta(hours=48)

created = 0

for ch in channels:
    pool = pool_for(ch)
    cycler = itertools.cycle(pool)
    cursor = start
    while cursor < end_limit:
        asset = next(cycler)
        dur = int(asset["duration_seconds"] or 1800)
        if dur < 60:
            dur = 60
        end = cursor + timedelta(seconds=dur)

        cur.execute("""
            INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override)
            VALUES (?, ?, ?, ?, ?)
        """, (
            ch["id"],
            asset["id"],
            cursor.isoformat(timespec="minutes"),
            end.isoformat(timespec="minutes"),
            None
        ))
        created += 1
        cursor = end

conn.commit()
conn.close()
print(f"Schedule rows created: {created}")
'@ | Set-Content .\scripts\generate_schedule.py -Encoding utf8

# -----------------------------
# Normalize text files
# -----------------------------
Ensure-Utf8 @(
    ".\app\views.py",
    ".\app\templates\epg.html",
    ".\import_m3u.ps1",
    ".\scripts\generate_schedule.py"
)

# -----------------------------
# Init DB
# -----------------------------
Write-Host "Initializing database..." -ForegroundColor Yellow
Run-Python ".\init_db.py"

# -----------------------------
# Import channels from M3U
# -----------------------------
Write-Host "Importing channels from M3U..." -ForegroundColor Yellow
& .\import_m3u.ps1 -M3UFile $M3UFile -Limit $Limit -StartNumber $StartNumber

# -----------------------------
# Generate schedules
# -----------------------------
Write-Host "Generating schedules..." -ForegroundColor Yellow
Run-Python ".\scripts\generate_schedule.py"

# -----------------------------
# Open browser + run app
# -----------------------------
Start-Process "http://127.0.0.1:5000"
Start-Process "http://127.0.0.1:5000/beacon"
Start-Process "http://127.0.0.1:5000/epg"
Start-Process "http://127.0.0.1:5000/admin/login"

Write-Host ""
Write-Host "Starting CultureQuest..." -ForegroundColor Green
Run-Python ".\run.py"