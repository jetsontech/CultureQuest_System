param(
    [Parameter(Mandatory=$true)]
    [string]$M3UFile,

    [string]$OutCsv = ".\channels_from_m3u.csv",

    [int]$Limit = 200,

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

if (!(Test-Path $M3UFile)) {
    throw "M3U file not found: $M3UFile"
}

$dbPath = Join-Path $PSScriptRoot "instance\culturequest.db"
if (!(Test-Path $dbPath)) {
    throw "Database not found: $dbPath"
}

$lines = Get-Content $M3UFile
$rows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()

    if ($line -like "#EXTINF:*") {
        $name = ""
        $category = "Live"

        if ($line -match 'group-title="([^"]+)"') {
            $category = $matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($category)) {
                $category = "Live"
            }
        }

        if ($line -match ',(.*)$') {
            $name = $matches[1].Trim()
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "Channel-$($rows.Count + 1)"
        }

        $urlIndex = $i + 1
        if ($urlIndex -lt $lines.Count) {
            $url = $lines[$urlIndex].Trim()

            if ($url -match '^https?://') {
                $rows.Add([pscustomobject]@{
                    name        = $name
                    category    = $category
                    stream_url  = $url
                    is_premium  = "false"
                    is_active   = "true"
                })
            }
        }
    }

    if ($rows.Count -ge $Limit) {
        break
    }
}

if ($rows.Count -eq 0) {
    throw "No stream entries were parsed from the M3U."
}

$rows | Export-Csv -NoTypeInformation -Encoding utf8 $OutCsv
Write-Host "CSV created: $OutCsv"
Write-Host "Rows parsed: $($rows.Count)"

$tmpPy = Join-Path $PSScriptRoot "_cq_import_m3u_tmp.py"

$py = @"
import csv
import sqlite3
from pathlib import Path
import re

db_path = Path(r"$dbPath")
csv_path = Path(r"$OutCsv")
start_number = int($StartNumber)

def slugify(value: str) -> str:
    s = (value or "").strip().lower()
    s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
    return s or "channel"

def as_bool(v, default=False):
    if v is None:
        return default
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "y", "on")

with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

existing_numbers = {row["number"] for row in cur.execute("SELECT number FROM channels").fetchall()}

def next_number():
    global start_number
    while start_number in existing_numbers:
        start_number += 1
    n = start_number
    existing_numbers.add(n)
    start_number += 1
    return n

created = 0
updated = 0
skipped = 0

for raw in rows:
    name = str(raw.get("name", "")).strip()
    stream_url = str(raw.get("stream_url", "")).strip()
    category = str(raw.get("category", "")).strip() or "Live"

    if not name or not stream_url:
        skipped += 1
        continue

    slug = slugify(name)
    existing = cur.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()

    if existing:
        cur.execute(
            '''
            UPDATE channels
            SET name = ?, category = ?, description = ?, stream_url = ?, is_premium = ?, is_active = ?
            WHERE slug = ?
            ''',
            (
                name,
                category,
                f"{name} imported from M3U",
                stream_url,
                1 if as_bool(raw.get("is_premium"), False) else 0,
                1 if as_bool(raw.get("is_active"), True) else 0,
                slug
            )
        )
        updated += 1
    else:
        number = next_number()
        cur.execute(
            '''
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ''',
            (
                number,
                name,
                slug,
                f"{name} imported from M3U",
                category,
                stream_url,
                1 if as_bool(raw.get("is_premium"), False) else 0,
                1 if as_bool(raw.get("is_active"), True) else 0
            )
        )
        created += 1

conn.commit()
conn.close()

print(f"Created: {created}")
print(f"Updated: {updated}")
print(f"Skipped: {skipped}")
"@

Set-Content $tmpPy -Value $py -Encoding utf8
Run-Python $tmpPy
$exit = $LASTEXITCODE
Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

if ($exit -ne 0) {
    throw "Import failed."
}

Write-Host ""
Write-Host "Import complete." -ForegroundColor Green