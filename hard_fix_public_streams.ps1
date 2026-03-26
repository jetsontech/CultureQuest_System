$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$viewsPath = ".\app\views.py"

if (!(Test-Path $viewsPath)) {
    throw "Cannot find $viewsPath"
}

$content = Get-Content $viewsPath -Raw

Write-Host "Scanning app\views.py for duplicate public.streams routes..." -ForegroundColor Cyan

# Remove every existing /streams route block, no matter how many there are
$pattern = '(?ms)@public_bp\.route\("/streams/<path:filename>"\)\s*def\s+streams\(filename\):\s*return\s+send_from_directory\([^\r\n]+(?:\r?\n[ \t]+[^\r\n]+)*'
$matches = [regex]::Matches($content, $pattern)

Write-Host ("Found " + $matches.Count + " public.streams route block(s).") -ForegroundColor Yellow

$content = [regex]::Replace($content, $pattern, '')

# Normalize extra blank lines
$content = [regex]::Replace($content, '(\r?\n){3,}', "`r`n`r`n")

# Append exactly one correct /streams route
$singleRoute = @'

@public_bp.route("/streams/<path:filename>")
def streams(filename):
    return send_from_directory(os.path.join(os.getcwd(), "streams"), filename)
'@

$content = $content.TrimEnd() + "`r`n" + $singleRoute + "`r`n"

Set-Content $viewsPath -Value $content -Encoding utf8

Write-Host "Rewrote app\views.py so it contains exactly one public.streams route." -ForegroundColor Green
Write-Host ""
Write-Host "Verifying remaining occurrences..." -ForegroundColor Cyan

$verify = Select-String -Path $viewsPath -Pattern '@public_bp\.route\("/streams/<path:filename>"\)|def streams\(filename\):'
$verify | ForEach-Object { $_.Line }

Write-Host ""
Write-Host "Now start the app with:" -ForegroundColor Yellow
Write-Host "py .\run.py"