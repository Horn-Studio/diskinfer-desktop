#requires -Version 7.0
<#
Supplemental Phase 2 smoke test for the third deliverable binary
(llama-completion.exe), outside the main 7-case matrix.

Checks:
  - --version exits 0 and prints a version string
  - one-shot greedy completion with streaming arena 200 MiB exits 0
  - "llama-disk: streaming weights from disk" arena line present
  - every "N tensors registered" line reports 320 (never 640) and count them
  - generated text after the prompt echo equals the diskrun reference (or is reported)

Writes stdout.log / stderr.log / supplement.txt under -OutDir.
ASCII only.
#>
[CmdletBinding()]
param(
    [string]$Exe = 'F:\diskinfer\build\out\win-x64\llama-completion.exe',
    [string]$Model = 'D:\LMStudioModel\lmstudio-community\Qwen3.5-0.8B-GGUF\Qwen3.5-0.8B-Q6_K.gguf',
    [string]$OutDir = 'F:\diskinfer\test\logs\phase2-supplement',
    [int]$TimeoutSec = 300,
    [int]$PollMs = 200
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$prompt = 'The capital of France is'
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$outFile = Join-Path $OutDir 'stdout.log'
$errFile = Join-Path $OutDir 'stderr.log'
$summaryFile = Join-Path $OutDir 'supplement.txt'

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, [string]$Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Child {
    param([string[]]$ArgList, $EnvMap, [int]$Timeout)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    $psi.WorkingDirectory = Split-Path -Parent $Exe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($a in @($ArgList)) { [void]$psi.ArgumentList.Add([string]$a) }
    foreach ($k in @('LLAMA_DISK_STREAM_MB', 'LLAMA_DISK_ODIRECT', 'LLAMA_DISK_MLOCK', 'LLAMA_DISK_LOG', 'GGML_CPU_DISABLE_FUSION')) {
        if ($psi.Environment.ContainsKey($k)) { [void]$psi.Environment.Remove($k) }
    }
    if ($EnvMap) { foreach ($k in @($EnvMap.Keys)) { $psi.Environment[[string]$k] = [string]$EnvMap[$k] } }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try { $proc.StandardInput.Close() } catch { }
    $timedOut = $false
    while (-not $proc.HasExited) {
        if ($sw.Elapsed.TotalSeconds -ge $Timeout) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { }
            break
        }
        Start-Sleep -Milliseconds $PollMs
    }
    try { [void]$proc.WaitForExit(10000) } catch { }
    $sw.Stop()
    $stdout = ''
    $stderr = ''
    try { if ($outTask.Wait(10000)) { $stdout = [string]$outTask.Result } } catch { }
    try { if ($errTask.Wait(10000)) { $stderr = [string]$errTask.Result } } catch { }
    $exitCode = $null
    try { if ($proc.HasExited) { $exitCode = [int]$proc.ExitCode } } catch { }
    $proc.Dispose()
    return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit = $exitCode; seconds = $sw.Elapsed.TotalSeconds; timed_out = $timedOut }
}

$lines = New-Object System.Collections.ArrayList
function Add-L([string]$Text) { [void]$lines.Add($Text) }

Add-L 'Supplemental llama-completion.exe smoke test'
Add-L ('Exe     : ' + $Exe)
Add-L ('Model   : ' + $Model)
Add-L ('Run at  : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-L ''

# ---- --version
$ver = Invoke-Child -ArgList @('--version') -EnvMap @{} -Timeout 60
$verText = ($ver.stdout + "`n" + $ver.stderr).Trim()
Add-L ('--version: exit=' + $ver.exit + ' seconds=' + [math]::Round($ver.seconds, 3))
Add-L ('  output: ' + (($verText -split "`n") | Select-Object -First 2 | ForEach-Object { $_.Trim() }) -join ' | ')
Add-L ''

# ---- one-shot greedy completion, streaming arena 200 MiB, no conversation wrapper
$envMap = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '200' }
$run = Invoke-Child -ArgList @('-m', $Model, '-p', $prompt, '-n', '8', '-c', '128', '-b', '4', '-ub', '4', '-t', '4', '--temp', '0', '-no-cnv', '--no-display-prompt') -EnvMap $envMap -Timeout $TimeoutSec
Write-Utf8 $outFile $run.stdout
Write-Utf8 $errFile $run.stderr
$all = $run.stdout + "`n" + $run.stderr

