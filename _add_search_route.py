from pathlib import Path

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")

if '@public_bp.route("/search")' not in text:
    insert_block = '''

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
'''
    marker = '@public_bp.route("/epg")'
    if marker in text:
        text = text.replace(marker, insert_block + "\n\n" + marker, 1)
    else:
        text += "\n" + insert_block + "\n"

    path.write_text(text, encoding="utf-8")
    print("Added /search route.")
else:
    print("/search route already present.")
