param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [int]$StartNumber = 300
)

$ErrorActionPreference = "Stop"

function Normalize-Name {
    param([string]$Name)
    $n = $Name.ToLower()
    $n = $n -replace '[^a-z0-9]+','-'
    $n = $n.Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = "channel" }
    return $n
}

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

if (!(Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}

$dbPath = Join-Path $PSScriptRoot "instance\culturequest.db"
if (!(Test-Path $dbPath)) {
    throw "Database not found: $dbPath"
}

$ext = [System.IO.Path]::GetExtension($InputFile).ToLowerInvariant()
if ($ext -notin @(".csv",".json")) {
    throw "Unsupported input format. Use .csv or .json"
}

$tmpPy = Join-Path $PSScriptRoot "_cq_import_channels.py"

$py = @"
import csv
import json
import sqlite3
import sys
from pathlib import Path

db_path = Path(r"$dbPath")
input_file = Path(r"$InputFile")
start_number = int($StartNumber)

def normalize_name(name: str) -> str:
    import re
    n = name.strip().lower()
    n = re.sub(r'[^a-z0-9]+', '-', n)
    n = n.strip('-')
    return n or "channel"

def as_bool(v, default=False):
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "y", "on")

def load_rows(path: Path):
    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and "channels" in data:
            data = data["channels"]
        if not isinstance(data, list):
            raise ValueError("JSON must be a list or an object with a 'channels' list.")
        return data

    rows = []
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(dict(row))
    return rows

rows = load_rows(input_file)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

existing_numbers = {row["number"] for row in cur.execute("SELECT number FROM channels").fetchall()}
existing_slugs = {row["slug"] for row in cur.execute("SELECT slug FROM channels").fetchall()}

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

    if not name or not stream_url:
        skipped += 1
        continue

    slug = str(raw.get("slug", "")).strip() or normalize_name(name)
    base_slug = slug
    i = 2
    while slug in existing_slugs and not cur.execute("SELECT 1 FROM channels WHERE slug = ?", (slug,)).fetchone():
        slug = f"{base_slug}-{i}"
        i += 1

    number_raw = str(raw.get("number", "")).strip()
    if number_raw:
        try:
            number = int(number_raw)
            if number in existing_numbers:
                found = cur.execute("SELECT slug FROM channels WHERE number = ?", (number,)).fetchone()
                if found and found["slug"] != slug:
                    number = next_number()
        except:
            number = next_number()
    else:
        number = next_number()

    category = str(raw.get("category", "")).strip() or "Live"
    description = str(raw.get("description", "")).strip() or f"{name} live channel"
    is_premium = 1 if as_bool(raw.get("is_premium"), False) else 0
    is_active = 1 if as_bool(raw.get("is_active"), True) else 0

    existing = cur.execute("SELECT id FROM channels WHERE slug = ?", (slug,)).fetchone()

    if existing:
        cur.execute(
            '''
            UPDATE channels
            SET number = ?, name = ?, description = ?, category = ?, stream_url = ?, is_premium = ?, is_active = ?
            WHERE slug = ?
            ''',
            (number, name, description, category, stream_url, is_premium, is_active, slug)
        )
        updated += 1
    else:
        cur.execute(
            '''
            INSERT INTO channels
            (number, name, slug, description, category, stream_url, is_premium, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ''',
            (number, name, slug, description, category, stream_url, is_premium, is_active)
        )
        existing_slugs.add(slug)
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
Write-Host "Open Beacon: http://127.0.0.1:5000/beacon" -ForegroundColor Green
Write-Host "Manage Channels: http://127.0.0.1:5000/admin/channels" -ForegroundColor Green