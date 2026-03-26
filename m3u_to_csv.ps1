param(
    [Parameter(Mandatory=$true)]
    [string]$M3UFile,

    [string]$OutCsv = ".\channels_from_m3u.csv",

    [int]$Limit = 200
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $M3UFile)) {
    throw "M3U file not found: $M3UFile"
}

$lines = Get-Content $M3UFile
$rows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()

    if ($line -like "#EXTINF:*") {
        $name = ""
        $category = "Live"

        if ($line -match 'group-title="([^"]+)"') {
            $category = $matches[1]
        }

        if ($line -match ',(.*)$') {
            $name = $matches[1].Trim()
        }

        $urlIndex = $i + 1
        if ($urlIndex -lt $lines.Count) {
            $url = $lines[$urlIndex].Trim()

            if ($url -match '^https?://') {
                $rows.Add([pscustomobject]@{
                    name = $name
                    category = $category
                    stream_url = $url
                    is_premium = "false"
                    is_active = "true"
                })
            }
        }
    }

    if ($rows.Count -ge $Limit) {
        break
    }
}

$rows | Export-Csv -NoTypeInformation -Encoding utf8 $OutCsv
Write-Host "Created CSV: $OutCsv"
Write-Host "Rows: $($rows.Count)"