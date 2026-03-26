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

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   CultureQuest Absolute Master v1    " -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

Ensure-LineInFile ".\requirements.txt" "requests"

# ---------------------------------------------------
# 1) Liquid Glass homepage template
# ---------------------------------------------------
Write-Host "Applying 2026 Liquid Glass UI..." -ForegroundColor Yellow

$homeHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest{% endblock %}

{% block content %}
<section class="hero-shell glass-blur">
  <div class="hero-panel">
    <div class="hero-copy">
      <div class="eyebrow">CultureQuest Premier</div>
      <h1>The Peak of Streaming</h1>
      <p>Futuristic live channels, original stories, and premium culture in one immersive experience.</p>
      <div class="actions top-gap-sm">
        <a class="btn btn-primary" href="{{ url_for('public.beacon') }}">Watch Live Now</a>
        <a class="btn" href="{{ url_for('public.premium') }}">Explore Plans</a>
      </div>
    </div>

    <div class="hero-side-grid">
      {% for channel in featured %}
      <a class="feature-tile" href="{{ url_for('public.channel_detail', slug=channel['slug']) }}">
        <strong>{{ channel['name'] }}</strong>
        <span>CH {{ channel['number'] }} · {{ channel['category'] or 'Featured' }}</span>
      </a>
      {% endfor %}
    </div>
  </div>
</section>

{% set genres = ['Featured', 'Movies', 'Comedy', 'Drama', 'Crime', 'Reality', 'Documentaries', 'News', 'Sports', 'Kids', 'Anime', 'Entertainment', 'Food', 'Travel', 'Music', 'Latino', 'Local', 'Gaming / Games'] %}

{% for cat in genres %}
<section class="top-gap rail-section">
  <div class="section-head">
    <h2>{{ cat }}</h2>
    <a href="{{ url_for('public.category_page', category_name=cat) }}" class="pill">View All</a>
  </div>

  <div class="scrolling-rail">
    {% for row in category_rows if row['name'] == cat %}
      {% for channel in row['channels'] %}
        <a href="{{ url_for('public.channel_detail', slug=channel['slug']) }}" class="rail-card glass-card">
          <div class="rail-poster alt-{{ loop.index % 4 }}">
            <div class="live-badge pulse">LIVE</div>
          </div>
          <div class="rail-meta">
            <h3>{{ channel['name'] }}</h3>
            <p>{{ channel['description'] or 'Now Streaming' }}</p>
          </div>
        </a>
      {% endfor %}
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\home.html" $homeHtml

# ---------------------------------------------------
# 2) Stronger beacon page
# ---------------------------------------------------
$beaconHtml = @'
{% extends "base.html" %}
{% block title %}CultureQuest · Live TV{% endblock %}

{% block content %}
<div class="section-head">
  <div>
    <h1>Live TV</h1>
    <p class="muted">Modern category rails powered by real imported channels.</p>
  </div>
  <span class="pill">{{ channels|length }} Channels</span>
</div>

{% for row in category_rows %}
<section class="top-gap rail-section">
  <div class="section-head">
    <h2>{{ row['name'] }}</h2>
    <a href="{{ url_for('public.category_page', category_name=row['name']) }}" class="pill">View All</a>
  </div>

  <div class="scrolling-rail">
    {% for channel in row['channels'] %}
      <a href="{{ url_for('public.channel_detail', slug=channel['slug']) }}" class="rail-card glass-card">
        <div class="rail-poster alt-{{ loop.index % 4 }}">
          <div class="live-badge pulse">LIVE</div>
        </div>
        <div class="rail-meta">
          <h3>{{ channel['name'] }}</h3>
          <p>{{ channel['description'] or channel['category'] or 'Now Streaming' }}</p>
        </div>
      </a>
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endblock %}
'@
Write-Utf8File ".\app\templates\beacon.html" $beaconHtml

