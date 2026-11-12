$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1')
$fixture = Join-Path "$PSScriptRoot/../.test_tmp" ('shader-check-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'hlsl'
$output = Join-Path $fixture 'compiled'
New-Item -ItemType Directory -Path $source,$output -Force | Out-Null
Copy-Item "$PSScriptRoot/../Tests/gutwall/shaders/hlsl/*" $source
Copy-Item "$PSScriptRoot/../Tests/gutwall/shaders/compiled/*" $output
& "$PSScriptRoot/Verify-Shaders.ps1" -Source $source -Output $output
function Assert-Rejected([string]$Label) {
    $rejected=$false
    try { & "$PSScriptRoot/Verify-Shaders.ps1" -Source $source -Output $output } catch { $rejected=$true }
    if (!$rejected) { throw "Verifier accepted $Label" }
    Write-Host "[shaders] correctly rejected $Label"
}
$hlsl=Join-Path $source 'gutwall.hlsl'
$original=[IO.File]::ReadAllBytes($hlsl)
[IO.File]::AppendAllText($hlsl,"`n// modified source")
Assert-Rejected 'stale source'
[IO.File]::WriteAllBytes($hlsl,$original)
$blob=Join-Path $output 'gutwall.fragment.dxil'
$originalBlob=[IO.File]::ReadAllBytes($blob)
$bad=[byte[]]$originalBlob.Clone();$bad[0]=$bad[0] -bxor 1
[IO.File]::WriteAllBytes($blob,$bad)
Assert-Rejected 'corrupt blob'
[IO.File]::WriteAllBytes($blob,$originalBlob)
$manifestPath=Join-Path $output 'manifest.json'
$manifest=Get-Content $manifestPath -Raw | ConvertFrom-Json
$manifest.records[1]=$manifest.records[0]
$manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath -Encoding utf8
Assert-Rejected 'duplicate/missing blob record'
Write-Host '[shaders] 4 checks passed'
