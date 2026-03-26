$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Utf8File {
    param([string]$Path,[string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Content | Set-Content -Path $Path -Encoding utf8
    Write-Host ("Wrote " + $Path) -ForegroundColor Green
}

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Search + Cleanup Patch" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------
# 1) Remove duplicate /streams decorators and orphan defs
# -------------------------------------------------
@'
from pathlib import Path

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

out = []
skip_mode = False
seen_stream_route = False

i = 0
while i < len(lines):
    line = lines[i].rstrip("\n")
    stripped = line.strip()

    # kill single-quote duplicate decorator
    if stripped == "@public_bp.route('/streams/<path:filename>')":
        i += 1
        continue

    # handle main double-quote decorator
    if stripped == '@public_bp.route("/streams/<path:filename>")':
        if seen_stream_route:
            i += 1
            continue
        seen_stream_route = True
        out.append(line)
        i += 1
        continue

    # remove orphan def streams not immediately preceded by the decorator
    if stripped == "def streams(filename):":
        prev = out[-1].strip() if out else ""
        if prev != '@public_bp.route("/streams/<path:filename>")':
            i += 1
            while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
                i += 1
            continue
        out.append(line)
        i += 1
        continue

    out.append(line)
    i += 1

path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("Cleaned duplicate streams route definitions.")
'@ | Set-Content .\_cleanup_streams_route.py -Encoding utf8

python .\_cleanup_streams_route.py

# -------------------------------------------------
# 2) Add channel search route if missing
# -------------------------------------------------
@'
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
'@ | Set-Content .\_add_search_route.py -Encoding utf8

python .\_add_search_route.py

# -------------------------------------------------
# 3) Add search template
# -------------------------------------------------
$searchHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Search{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Search Channels</h1>
    <p class="muted">Find channels by name, category, slug, or description.</p>
  </div>
</div>

<div class="card">
  <form method="get" action="{{ url_for('public.search_channels') }}" class="search-bar">
    <input type="text" name="q" value="{{ query }}" placeholder="Search channels...">
    <button class="btn btn-primary" type="submit">Search</button>
  </form>
</div>

{% if query %}
<div class="section-head top-gap">
  <h2>Results for "{{ query }}"</h2>
  <span class="pill">{{ channels|length }} found</span>
</div>

<div class="browse-grid">
  {% for channel in channels %}
    <a class="browse-card" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
      <strong>{{ channel['name'] }}</strong>
      <span>CH {{ channel['number'] }}{% if channel['category'] %} · {{ channel['category'] }}{% endif %}</span>
    </a>
  {% endfor %}
</div>
{% endif %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\search.html" $searchHtml

# -------------------------------------------------
# 4) Patch base.html nav with search link + search form
# -------------------------------------------------
@'
from pathlib import Path

path = Path(r".\app\templates\base.html")
text = path.read_text(encoding="utf-8")

if 'url_for(\'public.search_channels\')' not in text and 'url_for("public.search_channels")' not in text:
    nav_marker = '<a href="{{ url_for(\'public.epg\') }}">Guide</a>'
    replacement = nav_marker + '\n        <a href="{{ url_for(\'public.search_channels\') }}">Search</a>'
    text = text.replace(nav_marker, replacement)

if 'class="topbar-search"' not in text:
    marker = '</nav>'
    inject = '''
      <form class="topbar-search" method="get" action="{{ url_for('public.search_channels') }}">
        <input type="text" name="q" placeholder="Search">
      </form>
'''
    text = text.replace(marker, marker + inject, 1)

path.write_text(text, encoding="utf-8")
print("Patched base.html with search.")
'@ | Set-Content .\_patch_base_search.py -Encoding utf8

python .\_patch_base_search.py

# -------------------------------------------------
# 5) CSS for search
# -------------------------------------------------
if (Test-Path ".\app\static\style.css") {
    $css = Get-Content ".\app\static\style.css" -Raw
    if ($css -notmatch "topbar-search") {
        Add-Content ".\app\static\style.css" @'

.topbar-search{
  display:flex;
  align-items:center;
  margin-left:12px;
}
.topbar-search input,
.search-bar input{
  width:100%;
  min-width:180px;
  background:rgba(255,255,255,.08);
  border:1px solid rgba(255,255,255,.14);
  color:#fff;
  border-radius:12px;
  padding:10px 12px;
}
.search-bar{
  display:grid;
  grid-template-columns:1fr auto;
  gap:12px;
}
@media (max-width: 900px){
  .topbar-search{
    width:100%;
    margin:12px 0 0 0;
  }
  .topbar-search input{
    width:100%;
    min-width:0;
  }
}
'@
        Write-Host "Updated app\static\style.css" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Patch complete." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Yellow
Write-Host "  py .\run.py"
Write-Host ""
Write-Host "Search URL:" -ForegroundColor Yellow
Write-Host "  http://127.0.0.1:5000/search"
Write-Host ""
Write-Host "Docker proxy reminders:" -ForegroundColor Yellow
Write-Host "  Samsung proxy expected at http://localhost:8182/playlist.m3u8"
Write-Host "  Tubi proxy expected at http://localhost:7779/playlist.m3u8"
Write-Host ""
Write-Host "Then run your sync after proxies are up." -ForegroundColor Yellow