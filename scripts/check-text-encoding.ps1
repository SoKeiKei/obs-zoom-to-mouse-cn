param(
    [string[]]$Paths = @('obs-zoom-to-mouse-cn.lua', 'AGENTS.md'),
    [string[]]$ExpectContains = @()
)

$ErrorActionPreference = 'Stop'
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$failed = $false

foreach ($path in $Paths) {
    if (-not (Test-Path $path)) {
        Write-Host "[MISS] $path" -ForegroundColor Yellow
        $failed = $true
        continue
    }

    $fullPath = (Resolve-Path $path)
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Host "[FAIL] $path -> UTF-8 BOM detected" -ForegroundColor Red
        $failed = $true
        continue
    }

    try {
        $text = $utf8Strict.GetString($bytes)
    }
    catch {
        Write-Host "[FAIL] $path -> invalid UTF-8 without BOM" -ForegroundColor Red
        $failed = $true
        continue
    }

    if ($text.Contains([char]0xFFFD)) {
        Write-Host "[FAIL] $path -> replacement character detected" -ForegroundColor Red
        $failed = $true
        continue
    }

    if ($ExpectContains.Count -gt 0) {
        $missing = @($ExpectContains | Where-Object { -not $text.Contains($_) })
        if ($missing.Count -gt 0) {
            Write-Host "[FAIL] $path -> missing expected text: $($missing -join '; ')" -ForegroundColor Red
            $failed = $true
            continue
        }
    }

    Write-Host "[OK]   $path" -ForegroundColor Green
}

if ($failed) {
    exit 1
}

exit 0