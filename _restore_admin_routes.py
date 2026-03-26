from pathlib import Path

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")

needed_blocks = []

if '@admin_bp.route("/assets", methods=["GET", "POST"])' not in text:
    needed_blocks.append("""

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

        db.execute(
            \"\"\"
            INSERT INTO assets
            (title, slug, description, file_path, public_url, duration_seconds, media_type, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            \"\"\",
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
        flash("Asset added.", "success")
        return redirect(url_for("admin.assets"))

    rows = db.execute("SELECT * FROM assets ORDER BY id DESC").fetchall()
    return render_template("admin_assets.html", assets=rows)
""")

if '@admin_bp.route("/schedules", methods=["GET", "POST"])' not in text:
    needed_blocks.append("""

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

        db.execute(
            \"\"\"
            INSERT INTO schedules (channel_id, asset_id, starts_at, ends_at, title_override)
            VALUES (?, ?, ?, ?, ?)
            \"\"\",
            (channel_id, asset_id, starts_at, ends_at, title_override),
        )
        db.commit()
        flash("Schedule block added.", "success")
        return redirect(url_for("admin.schedules"))

    rows = db.execute(
        \"\"\"
        SELECT s.*, c.name AS channel_name, a.title AS asset_title
        FROM schedules s
        JOIN channels c ON c.id = s.channel_id
        JOIN assets a ON a.id = s.asset_id
        ORDER BY s.starts_at ASC
        \"\"\"
    ).fetchall()

    channels = db.execute("SELECT id, name, number FROM channels ORDER BY number ASC").fetchall()
    assets = db.execute("SELECT id, title FROM assets ORDER BY id DESC").fetchall()

    return render_template(
        "admin_schedules.html",
        schedules=rows,
        channels=channels,
        assets=assets,
    )
""")

if '@admin_bp.route("/plans", methods=["GET", "POST"])' not in text:
    needed_blocks.append("""

@admin_bp.route("/plans", methods=["GET", "POST"])
@login_required
def manage_plans():
    db = get_db()

    if request.method == "POST":
        db.execute(
            \"\"\"
            INSERT INTO plans (name, slug, price_cents, billing_interval, description, is_active)
            VALUES (?, ?, ?, ?, ?, 1)
            \"\"\",
            (
                request.form.get("name", "").strip(),
                slugify(request.form.get("slug") or request.form.get("name", "")),
                int(request.form.get("price_cents") or 0),
                request.form.get("billing_interval", "monthly"),
                request.form.get("description", "").strip(),
            ),
        )
        db.commit()
        flash("Plan created.", "success")
        return redirect(url_for("admin.manage_plans"))

    rows = db.execute("SELECT * FROM plans ORDER BY price_cents ASC").fetchall()
    return render_template("admin_plans.html", plans=rows)
""")

if needed_blocks:
    text = text.rstrip() + "\n\n" + "\n\n".join(needed_blocks) + "\n"
    path.write_text(text, encoding="utf-8")
    print("Restored missing admin routes.")
else:
    print("All admin routes already present.")
