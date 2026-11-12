$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$jai = if ($env:JAI) { $env:JAI } else { 'D:\MySpace\RefProject\jai\jai\bin\jai.exe' }
$fosterParent = if ($env:JFOSTER_PARENT) { $env:JFOSTER_PARENT } else { Split-Path $root -Parent }
$demo = Join-Path $root 'bin\game_app_demo.exe'
if (-not (Test-Path -LiteralPath $demo)) { throw 'Run build_game_app_demo.bat first.' }
& $jai -no_cwd -import_dir "$root\Libs\Engine" -import_dir "$root\Tests" -import_dir $fosterParent -output_path "$root\bin" -exe game_app_tests "$root\Tests\game_app_tests.jai"
if ($LASTEXITCODE -ne 0) { throw 'game_app_tests build failed' }

function Invoke-GameTest([string]$exe, [string]$arguments, [string]$inputText, [bool]$closeInput = $true) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = $arguments
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $child = [System.Diagnostics.Process]::Start($info)
    # Windows PowerShell defaults Process.StandardInput to the ANSI code page.
    $inputWriter = [System.IO.StreamWriter]::new($child.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
    $outputTask = $child.StandardOutput.ReadToEndAsync()
    $errorTask = $child.StandardError.ReadToEndAsync()
    try {
        if ($inputText) { $inputWriter.Write($inputText); $inputWriter.Flush() }
        if ($closeInput) { $inputWriter.Close() }
        if (-not $child.WaitForExit(15000)) {
            $child.Kill()
            $child.WaitForExit()
            Write-Host $outputTask.Result
            Write-Host $errorTask.Result
            throw "Timeout: $exe $arguments"
        }
        $stdout = $outputTask.Result
        $stderr = $errorTask.Result
        Write-Host $stdout.TrimEnd()
        if ($stderr) { Write-Host $stderr }
        if ($child.ExitCode -ne 0) { throw "Exit $($child.ExitCode): $exe $arguments" }
    } finally { $child.Dispose() }
}

$tests = Join-Path $root 'bin\game_app_tests.exe'
# Includes CRLF, Unicode, whitespace, case-insensitive names and an EOF line.
$fixture = "probe first`r`nPROBE   第二 个  参数  `r`nhelp`r`nmissing`r`nhistory`r`nQuIt"
foreach ($driver in @('', 'vulkan')) {
    Invoke-GameTest $tests $driver ''
    Invoke-GameTest $tests "--cli-test $driver" $fixture
}
# Keep stdin open and idle: shutdown must cancel the reader and join the thread.
Invoke-GameTest $demo 'auto --cli --no-focus' 'status' $false
Write-Host '[game_app] D3D12/Vulkan lifecycle and CLI passed; open-stdin shutdown passed.'
