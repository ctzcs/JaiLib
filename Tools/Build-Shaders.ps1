param(
    [string]$Source = "$PSScriptRoot/../Tests/fluid2d/shaders/hlsl",
    [string]$Output = "$PSScriptRoot/../Tests/fluid2d/shaders/compiled",
    [string]$Compiler = "$PSScriptRoot/../../DragonLib/Tools/ShaderCross/shadercross.exe"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1")
Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1")
if (!(Test-Path -LiteralPath $Compiler)) { throw "Missing shadercross: $Compiler" }
$sources = @(Get-ChildItem -LiteralPath $Source -Filter '*.hlsl' | Sort-Object Name)
if ($sources.Count -eq 0) { throw "No HLSL sources in $Source" }
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Output = (Resolve-Path -LiteralPath $Output).Path
$temporary = Join-Path $Output ('.compile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $records = @()
    foreach ($sourceFile in $sources) {
        if ([IO.File]::ReadAllText($sourceFile.FullName) -match '(?m)^\s*#\s*include\b') { throw "Shader includes require dependency hashing support: $($sourceFile.Name)" }
        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
        foreach ($format in @(@{ext='dxil';target='DXIL'}, @{ext='spv';target='SPIRV'})) {
            $name = "$($sourceFile.BaseName).fragment.$($format.ext)"
            $blob = Join-Path $temporary $name
            & $Compiler $sourceFile.FullName -s HLSL -d $format.target -t fragment -e fragment_main -o $blob
            if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $blob)) { throw "Shader compilation failed: $name" }
            $records += [ordered]@{source=$sourceFile.Name; sourceSha256=$sourceHash; blob=$name; blobSha256=(Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash}
        }
        if ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ne $sourceHash) { throw "Source changed during compilation: $($sourceFile.Name)" }
    }
    # Manifest last: incomplete output never passes verification.
    foreach ($record in $records) { Copy-Item -LiteralPath (Join-Path $temporary $record.blob) -Destination $Output -Force }
    [ordered]@{version=1;stage='fragment';entryPoint='fragment_main';records=$records} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Output 'manifest.json') -Encoding utf8
    & "$PSScriptRoot/Verify-Shaders.ps1" -Source $Source -Output $Output
} finally {
    # Explicitly created child of Output, never a caller-provided deletion target.
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($temporary)) -ne $Output) { throw 'Temporary shader path escaped output directory' }
    Remove-Item -LiteralPath $temporary -Recurse -Force
}

