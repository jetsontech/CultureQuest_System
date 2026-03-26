param (
    [string]$DemoStreamUrl = ""
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "      CultureQuest Platform Start     " -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# Activate Venv
if (Test-Path ".\.venv\Scripts\Activate.ps1") { . .\.venv\Scripts\Activate.ps1 }

# Clean app/views.py (Resolve the Duplicate Route AssertionError)
$viewsPath = ".\app\views.py"
$content = Get-Content $viewsPath -Raw
# Strip all versions of the streams route
$content = $content -replace "(?s)@public_bp\.route\('/streams/<path:filename>'\).*?return send_from_directory.*?filename\)", ""
# Add exactly ONE clean copy
$route = "`n`n@public_bp.route('/streams/<path:filename>')`ndef streams(filename):`n    import os`n    from flask import send_from_directory`n    return send_from_directory(os.path.join(os.getcwd(), 'streams'), filename)"
$content += $route
Set-Content $viewsPath -Value $content -Encoding utf8
Write-Host "Views.py sanitized." -ForegroundColor Green

# Initialize Database
python .\init_db.py

# Launch Server
Write-Host "Launching CultureQuest..." -ForegroundColor Green
Start-Process "http://127.0.0.1:5000"
python .\run.py
