<#
  Builds AIUsageWidget and packages it into dist/:
    AIUsageWidget.exe            raw release exe
    AIUsageWidget-portable.zip   AIUsageWidget.exe + portable.txt + scripts/
    AIUsageWidget-Setup.exe      installer (needs Inno Setup 6; skipped with a warning if missing)
  Usage:  .\build.ps1 [-SkipSetup]
#>
param([switch]$SkipSetup)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$version = (Select-String -Path Cargo.toml -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value
Write-Host "Building AIUsageWidget $version"

cargo build --release
if ($LASTEXITCODE) { throw 'cargo build failed' }

$dist = Join-Path $PSScriptRoot 'dist'
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $dist | Out-Null
$tgt = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $PSScriptRoot 'target' }
Copy-Item (Join-Path $tgt 'release\aiusagewidget.exe') (Join-Path $dist 'AIUsageWidget.exe')

function Copy-RuntimeFiles($dest) {
    $scripts = Join-Path $dest 'scripts'
    New-Item -ItemType Directory $scripts -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'scripts\fetch.ps1') $scripts -Force
}

# Portable zip
$stage = Join-Path $dist '_portable'
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $dist 'AIUsageWidget.exe') $stage
Copy-RuntimeFiles $stage
Set-Content -Path (Join-Path $stage 'portable.txt') -Value 'Delete this file to store settings in %APPDATA%\AIUsageWidget instead.'
Compress-Archive -Path "$stage\*" -DestinationPath (Join-Path $dist 'AIUsageWidget-portable.zip')
Remove-Item $stage -Recurse -Force

# Also stage scripts next to dist exe for local testing / installer source
Copy-RuntimeFiles $dist

# Installer
if (-not $SkipSetup) {
    $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($iscc) {
        & $iscc "/DAppVersion=$version" installer\AIUsageWidget.iss
        if ($LASTEXITCODE) { throw 'Inno Setup failed' }
    } else {
        Write-Warning 'Inno Setup 6 not found - skipped AIUsageWidget-Setup.exe (winget install JRSoftware.InnoSetup)'
    }
}

$sums = Get-ChildItem $dist -File | Where-Object { $_.Name -in 'AIUsageWidget-Setup.exe','AIUsageWidget-portable.zip' } |
    ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
Set-Content -Path (Join-Path $dist 'SHA256SUMS.txt') -Value $sums
$sums | ForEach-Object { Write-Host $_ }

Get-ChildItem $dist | Format-Table Name, @{n='MB';e={[math]::Round($_.Length/1MB,2)}}