$arenaLine = ''
$streamed = $false
foreach ($line in ($all -split "`n")) {
    if ($line -match 'llama-disk: streaming weights from disk') { $arenaLine = $line.Trim(); $streamed = $true }
}
$raiseLines = @()
$registerValues = @()
$loadLines = @()
foreach ($line in ($all -split "`n")) {
    if ($line -match "llama-disk: arena (\d+) MiB cannot hold the largest tensor '([^']*)' \((\d+) MiB\), raised to (\d+) MiB") { $raiseLines += $line.Trim() }
    $mm = [regex]::Match($line, 'llama-disk: (\d+) tensors registered, (\d+) MiB to stream')
    if ($mm.Success) { $registerValues += [int]$mm.Groups[1].Value }
    if ($line -match 'diskrun: model loaded in|load time\s*=') { $loadLines += $line.Trim() }
}
$loadCount = $registerValues.Count
$registerOk = ($registerValues.Count -gt 0 -and (@($registerValues | Where-Object { $_ -ne 320 }).Count -eq 0))

# generated text: strip prompt echo like the main harness
$text = $run.stdout.Replace("`r", '')
if ($text.StartsWith($prompt)) { $text = $text.Substring($prompt.Length) }
$text = $text.TrimEnd()
if ($text.EndsWith($prompt) -and $text.Length -gt $prompt.Length) { $text = $text.Substring(0, $text.Length - $prompt.Length).TrimEnd() }

Add-L ('completion: exit=' + $run.exit + ' seconds=' + [math]::Round($run.seconds, 3) + ' timed_out=' + $run.timed_out)
Add-L ('  streaming arena line : ' + $(if ($streamed) { 'PRESENT: ' + $arenaLine } else { 'MISSING' }))
foreach ($r in $raiseLines) { Add-L ('  raise line           : ' + $r) }
Add-L ('  tensor registration  : ' + $loadCount + ' line(s): ' + (@($registerValues) -join ',') + ' -> ' + $(if ($registerOk) { 'OK (all 320)' } else { 'UNEXPECTED' }))
Add-L ('  load/ready lines     : ' + $loadCount + ' (a --fit probe may legitimately load twice; each load must register 320)')
Add-L ('  generated text       : "' + $text + '"')
Add-L ''
$verdict = 'PASS'
$reasons = @()
if ($ver.exit -ne 0) { $verdict = 'FAIL'; $reasons += '--version did not exit 0' }
if ($run.timed_out) { $verdict = 'FAIL'; $reasons += 'completion timed out' }
if ($run.exit -ne 0) { $verdict = 'FAIL'; $reasons += ('completion exit code ' + $run.exit) }
if (-not $streamed) { $verdict = 'FAIL'; $reasons += 'no streaming arena line' }
if (-not $registerOk) { $verdict = 'FAIL'; $reasons += 'tensor registration count missing or not 320' }
if (-not $text.Contains('Paris')) { $verdict = 'FAIL'; $reasons += 'generated text does not contain "Paris"' }
Add-L ('VERDICT: ' + $verdict + $(if ($reasons.Count -gt 0) { '  (' + ($reasons -join '; ') + ')' } else { '' }))
Add-L ''
Add-L ('Raw stdout: ' + $outFile)
Add-L ('Raw stderr: ' + $errFile)

$report = (@($lines) -join "`r`n")
Write-Utf8 $summaryFile $report
Write-Host $report
if ($verdict -eq 'FAIL') { exit 1 }
exit 0
