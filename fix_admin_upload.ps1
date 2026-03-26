$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host ""
Write-Host "======================================"
Write-Host " CultureQuest Admin Upload Fix"
Write-Host "======================================"
Write-Host ""

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )
    $Content | Set-Content -Path $Path -Encoding utf8
    Write-Host ("Wrote " + $Path) -ForegroundColor Green
}

# ---------------------------
# Rewrite views.py
# ---------------------------
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

        upload_file = request.files.get("upload_file")
        uploaded_public_url = ""

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

        channel_row = db.execute(
            "SELECT id FROM channels WHERE slug = ?",
            (slug,)
        ).fetchone()

        if upload_file and upload_file.filename:
            filename = secure_filename(upload_file.filename)
            dest = os.path.join(current_app.config["UPLOAD_FOLDER"], filename)
            upload_file.save(dest)

            uploaded_public_url = url_for(
                "public.uploaded_file",
                filename=filename
            )

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
                    """
                    UPDATE channels
                    SET stream_url = ?
                    WHERE id = ?
                    """,
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
'@

Write-Utf8File ".\app\views.py" $viewsPy

# ---------------------------
# Rewrite admin_channels.html
# ---------------------------
$html = @'
{% extends "base.html" %}
{% block content %}
<h1>Channels</h1>

<form method="post" enctype="multipart/form-data">
Name <input name="name" required><br>
Slug <input name="slug"><br>
Number <input name="number" type="number" required><br>
Category <input name="category" required><br>
Description <input name="description"><br>
Primary Stream URL <input name="stream_url"><br>
Fallback Stream URL <input name="fallback_stream_url"><br>
Upload Video <input type="file" name="upload_file"><br>
Premium <input type="checkbox" name="is_premium"><br>
<button type="submit">Create Channel</button>
</form>

<hr>

{% for channel in channels %}
<form method="post" action="{{ url_for('admin.edit_channel', channel_id=channel['id']) }}">
{{ channel['number'] }}
<input name="name" value="{{ channel['name'] }}">
<input name="slug" value="{{ channel['slug'] }}">
<input name="category" value="{{ channel['category'] }}">
<input name="stream_url" value="{{ channel['stream_url'] }}">
<input name="fallback_stream_url" value="{{ channel['fallback_stream_url'] }}">
Active <input type="checkbox" name="is_active" {% if channel['is_active'] %}checked{% endif %}>
<button type="submit">Save</button>
</form>
<hr>
{% endfor %}
{% endblock %}
'@

Write-Utf8File ".\app\templates\admin_channels.html" $html

Write-Host ""
Write-Host "Admin upload fix complete."
Write-Host "Restart server:"
Write-Host "py .\run.py"