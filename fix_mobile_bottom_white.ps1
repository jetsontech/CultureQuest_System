$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Fix Mobile Bottom White Bar" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# Fix base.html
@'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#05070a">
  <title>{% block title %}CultureQuest{% endblock %}</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
  <header class="topbar">
    <div class="wrap topbar-inner">
      <a class="brand-wrap" href="{{ url_for('public.home') }}">
        <div class="brand-mark">CQ</div>
        <div>
          <div class="brand">CultureQuest</div>
          <div class="brand-sub">Live TV Platform</div>
        </div>
      </a>

      <nav class="nav">
        <a href="{{ url_for('public.home') }}">Home</a>
        <a href="{{ url_for('public.beacon') }}">Live TV</a>
        <a href="{{ url_for('public.epg') }}">Guide</a>
        <a href="{{ url_for('admin.channels') }}">Channels</a>
      </nav>
    </div>
  </header>

  <main class="main-area">
    <div class="wrap">
      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          <div class="flash-stack">
            {% for category, message in messages %}
              <div class="flash {{ category }}">{{ message }}</div>
            {% endfor %}
          </div>
        {% endif %}
      {% endwith %}

      {% block content %}{% endblock %}
    </div>
  </main>
</body>
</html>
'@ | Set-Content .\app\templates\base.html -Encoding utf8

# Patch style.css
$cssPath = ".\app\static\style.css"
if (Test-Path $cssPath) {
    $css = Get-Content $cssPath -Raw

    if ($css -notmatch 'html,\s*body') {
        $css += @'

html, body {
  min-height: 100%;
  background: #05070a;
}

html {
  background-color: #05070a;
}

body {
  background-color: #05070a;
  min-height: 100vh;
  min-height: 100dvh;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

.main-area {
  padding-bottom: calc(70px + env(safe-area-inset-bottom, 0px));
}
'@
    } else {
        $css += @'

body {
  min-height: 100vh;
  min-height: 100dvh;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

.main-area {
  padding-bottom: calc(70px + env(safe-area-inset-bottom, 0px));
}
'@
    }

    Set-Content $cssPath -Value $css -Encoding utf8
    Write-Host "Patched app\static\style.css" -ForegroundColor Green
} else {
    Write-Host "style.css not found" -ForegroundColor Red
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Now restart:" -ForegroundColor Yellow
Write-Host "  py .\run.py"