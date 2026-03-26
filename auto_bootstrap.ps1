param(
    [string]$PlaylistUrl = "https://iptv-org.github.io/iptv/index.country.m3u",
    [string]$PlaylistPath = ".\iptv.m3u",
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

function Ensure-Dir {
    param([string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

Ensure-Dir ".\app\templates"
Ensure-Dir ".\scripts"
Ensure-Dir ".\instance"

if (!(Test-Path ".\import_m3u.ps1")) {
    throw "Missing .\import_m3u.ps1"
}

if (!(Test-Path ".\scripts\generate_schedule.py")) {
    throw "Missing .\scripts\generate_schedule.py"
}

if (!(Test-Path ".\app\templates\epg.html")) {
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
</div>
{% endif %}
{% endblock %}
'@ | Set-Content ".\app\templates\epg.html" -Encoding utf8
}

Ensure-Utf8 @(
    ".\app\views.py",
    ".\app\templates\epg.html",
    ".\import_m3u.ps1",
    ".\scripts\generate_schedule.py"
)

Write-Host "Initializing database..." -ForegroundColor Yellow
Run-Python ".\init_db.py"

Write-Host "Downloading playlist..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $PlaylistUrl -OutFile $PlaylistPath
Write-Host "Saved to $PlaylistPath" -ForegroundColor Green

Write-Host "Importing channels..." -ForegroundColor Yellow
& .\import_m3u.ps1 -M3UFile $PlaylistPath -Limit $Limit -StartNumber $StartNumber

Write-Host "Generating schedules..." -ForegroundColor Yellow
Run-Python ".\scripts\generate_schedule.py"

Start-Process "http://127.0.0.1:5000"
Start-Process "http://127.0.0.1:5000/beacon"
Start-Process "http://127.0.0.1:5000/epg"
Start-Process "http://127.0.0.1:5000/admin/login"

Write-Host "Starting CultureQuest..." -ForegroundColor Green
Run-Python ".\run.py"