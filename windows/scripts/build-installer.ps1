$ErrorActionPreference = "Stop"

$project = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script = Join-Path $project "build\installer.nsi"
$packagedRoot = (Resolve-Path -LiteralPath (Join-Path $project 'release\win-unpacked')).Path
$uninstallLines = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $packagedRoot -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($packagedRoot.Length + 1)
    if ($relative.Contains('$') -or $relative.Contains('"')) { throw 'Unexpected installer filename.' }
    $uninstallLines.Add('Delete "$INSTDIR\' + $relative + '"')
}
Get-ChildItem -LiteralPath $packagedRoot -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    $relative = $_.FullName.Substring($packagedRoot.Length + 1)
    if ($relative.Contains('$') -or $relative.Contains('"')) { throw 'Unexpected installer directory.' }
    $uninstallLines.Add('RMDir "$INSTDIR\' + $relative + '"')
}
$uninstallLines | Set-Content -LiteralPath (Join-Path $project 'build\uninstall-files.nsh') -Encoding utf8
$cache = Join-Path $env:LOCALAPPDATA "electron-builder\Cache\nsis"
$compiler = Get-ChildItem -LiteralPath $cache -Recurse -Filter "makensis.exe" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq "Bin" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if (-not $compiler) {
    $command = Get-Command "makensis.exe" -ErrorAction SilentlyContinue
    if ($command) {
        $compilerPath = $command.Source
    } else {
        throw "NSIS compiler not found. Install NSIS or populate Electron Builder's NSIS cache."
    }
} else {
    $compilerPath = $compiler.FullName
}

Push-Location $project
try {
    & $compilerPath /WX /V2 $script
    if ($LASTEXITCODE) {
        throw "NSIS compiler exited with $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
