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
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " CultureQuest Stream Stability Fix" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------
# requirements.txt
# ---------------------------------
Ensure-LineInFile ".\requirements.txt" "requests"

# ---------------------------------
# app/hls_proxy.py
# ---------------------------------
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

        # rewrite encryption key URIs too
        if line.startswith("#EXT-X-KEY:") and 'URI="' in line:
            prefix, rest = line.split('URI="', 1)
            key_uri, suffix = rest.split('"', 1)
            absolute = urljoin(base_url, key_uri)
            proxied = f'/hls/{slug}/segment?url={absolute}'
            out_lines.append(f'{prefix}URI="{proxied}"{suffix}')
            continue

        # nested playlist
        if line.endswith(".m3u8") and not line.startswith("#"):
            absolute = urljoin(base_url, line)
            proxied = f"/hls/{slug}/segment?url={absolute}"
            out_lines.append(proxied)
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

# ---------------------------------
# app/__init__.py
# ---------------------------------
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

# ---------------------------------
# app/templates/channel_detail.html
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

Write-Host ""
Write-Host "Installing requirements..." -ForegroundColor Yellow
pip install -r .\requirements.txt

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Now run:" -ForegroundColor Green
Write-Host "  py .\run.py"
Write-Host ""
Write-Host "Then test:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:5000/hls/bbc-america/index.m3u8"
Write-Host "  http://127.0.0.1:5000/channel/bbc-america"