# ---------------------------------------------------
# 3) Add glass / rail CSS
# ---------------------------------------------------
if (Test-Path ".\app\static\style.css") {
    $css = Get-Content ".\app\static\style.css" -Raw
    if ($css -notmatch "scrolling-rail") {
        Add-Content ".\app\static\style.css" @'

.glass-blur{
  backdrop-filter: blur(22px);
  -webkit-backdrop-filter: blur(22px);
}
.glass-card{
  background: linear-gradient(180deg, rgba(255,255,255,.12), rgba(255,255,255,.05));
  border: 1px solid rgba(255,255,255,.12);
  box-shadow: 0 18px 60px rgba(0,0,0,.28);
}
.scrolling-rail{
  display:flex;
  gap:16px;
  overflow-x:auto;
  padding-bottom:8px;
  scroll-behavior:smooth;
}
.scrolling-rail::-webkit-scrollbar{
  height:10px;
}
.scrolling-rail::-webkit-scrollbar-thumb{
  background:rgba(255,255,255,.12);
  border-radius:999px;
}
.rail-card{
  min-width:260px;
  max-width:260px;
  border-radius:24px;
  overflow:hidden;
  color:inherit;
  text-decoration:none;
}
.rail-poster{
  height:150px;
  position:relative;
  background:linear-gradient(135deg,#263246,#101722);
}
.rail-poster.alt-0{background:linear-gradient(135deg,#2f3a54,#111724)}
.rail-poster.alt-1{background:linear-gradient(135deg,#4e2c3f,#131722)}
.rail-poster.alt-2{background:linear-gradient(135deg,#1f4a50,#0f161e)}
.rail-poster.alt-3{background:linear-gradient(135deg,#51421c,#14181d)}
.rail-meta{
  padding:14px 16px 18px;
}
.rail-meta h3{
  margin:0 0 8px 0;
  font-size:1rem;
}
.rail-meta p{
  margin:0;
  color:#aeb7ca;
  font-size:.92rem;
}
.live-badge{
  position:absolute;
  top:12px;
  left:12px;
  padding:6px 10px;
  border-radius:999px;
  background:#ff3040;
  color:#fff;
  font-size:.72rem;
  font-weight:700;
  letter-spacing:.04em;
}
.pulse{
  box-shadow:0 0 0 rgba(255,48,64,.5);
  animation:pulseGlow 1.8s infinite;
}
@keyframes pulseGlow{
  0%{box-shadow:0 0 0 0 rgba(255,48,64,.45)}
  70%{box-shadow:0 0 0 12px rgba(255,48,64,0)}
  100%{box-shadow:0 0 0 0 rgba(255,48,64,0)}
}
'@
        Write-Host "Updated app\static\style.css" -ForegroundColor Green
    }
}

# ---------------------------------------------------
# 4) Content ingestion packs
# ---------------------------------------------------
$sources = @(
    @{ name="Cinematic Action"; url="https://aymrgknetzpucldhpkwm.supabase.co/storage/v1/object/public/tmdb/action-movies.m3u" },
    @{ name="Global News Hub"; url="https://iptv-org.github.io/iptv/categories/news.m3u" },
    @{ name="World Sports"; url="https://iptv-org.github.io/iptv/categories/sport.m3u" },
    @{ name="Kids Zone"; url="https://iptv-org.github.io/iptv/categories/kids.m3u" }
)

foreach ($s in $sources) {
    Write-Host ("Connecting to Source: " + $s.name + "...") -ForegroundColor Cyan
    $tmp = ".\temp.m3u8"
    try {
        Invoke-WebRequest -Uri $s.url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        if (Test-Path ".\import_m3u.ps1") {
            .\import_m3u.ps1 -M3UFile $tmp -Limit 50 -StartNumber (Get-Random -Minimum 1000 -Maximum 9999)
        } else {
            Write-Host "import_m3u.ps1 not found. Skipping import." -ForegroundColor Red
        }
    }
    catch {
        Write-Host ("Skipping " + $s.name + " - Temporarily Unavailable") -ForegroundColor Red
    }
    finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force
        }
    }
}

# ---------------------------------------------------
# 5) Optional schedule generation
# ---------------------------------------------------
Write-Host "Updating 72-Hour Intelligent EPG..." -ForegroundColor Yellow
if (Test-Path ".\scripts\generate_schedule.py") {
    python .\scripts\generate_schedule.py
} else {
    Write-Host "generate_schedule.py not found. Skipping EPG generation." -ForegroundColor Yellow
}

Write-Host "DEPLOYMENT COMPLETE. CultureQuest is ready." -ForegroundColor Green
Write-Host ""
Write-Host "Start with:" -ForegroundColor Yellow
Write-Host "  .\start.ps1"