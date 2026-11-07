#requires -Version 5.1
# diskinfer.ps1 - Windows launcher for disktui (the diskinfer TUI)
#
#   diskinfer.ps1                                  interactive, model auto-detected
#   diskinfer.ps1 "The capital of France is"       one-shot question
#   diskinfer.ps1 -m D:\models\qwen.gguf --arena 1024 -n 64 "hello"
#   diskinfer.ps1 -h                               full help
#
# Windows equivalent of the Termux `diskinfer` wrapper: finds a model, picks a
# sensible arena size, sets the disk-streaming log location, and starts
# disktui.exe with the arguments passed through untouched.
#
# Everything after the known options is passed to disktui.exe as-is. Bare words
# (not starting with '-') are joined with spaces and become the one-shot
# question.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files as ANSI unless
# they have a BOM, so non-ASCII text would be mis-decoded on non-UTF-8 locales.

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$repoRoot = Split-Path -Parent $scriptDir

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Usage {
    Write-Host @'
usage: diskinfer.ps1 [question words...]
       diskinfer.ps1 -m PATH [--arena MiB] [question words...] [engine args]

  -m PATH        model file (.gguf). if omitted, exactly one *.gguf is searched
                 for in: %USERPROFILE%\models, .\models,
                 %USERPROFILE%\Downloads\models (several models -> exit 2,
                 none -> exit 1)
  --arena MiB    weight arena size (sets LLAMA_DISK_STREAM_MB; the engine
                 raises it to fit the largest tensor and caps it at 2048 MiB)
                 default = total RAM / 8, clamped to 176..2048 MiB
  -n N           max tokens to generate (default 256, capped by ctx)
  -c N           context size (default 256)
  -ub N          prefill batch (default 4; 1 = least RAM, slowest prefill)
  -t N           threads (default 4, try 8-16 on a desktop)
  --temp F       sampling temperature (default 1.0)
  --top-k N      default 20
  --top-p F      default 0.95
  --raw          raw completion prompt (default)
  --chat         use the chat template with thinking off
  --sys "text"   system message for --chat
  --debug        verbose disk-streaming diagnostics (LLAMA_DISK_DEBUG=1)
  -l, --list     list the models found in the search dirs and exit
  -h, --help     show this help and exit

environment:
  LLAMA_DISK_LOG       default: %TEMP%\diskinfer.log
  LLAMA_DISK_STREAM_MB arena size in MiB (--arena overrides it)
  DISKINFER_DISKTUI    explicit path to disktui.exe (for testing side builds)

examples:
  diskinfer.ps1 "The capital of France is"
  diskinfer.ps1 -m D:\models\qwen.gguf --arena 1024 -n 64 --chat "hello"

model search order:
  %USERPROFILE%\models\*.gguf
  .\models\*.gguf
  %USERPROFILE%\Downloads\models\*.gguf
'@
}

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-SearchDirs {
    $dirs = New-Object System.Collections.ArrayList
    if ($env:USERPROFILE) {
        [void]$dirs.Add((Join-Path $env:USERPROFILE 'models'))
    }
    [void]$dirs.Add((Join-Path (Get-Location).Path 'models'))
    if ($env:USERPROFILE) {
        [void]$dirs.Add((Join-Path $env:USERPROFILE 'Downloads\models'))
    }
    return @($dirs)
}

function Find-GgufModels {
    $found = New-Object System.Collections.ArrayList
    foreach ($dir in (Get-SearchDirs)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                       Sort-Object Name)
            foreach ($file in $files) {
                [void]$found.Add($file.FullName)
            }
        }
    }
    return @($found)
}

function Get-TotalRamMiB {
    # 1) CIM/WMI: works on Windows PowerShell 5.1 and PowerShell 7, no admin
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $cs -and $cs.TotalPhysicalMemory -gt 0) {
            return [int64][math]::Floor([double]$cs.TotalPhysicalMemory / 1MB)
        }
    } catch {
        # fall through to kernel32
    }
    # 2) kernel32!GlobalMemoryStatusEx
    try {
        if (-not ('DisktuiMemInfo' -as [type])) {
            $typeCode = @'
using System;
using System.Runtime.InteropServices;

public static class DisktuiMemInfo {
    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX {
        public uint  dwLength;
        public uint  dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    public static ulong TotalPhysicalBytes() {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        if (!GlobalMemoryStatusEx(ref m)) {
            return 0;
        }
        return m.ullTotalPhys;
    }
}
'@
            Add-Type -TypeDefinition $typeCode -ErrorAction Stop
        }
        $bytes = [DisktuiMemInfo]::TotalPhysicalBytes()
        if ($bytes -gt 0) {
            return [int64][math]::Floor([double]$bytes / 1MB)
        }
    } catch {
        # ignore, caller falls back to engine auto sizing
    }
    return [int64]0
}

