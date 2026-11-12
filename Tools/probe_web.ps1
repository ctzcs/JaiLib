param([string]$Jai = 'jai', [string]$Node = '', [switch]$CheckGraphics)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1')
$root = (Resolve-Path "$PSScriptRoot/..").Path
if (!$Node) {
    $bundled = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
    $Node = if (Test-Path -LiteralPath $bundled) { $bundled } else { 'node' }
}
Push-Location $root
try {
    New-Item -ItemType Directory -Path '.test_tmp/web_probe' -Force | Out-Null
    & $Jai -no_cwd 'Tests/web_probe/build.jai'
    if ($LASTEXITCODE -ne 0) { throw 'Jai WASM64 compilation failed' }
    & $Node 'Tests/web_probe/run.cjs' '.test_tmp/web_probe/probe.wasm'
    if ($LASTEXITCODE -ne 0) { throw 'WASM64 runtime failed; this Node version may lack memory64/table64 support' }
    if ($CheckGraphics) {
        & $Jai -no_cwd 'Tests/web_probe/build.jai' - gfx
        if ($LASTEXITCODE -ne 0) { throw 'CPU probe passed, but gfx/jfoster requires a Web platform backend' }
    }
} finally { Pop-Location }

