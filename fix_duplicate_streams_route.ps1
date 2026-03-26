$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$path = ".\app\views.py"
$content = Get-Content $path -Raw

$pattern = '(?s)@public_bp\.route\("/streams/<path:filename>"\)\s*def streams\(filename\):\s*return send_from_directory\(os\.path\.join\(os\.getcwd\(\), "streams"\), filename\)\s*'
$matches = [regex]::Matches($content, $pattern)

if ($matches.Count -gt 1) {
    $first = $matches[0].Value
    $content = [regex]::Replace($content, $pattern, '', 0)
    $content += "`r`n`r`n" + $first + "`r`n"
    Set-Content $path -Value $content -Encoding utf8
    Write-Host "Removed duplicate public.streams routes." -ForegroundColor Green
} else {
    Write-Host "No duplicate public.streams route found by script pattern." -ForegroundColor Yellow
}

Write-Host "Now run: py .\run.py" -ForegroundColor Cyan