function Get-DefaultArenaMiB {
    $totalMiB = Get-TotalRamMiB
    if ($totalMiB -le 0) {
        return [int64]0
    }
    $arena = [int64][math]::Floor($totalMiB / 8)
    if ($arena -lt 176) { $arena = [int64]176 }
    if ($arena -gt 2048) { $arena = [int64]2048 }
    return [int64]$arena
}

function Find-DisktuiExe {
    $candidates = New-Object System.Collections.ArrayList
    if ($env:DISKINFER_DISKTUI) {
        [void]$candidates.Add($env:DISKINFER_DISKTUI)
    }
    [void]$candidates.Add((Join-Path $scriptDir 'disktui.exe'))
    [void]$candidates.Add((Join-Path $repoRoot 'bin\disktui.exe'))
    [void]$candidates.Add((Join-Path $repoRoot 'build\out\win-x64\disktui.exe'))
    [void]$candidates.Add((Join-Path $repoRoot 'build\win-x64\bin\Release\llama-diskui.exe'))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# parse arguments
# ---------------------------------------------------------------------------

$modelPath    = $null
$arenaMiB     = [int64]0
$arenaGiven   = $false
$endOfOptions = $false
$question     = New-Object System.Collections.ArrayList
$childArgs    = New-Object System.Collections.ArrayList
$allArgs      = @($args)

$valueOptions = @('-n', '-c', '-ub', '-b', '-t', '-ngl', '--temp', '--top-k', '--top-p', '-q', '--sys', '--prompt')
$flagOptions  = @('--raw', '--chat', '--debug')

$i = 0
while ($i -lt $allArgs.Count) {
    $a = [string]$allArgs[$i]
    $next = $null
    if ($i + 1 -lt $allArgs.Count) { $next = [string]$allArgs[$i + 1] }

    if ($endOfOptions) {
        [void]$question.Add($a)
        $i++
        continue
    }
    if ($a -eq '--') {
        $endOfOptions = $true
        $i++
        continue
    }
    if ($a -eq '-h' -or $a -eq '--help' -or $a -eq '-help' -or $a -eq '/?') {
        Write-Usage
        exit 0
    }
    if ($a -eq '-l' -or $a -eq '--list' -or $a -eq '-list') {
        $models = @(Find-GgufModels)
        Write-Host 'model search dirs:'
        foreach ($dir in (Get-SearchDirs)) {
            $state = 'missing'
            if (Test-Path -LiteralPath $dir -PathType Container) { $state = 'exists' }
            Write-Host ("  {0}  [{1}]" -f $dir, $state)
        }
        if ($models.Count -eq 0) {
            Write-Host 'no *.gguf model found'
            exit 1
        }
        Write-Host ''
        foreach ($m in $models) {
            $bytes = (Get-Item -LiteralPath $m).Length
            Write-Host ("  {0,10:N1} MiB  {1}" -f ($bytes / 1MB), $m)
        }
        exit 0
    }
    if ($a -eq '-m' -or $a -eq '--model') {
        if ($null -eq $next) {
            Write-Host 'diskinfer: -m needs a model path'
            exit 2
        }
        $modelPath = $next
        $i += 2
        continue
    }
    if ($a -like '--arena=*') {
        $text = $a.Substring(8)
        $parsed = [int64]0
        if (-not [int64]::TryParse($text, [ref]$parsed) -or $parsed -lt 1) {
            Write-Host ("diskinfer: --arena needs a positive number in MiB (got '{0}')" -f $text)
            exit 2
        }
        $arenaMiB = $parsed
        $arenaGiven = $true
        $i++
        continue
    }
    if ($a -eq '--arena') {
        if ($null -eq $next) {
            Write-Host 'diskinfer: --arena needs a number in MiB'
            exit 2
        }
        $parsed = [int64]0
        if (-not [int64]::TryParse($next, [ref]$parsed) -or $parsed -lt 1) {
            Write-Host ("diskinfer: --arena needs a positive number in MiB (got '{0}')" -f $next)
            exit 2
        }
        $arenaMiB = $parsed
        $arenaGiven = $true
        $i += 2
        continue
    }
    if ($valueOptions -contains $a) {
        [void]$childArgs.Add($a)
        if ($null -ne $next) {
            [void]$childArgs.Add($next)
            $i += 2
        } else {
            $i++
        }
        continue
    }
    if ($flagOptions -contains $a) {
        [void]$childArgs.Add($a)
        $i++
        continue
    }
    if ($a.StartsWith('-')) {
        # unknown option: pass it through untouched
        [void]$childArgs.Add($a)
        $i++
        continue
    }
    [void]$question.Add($a)
    $i++
}

# ---------------------------------------------------------------------------
# resolve the model
# ---------------------------------------------------------------------------

if (-not $modelPath) {
    $models = @(Find-GgufModels)
    if ($models.Count -eq 1) {
        $modelPath = $models[0]
    } elseif ($models.Count -eq 0) {
        Write-Host 'diskinfer: no .gguf model found'
        Write-Host 'searched:'
        foreach ($dir in (Get-SearchDirs)) {
            $state = 'missing'
            if (Test-Path -LiteralPath $dir -PathType Container) { $state = 'no *.gguf inside' }
            Write-Host ("  {0}  [{1}]" -f $dir, $state)
        }
        Write-Host ''
        Write-Host 'put a .gguf model in one of those dirs, or pass -m PATH'
        exit 1
    } else {
        Write-Host ("diskinfer: found {0} .gguf models, pass -m PATH to choose one:" -f $models.Count)
        foreach ($m in $models) {
            Write-Host ("  {0}" -f $m)
        }
        exit 2
    }
} else {
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        Write-Host ("diskinfer: model not found: {0}" -f $modelPath)
        exit 1
    }
    $modelPath = [System.IO.Path]::GetFullPath($modelPath)
}

