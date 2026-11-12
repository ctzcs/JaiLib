param(
    [string]$Source = "$PSScriptRoot/../Tests/fluid2d/shaders/hlsl",
    [string]$Output = "$PSScriptRoot/../Tests/fluid2d/shaders/compiled"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1")
Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1")
$manifest = Get-Content -LiteralPath (Join-Path $Output 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.version -ne 1 -or $manifest.stage -ne 'fragment' -or $manifest.entryPoint -ne 'fragment_main') { throw 'Unsupported shader manifest' }
$expected = @{}
foreach ($file in Get-ChildItem -LiteralPath $Source -Filter '*.hlsl') {
    if ([IO.File]::ReadAllText($file.FullName) -match '(?m)^\s*#\s*include\b') { throw "Unsupported shader include: $($file.Name)" }
    foreach ($ext in @('dxil', 'spv')) { $expected["$($file.BaseName).fragment.$ext"] = $file.Name }
}
if ($expected.Count -eq 0 -or $manifest.records.Count -ne $expected.Count) { throw 'Shader manifest/source set differs; rebuild shaders' }
$seen = @{}
foreach ($record in $manifest.records) {
    if (!$expected.ContainsKey($record.blob) -or $expected[$record.blob] -ne $record.source -or $seen.ContainsKey($record.blob)) { throw 'Invalid or duplicate shader record' }
    $seen[$record.blob] = $true
    if ((Get-FileHash -LiteralPath (Join-Path $Source $record.source) -Algorithm SHA256).Hash -ne $record.sourceSha256) { throw "Stale shader source: $($record.source); rebuild shaders" }
    if ((Get-FileHash -LiteralPath (Join-Path $Output $record.blob) -Algorithm SHA256).Hash -ne $record.blobSha256) { throw "Corrupt shader blob: $($record.blob); rebuild shaders" }
}
Write-Host "[shaders] $($expected.Count) verified blobs"

