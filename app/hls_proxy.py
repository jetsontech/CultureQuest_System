import requests
from urllib.parse import urljoin
from flask import Blueprint, Response, abort, request
from .db import get_db

hls_bp = Blueprint("hls", __name__, url_prefix="/hls")

_SESSION = None

def get_session():
    global _SESSION
    if _SESSION is None:
        import requests
        _SESSION = requests.Session()
        _SESSION.headers.update({
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            ),
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Connection": "keep-alive",
        })
    return _SESSION


def get_channel_by_slug(slug):
    db = get_db()
    return db.execute(
        "SELECT * FROM channels WHERE slug = ? AND is_active = 1",
        (slug,)
    ).fetchone()


def fetch_url(url):
    try:
        resp = get_session().get(url, timeout=20, allow_redirects=True, stream=False)
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