# ---------------------------------------------------------------------------
# locate disktui.exe
# ---------------------------------------------------------------------------

$disktui = Find-DisktuiExe
if (-not $disktui) {
    Write-Host 'diskinfer: disktui.exe not found. looked for:'
    if ($env:DISKINFER_DISKTUI) { Write-Host ("  {0}  (DISKINFER_DISKTUI)" -f $env:DISKINFER_DISKTUI) }
    Write-Host ("  {0}" -f (Join-Path $scriptDir 'disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'bin\disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'build\out\win-x64\disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'build\win-x64\bin\Release\llama-diskui.exe'))
    Write-Host ''
    Write-Host 'build it first:'
    Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f (Join-Path $repoRoot 'build\build-windows.ps1'))
    exit 1
}

# ---------------------------------------------------------------------------
# environment defaults
# ---------------------------------------------------------------------------

if (-not $arenaGiven) {
    $arenaMiB = Get-DefaultArenaMiB
}
if ($arenaMiB -gt 0) {
    # the disk engine reads the arena size from LLAMA_DISK_STREAM_MB; the
    # launcher intentionally does not pass --arena to disktui.exe because
    # older/older-style disktui builds ignore unknown flags and would treat the
    # number as the question text
    $env:LLAMA_DISK_STREAM_MB = [string]$arenaMiB
}

if (-not $env:LLAMA_DISK_LOG) {
    $logDir = $env:TEMP
    if (-not $logDir) { $logDir = $scriptDir }
    $env:LLAMA_DISK_LOG = Join-Path $logDir 'diskinfer.log'
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

$runArgs = New-Object System.Collections.ArrayList
[void]$runArgs.Add('-m')
[void]$runArgs.Add($modelPath)
foreach ($childArg in $childArgs) {
    [void]$runArgs.Add([string]$childArg)
}
if ($question.Count -gt 0) {
    [void]$runArgs.Add(($question -join ' '))
}
$runArgsArray = @($runArgs.ToArray())

Write-Host ("diskinfer: model {0}" -f $modelPath)
if ($arenaMiB -gt 0) {
    Write-Host ("diskinfer: arena {0} MiB" -f $arenaMiB)
}
Write-Host ("diskinfer: log {0}" -f $env:LLAMA_DISK_LOG)
Write-Host ("diskinfer: exec {0}" -f $disktui)

$exitCode = 1
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $disktui @runArgsArray
    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }
} catch {
    Write-Host ("diskinfer: failed to start disktui.exe: {0}" -f $_.Exception.Message)
    $exitCode = 1
} finally {
    $ErrorActionPreference = $savedPreference
}

exit $exitCode

