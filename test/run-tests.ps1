#requires -Version 7.0
<#
.SYNOPSIS
    End-to-end verification harness for the Windows port of diskinfer-android
    (llama.cpp fork that streams GGUF weights from disk into a fixed RAM arena).

.DESCRIPTION
    Runs the ported Windows binaries against the ONLY allowed model
    (Qwen3.5-0.8B Q6_K GGUF) and records raw stdout/stderr logs plus a machine
    readable (summary.json) and human readable (summary.md) summary.

    Test cases (all use the allowed model only):
      case1 streaming-200       LLAMA_DISK_STREAM_MB=200, diskrun, greedy 8 tokens
      case2 native-baseline     LLAMA_DISK_STREAM_MB=0, diskrun, same args (reference text)
      case3 auto-arena          LLAMA_DISK_STREAM_MB unset, diskrun (auto = min(RAM/8, 2048) MiB)
      case4 odirect-off         streaming 200 MiB + LLAMA_DISK_ODIRECT=0
      case5 disktui-oneshot     llama-diskui one-shot, stdin closed (NUL), stdout redirected
      case6 error-missing-model -m C:\definitely\missing.gguf -> clean nonzero exit
      case7 tiny-arena-32       arena 32 MiB -> raised-arena message or clean failure, no hang
      case2b (diagnostic)       case2 rerun with GGML_CPU_DISABLE_FUSION=1, only when
                                case1/case2 greedy text differs (unless -NoDiagnostics)

    Output contract:
      - every case gets <LogDir>\<run-id>\<case>\stdout.log and stderr.log
      - summary.json / summary.md in the same run directory
      - the script exits 0 when the overall verdict is PASS or WARN, 1 otherwise
        (TIMEOUT/FAIL/ERROR or a required cross-check mismatch -> exit 1)

    The script never edits project sources. All text it writes is ASCII.

.PARAMETER BinDir
    Preferred binary directory (the build script output).
    Default: F:\diskinfer\build\out\win-x64
.PARAMETER FallbackBinDir
    Fallback binary directory.
    Default: F:\diskinfer\build\win-x64\bin\Release
.PARAMETER LogDir
    Directory that receives the per-run log folder. Default: <script dir>\logs
.PARAMETER Model
    GGUF model path. Hard rule: only Qwen3.5-0.8B-Q6_K.gguf (629,743,584 bytes)
    is allowed; other paths are rejected unless -AllowUnlistedModel is given.
.PARAMETER Cases
    Optional subset, e.g. -Cases 1,2,5 or -Cases case1,streaming-200. Default: all.
.PARAMETER TimeoutSec
    Per-case timeout in seconds (default 900 = 15 min). Timed out cases are
    killed (whole process tree) and marked TIMEOUT.
.PARAMETER PollMs
    Sampling interval for RSS / CPU / I/O counters (default 200 ms).
.PARAMETER DryRun
    Resolve binaries/model, print the planned commands and env vars, write nothing.
.PARAMETER NoDiagnostics
    Do not run the extra case2b diagnostic when streamed/native text differ.
.PARAMETER AllowUnlistedModel
    Allow a model other than the allowed Qwen3.5-0.8B Q6_K GGUF (NOT recommended).
.PARAMETER HashModel
    Also compute the SHA256 of the model file (adds a few seconds).

.EXAMPLE
    pwsh -File F:\diskinfer\test\run-tests.ps1 -DryRun

.EXAMPLE
    pwsh -File F:\diskinfer\test\run-tests.ps1

.EXAMPLE
    pwsh -File F:\diskinfer\test\run-tests.ps1 -Cases 1,5 -TimeoutSec 600
#>
[CmdletBinding()]
param(
    [string]$BinDir = 'F:\diskinfer\build\out\win-x64',
    [string]$FallbackBinDir = 'F:\diskinfer\build\win-x64\bin\Release',
    [string]$LogDir = '',
    [string]$Model = 'D:\LMStudioModel\lmstudio-community\Qwen3.5-0.8B-GGUF\Qwen3.5-0.8B-Q6_K.gguf',
    [string[]]$Cases = @(),
    [int]$TimeoutSec = 900,
    [int]$PollMs = 200,
    [switch]$NoDiagnostics,
    [switch]$DryRun,
    [switch]$AllowUnlistedModel,
    [switch]$HashModel
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants
$script:PromptText       = 'The capital of France is'
$script:AllowedModelLeaf = 'Qwen3.5-0.8B-Q6_K.gguf'
$script:AllowedModelSize = [int64]629743584
$script:DiskEnvVars = @(
    'LLAMA_DISK_STREAM_MB',
    'LLAMA_DISK_ODIRECT',
    'LLAMA_DISK_MLOCK',
    'LLAMA_DISK_PREFETCH',
    'LLAMA_DISK_LOOKAHEAD',
    'LLAMA_DISK_VERBOSE',
    'LLAMA_DISK_DEBUG',
    'LLAMA_DISK_WINDOW',
    'LLAMA_DISK_OUT_CHUNK',
    'LLAMA_DISK_LOG',
    'GGML_CPU_DISABLE_FUSION'
)

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    if ($PSScriptRoot) {
        $LogDir = Join-Path $PSScriptRoot 'logs'
    }
    else {
        $LogDir = 'F:\diskinfer\test\logs'
    }
}

$script:ProcIoAvailable = $false

# ---------------------------------------------------------------- text helpers
function Convert-ToAsciiText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # keep tab, LF, CR and printable ASCII; replace everything else with '?'
    return [regex]::Replace($Text, '[^\x09\x0A\x0D\x20-\x7E]', '?')
}

function Remove-AnsiEscapes {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $esc = [string][char]27
    $out = [regex]::Replace($Text, [regex]::Escape($esc) + '\[[0-9;?]*[A-Za-z]', '')
    $out = [regex]::Replace($out, [regex]::Escape($esc) + '\][^\x07]*\x07', '')
    $out = $out.Replace("`r", '')
    return $out
}

function Format-Seconds {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([double]$Value).ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Mib {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([double]$Value).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------- file helpers
function Write-Utf8File {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, [string]$Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-TextFileSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
        }
    }
    catch { }
    return ''
}

function Get-Sha256Hex {
    param([string]$Path, [int]$PrefixChars = 64)
    try {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($PrefixChars -gt 0 -and $PrefixChars -lt $hash.Length) { return $hash.Substring(0, $PrefixChars) }
        return $hash
    }
    catch { return '' }
}

function Get-FileSummary {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        path        = $item.FullName
        length      = [int64]$item.Length
        last_write  = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        sha256_16   = (Get-Sha256Hex -Path $item.FullName -PrefixChars 16)
    }
}

function Get-TextTailExcerpt {
    param([string]$Path, [int]$Count = 15)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
    }
    catch { return @() }
    $start = [Math]::Max(0, $lines.Length - $Count)
    $out = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $lines.Length; $i++) {
        [void]$out.Add(('{0,5}: {1}' -f ($i + 1), (Convert-ToAsciiText $lines[$i])))
    }
    return @($out)
}

function Find-TextMatches {
    param([string[]]$Paths, [string]$Pattern, [int]$MaxMatches = 6)
    $results = New-Object System.Collections.ArrayList
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try { $lines = [System.IO.File]::ReadAllLines($p) } catch { continue }
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match $Pattern) {
                [void]$results.Add(('{0}:{1}: {2}' -f (Split-Path -Leaf $p), ($i + 1), (Convert-ToAsciiText $lines[$i])))
                if ($results.Count -ge $MaxMatches) { return @($results) }
            }
        }
    }
    return @($results)
}

function Write-Step {
    param([string]$Message)
    Write-Host $Message
}

# ---------------------------------------------------------------- machine info
function Get-MachineInfo {
    $info = [ordered]@{
        computed_at        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        os_caption         = ''
        os_version         = ''
        os_build           = ''
        computer_name      = $env:COMPUTERNAME
        user               = $env:USERNAME
        cpu_name           = ''
        physical_cores     = 0
        logical_cores      = 0
        total_ram_mib      = 0
        free_ram_mib       = 0
        powershell_version = $PSVersionTable.PSVersion.ToString()
        dotnet             = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        pwsh_path          = (Get-Process -Id $PID).Path
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $info.os_caption = [string]$os.Caption
        $info.os_version = [string]$os.Version
        $info.os_build   = [string]$os.BuildNumber
        $info.free_ram_mib = [int][Math]::Round(([double]$os.FreePhysicalMemory) / 1024.0)
    }
    catch { }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $info.total_ram_mib = [int][Math]::Round(([double]$cs.TotalPhysicalMemory) / 1MB)
    }
    catch { }
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.cpu_name       = [string]$cpu.Name
        $info.physical_cores = [int]$cpu.NumberOfCores
        $info.logical_cores  = [int]$cpu.NumberOfLogicalProcessors
    }
    catch { }
    # keep every text this harness emits ASCII-only (localized OS captions are not)
    foreach ($k in @('os_caption', 'os_version', 'os_build', 'computer_name', 'user', 'cpu_name')) {
        $info[$k] = Convert-ToAsciiText ([string]$info[$k])
    }
    return [pscustomobject]$info
}

# ---------------------------------------------------------------- binary lookup
function Resolve-PortBinaries {
    param([string]$PrimaryDir, [string]$FallbackDir)
    $spec = [ordered]@{
        diskrun    = @('diskrun.exe', 'llama-diskrun.exe')
        disktui    = @('disktui.exe', 'llama-diskui.exe')
        completion = @('llama-completion.exe')
    }
    $searchDirs = New-Object System.Collections.ArrayList
    foreach ($d in @($PrimaryDir, $FallbackDir)) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        try {
            if (Test-Path -LiteralPath $d -PathType Container) {
                $full = (Resolve-Path -LiteralPath $d).Path
                if (-not $searchDirs.Contains($full)) { [void]$searchDirs.Add($full) }
            }
        }
        catch { }
    }
    $resolved = [ordered]@{}
    $searched = [ordered]@{}
    foreach ($key in @($spec.Keys)) {
        $hit  = $null
        $tried = New-Object System.Collections.ArrayList
        foreach ($dir in $searchDirs) {
            foreach ($name in $spec[$key]) {
                $p = Join-Path $dir $name
                [void]$tried.Add($p)
                if ($null -eq $hit) {
                    if (Test-Path -LiteralPath $p -PathType Leaf) {
                        $hit = (Resolve-Path -LiteralPath $p).Path
                    }
                }
            }
        }
        $resolved[$key] = $hit
        $searched[$key] = @($tried)
    }
    $missing = New-Object System.Collections.ArrayList
    foreach ($key in @($spec.Keys)) {
        if ($null -eq $resolved[$key]) { [void]$missing.Add($key) }
    }
    return [pscustomobject]@{
        search_dirs     = @($searchDirs)
        resolve_spec    = $spec
        resolved        = $resolved
        searched        = $searched
        missing         = @($missing)
        primary_dir     = $PrimaryDir
        fallback_dir    = $FallbackDir
        primary_exists  = (Test-Path -LiteralPath $PrimaryDir -PathType Container)
        fallback_exists = (Test-Path -LiteralPath $FallbackDir -PathType Container)
    }
}

function Get-BinaryDetails {
    param($BinInfo)
    $rows = New-Object System.Collections.ArrayList
    foreach ($key in @($BinInfo.resolve_spec.Keys)) {
        $path = $BinInfo.resolved[$key]
        if ($null -eq $path) {
            [void]$rows.Add([pscustomobject]@{
                key             = $key
                path            = ''
                exists          = $false
                length          = 0
                last_write      = ''
                sha256_16       = ''
                sibling_dlls    = @()
                stale_dll_count = 0
            })
            continue
        }
        $item = Get-Item -LiteralPath $path
        $dir  = Split-Path -Parent $path
        $dlls = @()
        try { $dlls = @(Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue | Sort-Object Name) } catch { }
        $stale = 0
        foreach ($dll in $dlls) {
            if ($dll.LastWriteTime -lt $item.LastWriteTime.AddMinutes(-1)) { $stale++ } else { }
        }
        $dllNames = @()
        foreach ($dll in $dlls) { $dllNames += $dll.Name }
        [void]$rows.Add([pscustomobject]@{
            key             = $key
            path            = $item.FullName
            exists          = $true
            length          = [int64]$item.Length
            last_write      = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            sha256_16       = (Get-Sha256Hex -Path $item.FullName -PrefixChars 16)
            sibling_dlls    = $dllNames
            stale_dll_count = $stale
        })
    }
    return @($rows)
}

# ---------------------------------------------------------------- model info
function Get-ModelInfo {
    param([string]$Path, [switch]$AllowUnlisted, [switch]$Hash)
    $result = [ordered]@{
        path          = $Path
        leaf          = (Split-Path -Leaf $Path)
        exists        = $false
        length        = 0
        last_write    = ''
        sha256        = ''
        allowed_leaf  = $script:AllowedModelLeaf
        allowed_size  = $script:AllowedModelSize
        policy_ok     = $false
        fatal         = $true
        reasons       = @()
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.reasons = @('model file not found: ' + $Path)
        return [pscustomobject]$result
    }
    $item = Get-Item -LiteralPath $Path
    $result.exists       = $true
    $result.length       = [int64]$item.Length
    $result.last_write   = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    $reasons = New-Object System.Collections.ArrayList
    if (-not $AllowUnlisted) {
        if ($result.leaf -ne $script:AllowedModelLeaf) {
            [void]$reasons.Add(('filename ''{0}'' is not the allowed model ''{1}''' -f $result.leaf, $script:AllowedModelLeaf))
        }
        if ($result.length -ne $script:AllowedModelSize) {
            [void]$reasons.Add(('size {0} bytes != allowed {1} bytes' -f $result.length, $script:AllowedModelSize))
        }
    }
    if ($Hash) { $result.sha256 = (Get-Sha256Hex -Path $item.FullName -PrefixChars 0) }
    $result.reasons = @($reasons)
    $result.policy_ok = ($reasons.Count -eq 0)
    $result.fatal = ($reasons.Count -gt 0)
    return [pscustomobject]$result
}

# ---------------------------------------------------------------- case definitions
function New-CaseExpectation {
    param([hashtable]$Overrides)
    $base = [ordered]@{
        exit                = 'zero'   # 'zero' | 'nonzero'
        streaming           = 'on'     # 'on' | 'off' | 'any'
        arena_requested     = $null    # requested LLAMA_DISK_STREAM_MB, if any
        arena_auto          = $false   # expect min(RAM/8, 2048) MiB
        require_raise       = $false   # expect "arena ... raised to fit the largest tensor"
        raise_from          = $null    # expected requested value in the raise message
        tokens_min          = 1
        tokens_max          = 8
        require_answer      = $true
        require_error       = $false
        allow_clean_failure = $false
        max_rss_mib         = $null
        direct_io           = $null    # expected direct io flag in the arena line
        require_disk_read   = $false   # expect process I/O counters to prove real reads
        expected_tensors    = $null    # expected "N tensors registered" per model load
    }
    if ($Overrides) {
        foreach ($k in @($Overrides.Keys)) {
            if (-not $base.Contains($k)) { throw ("unknown expectation key: " + $k) }
            $base[$k] = $Overrides[$k]
        }
    }
    return $base
}

function Get-CaseDefinitions {
    param([string]$ModelPath)
    $genArgs = @('-m', $ModelPath, '-p', $script:PromptText, '-n', '8', '-c', '128', '-b', '4', '-ub', '4', '-t', '4')
    $defs = New-Object System.Collections.ArrayList

    [void]$defs.Add([pscustomobject]@{
        id          = 'case1'
        name        = 'streaming-200'
        exe_key     = 'diskrun'
        args        = $genArgs
        env         = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '200' }
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Stream weights from disk with a 200 MiB arena, greedy 8 tokens.'
        expect      = (New-CaseExpectation -Overrides @{
            streaming         = 'on'
            arena_requested   = 200
            require_raise     = $true
            raise_from        = 200
            direct_io         = 1
            max_rss_mib       = 1024
            require_disk_read = $true
            expected_tensors  = 320
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case2'
        name        = 'native-baseline'
        exe_key     = 'diskrun'
        args        = $genArgs
        env         = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '0' }
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Native llama.cpp path (LLAMA_DISK_STREAM_MB=0, mmap / full load), reference text.'
        expect      = (New-CaseExpectation -Overrides @{
            streaming         = 'off'
            require_answer    = $true
            require_disk_read = $false
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case3'
        name        = 'auto-arena'
        exe_key     = 'diskrun'
        args        = $genArgs
        env         = [ordered]@{}
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Arena size auto (LLAMA_DISK_STREAM_MB unset): expect min(RAM/8, 2048) MiB.'
        expect      = (New-CaseExpectation -Overrides @{
            streaming         = 'on'
            arena_auto        = $true
            require_raise     = $false
            require_disk_read = $true
            expected_tensors  = 320
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case4'
        name        = 'odirect-off'
        exe_key     = 'diskrun'
        args        = $genArgs
        env         = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '200'; 'LLAMA_DISK_ODIRECT' = '0' }
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Streaming with direct I/O disabled (LLAMA_DISK_ODIRECT=0).'
        expect      = (New-CaseExpectation -Overrides @{
            streaming         = 'on'
            arena_requested   = 200
            require_raise     = $true
            raise_from        = 200
            direct_io         = 0
            require_disk_read = $true
            expected_tensors  = 320
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case5'
        name        = 'disktui-oneshot'
        exe_key     = 'disktui'
        args        = @('-m', $ModelPath, '-n', '4', $script:PromptText)
        env         = [ordered]@{}
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $true
        add_home_env = $true
        description = 'disktui one-shot smoke test: stdin closed (NUL), stdout redirected, ANSI expected.'
        expect      = (New-CaseExpectation -Overrides @{
            streaming      = 'any'
            tokens_max     = 4
            require_answer = $true
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case6'
        name        = 'error-missing-model'
        exe_key     = 'diskrun'
        args        = @('-m', 'C:\definitely\missing.gguf', '-n', '4', '-c', '64', '-b', '4', '-ub', '4', '-t', '4')
        env         = [ordered]@{}
        timeout_sec = 180
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Missing model path must produce a clean error, nonzero exit, no crash/hang.'
        expect      = (New-CaseExpectation -Overrides @{
            exit           = 'nonzero'
            streaming      = 'any'
            require_answer = $false
            require_error  = $true
            tokens_min     = $null
            tokens_max     = $null
        })
    })

    [void]$defs.Add([pscustomobject]@{
        id          = 'case7'
        name        = 'tiny-arena-32'
        exe_key     = 'diskrun'
        args        = $genArgs
        env         = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '32' }
        timeout_sec = 0
        stdin       = 'closed'
        add_log_env = $false
        add_home_env = $false
        description = 'Tiny 32 MiB arena must be auto-raised to largest-tensor+24 MiB and still run; record the raised size.'
        expect      = (New-CaseExpectation -Overrides @{
            streaming           = 'on'
            arena_requested     = 32
            require_raise       = $true
            raise_from          = 32
            allow_clean_failure = $false
            require_answer      = $true
            require_disk_read   = $false
            expected_tensors    = 320
        })
    })

    return @($defs)
}

function Select-CaseDefinitions {
    param($Definitions, [string[]]$Filter)
    $filtered = New-Object System.Collections.ArrayList
    foreach ($f in @($Filter)) {
        if ($null -eq $f) { continue }
        foreach ($part in ([string]$f -split ',')) {
            $p = $part.Trim()
            if ($p) { [void]$filtered.Add($p.ToLowerInvariant()) }
        }
    }
    if ($filtered.Count -eq 0) { return @($Definitions) }
    $out = New-Object System.Collections.ArrayList
    foreach ($def in $Definitions) {
        foreach ($w in @($filtered)) {
            $bare = $def.id -replace '^case', ''
            if ($w -eq $def.id.ToLowerInvariant() -or $w -eq $def.name.ToLowerInvariant() -or $w -eq $bare) {
                [void]$out.Add($def)
                break
            }
        }
    }
    return @($out)
}

# ================================================================
# child process execution (isolated env, timeout, RSS + I/O sampling)
# ================================================================

$script:ProcIoCode = @'
using System;
using System.Runtime.InteropServices;

namespace DiskInferTest
{
    public static class ProcessIo
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_MEMORY_COUNTERS
        {
            public uint cb;
            public uint PageFaultCount;
            public UIntPtr PeakWorkingSetSize;
            public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage;
            public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage;
            public UIntPtr PeakPagefileUsage;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS counters);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr hProcess, out long creation, out long exit, out long kernel, out long user);

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetProcessMemoryInfo(IntPtr hProcess, out PROCESS_MEMORY_COUNTERS counters, uint cb);

        public static ulong[] Get(IntPtr hProcess)
        {
            IO_COUNTERS c;
            if (!GetProcessIoCounters(hProcess, out c))
            {
                return null;
            }
            return new ulong[]
            {
                c.ReadOperationCount,
                c.WriteOperationCount,
                c.OtherOperationCount,
                c.ReadTransferCount,
                c.WriteTransferCount,
                c.OtherTransferCount
            };
        }

        public static ulong[] GetMemory(IntPtr hProcess)
        {
            PROCESS_MEMORY_COUNTERS c = new PROCESS_MEMORY_COUNTERS();
            c.cb = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS));
            if (!GetProcessMemoryInfo(hProcess, out c, c.cb))
            {
                return null;
            }
            return new ulong[]
            {
                c.WorkingSetSize.ToUInt64(),
                c.PeakWorkingSetSize.ToUInt64(),
                c.PagefileUsage.ToUInt64(),
                c.PeakPagefileUsage.ToUInt64(),
                (ulong)c.PageFaultCount
            };
        }

        public static ulong GetCpu100ns(IntPtr hProcess)
        {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(hProcess, out creation, out exit, out kernel, out user))
            {
                return 0;
            }
            return (ulong)(kernel + user);
        }
    }
}
'@

function Initialize-ProcIoCouners {
    if (-not ('DiskInferTest.ProcessIo' -as [type])) {
        try {
            Add-Type -TypeDefinition $script:ProcIoCode -ErrorAction Stop
            $script:ProcIoAvailable = $true
        }
        catch {
            $script:ProcIoAvailable = $false
        }
    }
    else {
        $script:ProcIoAvailable = $true
    }
}

function New-EmptyRun {
    param([string]$Message)
    return [pscustomobject]@{
        exe_path         = ''
        exe_key          = ''
        args             = ''
        env_text         = ''
        work_dir         = ''
        exit_code        = $null
        exit_hex         = ''
        exit_u32         = $null
        timed_out        = $false
        start_error      = $Message
        capture_note     = ''
        duration_s       = 0.0
        stdout           = ''
        stderr           = ''
        stdout_file      = ''
        stderr_file      = ''
        rss_os_peak_mib  = $null
        rss_os_max_mib   = $null
        private_peak_mib = $null
        disk_read_mib    = $null
        disk_read_ops    = $null
        cpu_s            = $null
        io_samples       = 0
        started_at       = ''
        finished_at      = ''
        output_bytes     = 0
    }
}

function Invoke-TestProcess {
    param(
        [string]$ExePath,
        [string[]]$ArgumentList,
        $EnvMap,
        [string]$WorkDir,
        [int]$TimeoutSec,
        [string]$CaseDir,
        [int]$PollMs = 200,
        [string]$ExeKey = ''
    )

    $stdoutFile = Join-Path $CaseDir 'stdout.log'
    $stderrFile = Join-Path $CaseDir 'stderr.log'
    if (-not (Test-Path -LiteralPath $CaseDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $CaseDir | Out-Null
    }

    $envPairs = New-Object System.Collections.ArrayList
    if ($EnvMap) {
        foreach ($k in @($EnvMap.Keys)) {
            [void]$envPairs.Add(('{0}={1}' -f $k, [string]$EnvMap[$k]))
        }
    }
    $envText = (@($envPairs) -join '; ')

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $ExePath
    $psi.WorkingDirectory       = $WorkDir
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    foreach ($a in @($ArgumentList)) {
        if ($null -ne $a) { [void]$psi.ArgumentList.Add([string]$a) }
    }

    # start from the inherited environment but strip every disk/ggml switch so
    # nothing can leak between cases, then apply exactly what this case needs
    foreach ($varName in @($script:DiskEnvVars)) {
        if ($psi.Environment.ContainsKey($varName)) { [void]$psi.Environment.Remove($varName) }
    }
    if ($EnvMap) {
        foreach ($k in @($EnvMap.Keys)) {
            $psi.Environment[[string]$k] = [string]$EnvMap[$k]
        }
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tStart = Get-Date
    try {
        $started = $proc.Start()
    }
    catch {
        $sw.Stop()
        $run = New-EmptyRun -Message ('failed to start: ' + $_.Exception.Message)
        $run.exe_path  = $ExePath
        $run.exe_key   = $ExeKey
        $run.args      = (@($ArgumentList) -join ' ')
        $run.env_text  = $envText
        $run.work_dir  = $WorkDir
        $run.started_at = $tStart.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Utf8File -Path $stdoutFile -Text ''
        Write-Utf8File -Path $stderrFile -Text ''
        $run.stdout_file = $stdoutFile
        $run.stderr_file = $stderrFile
        return $run
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try { $proc.StandardInput.Close() } catch { }

    $maxWsBytes   = [int64]0
    $maxPrivBytes = [int64]0
    $maxPeakBytes = [int64]0
    $maxDiskRead  = [uint64]0
    $maxDiskOps   = [uint64]0
    $maxCpu       = 0.0
    $samples      = 0
    $timedOut     = $false

    while ($true) {
        $elapsed = $sw.Elapsed.TotalSeconds

        # The PowerShell Process wrapper caches some memory properties after the
        # first read (verified on this machine), so use the Win32 API directly and
        # fall back to a fresh Process object if psapi is unavailable.
        if ($script:ProcIoAvailable) {
            try {
                $mem = [DiskInferTest.ProcessIo]::GetMemory($proc.Handle)
                if ($null -ne $mem) {
                    if ([int64]$mem[0] -gt $maxWsBytes)   { $maxWsBytes   = [int64]$mem[0] }
                    if ([int64]$mem[1] -gt $maxPeakBytes) { $maxPeakBytes = [int64]$mem[1] }
                    if ([int64]$mem[3] -gt $maxPrivBytes) { $maxPrivBytes = [int64]$mem[3] }
                }
            }
            catch { }
            try {
                $cpu100 = [DiskInferTest.ProcessIo]::GetCpu100ns($proc.Handle)
                if ($cpu100 -gt 0) {
                    $cpu = [double]$cpu100 / 10000000.0
                    if ($cpu -gt $maxCpu) { $maxCpu = $cpu }
                }
            }
            catch { }
            try {
                $counters = [DiskInferTest.ProcessIo]::Get($proc.Handle)
                if ($null -ne $counters) {
                    if ($counters[3] -gt $maxDiskRead) { $maxDiskRead = [uint64]$counters[3] }
                    if ($counters[0] -gt $maxDiskOps)  { $maxDiskOps  = [uint64]$counters[0] }
                }
            }
            catch { }
        }
        else {
            try {
                $fresh = [System.Diagnostics.Process]::GetProcessById($proc.Id)
                try {
                    $ws = [int64]$fresh.WorkingSet64
                    if ($ws -gt $maxWsBytes) { $maxWsBytes = $ws }
                    $peak = [int64]$fresh.PeakWorkingSet64
                    if ($peak -gt $maxPeakBytes) { $maxPeakBytes = $peak }
                    $priv = [int64]$fresh.PrivateMemorySize64
                    if ($priv -gt $maxPrivBytes) { $maxPrivBytes = $priv }
                    $cpu = [double]$fresh.TotalProcessorTime.TotalSeconds
                    if ($cpu -gt $maxCpu) { $maxCpu = $cpu }
                }
                finally { $fresh.Dispose() }
            }
            catch { }
        }
        $samples++

        if ($proc.HasExited) { break }
        if ($elapsed -ge $TimeoutSec) { $timedOut = $true; break }
        Start-Sleep -Milliseconds $PollMs
    }

    $captureNote = ''
    if ($timedOut) {
        try { $proc.Kill($true) } catch { }
        try { [void]$proc.WaitForExit(15000) } catch { }
        $captureNote = ('killed after {0:N1}s timeout' -f $sw.Elapsed.TotalSeconds)
    }
    try {
        if (-not $proc.HasExited) {
            [void]$proc.WaitForExit(15000)
            if (-not $proc.HasExited) {
                try { $proc.Kill($true) } catch { }
                [void]$proc.WaitForExit(5000)
            }
        }
    }
    catch { }
    $sw.Stop()

    $duration = $sw.Elapsed.TotalSeconds
    try {
        if ($proc.HasExited) {
            $duration = ($proc.ExitTime - $proc.StartTime).TotalSeconds
        }
    }
    catch { }

    $stdout = ''
    $stderr = ''
    try {
        if ($outTask.Wait(15000)) { $stdout = [string]$outTask.Result }
        else { $captureNote = ($captureNote + ' stdout capture did not complete').Trim() }
    }
    catch { }
    try {
        if ($errTask.Wait(15000)) { $stderr = [string]$errTask.Result }
        else { $captureNote = ($captureNote + ' stderr capture did not complete').Trim() }
    }
    catch { }

    $exitCode = $null
    $exitHex  = ''
    $exitU32  = $null
    try {
        if ($proc.HasExited) {
            $exitCode = [int]$proc.ExitCode
            $u = [int64]$exitCode
            if ($u -lt 0) { $u += 4294967296 }
            $exitU32 = [uint32]$u
            $exitHex = '0x{0:X8}' -f $exitU32
        }
    }
    catch { }

    Write-Utf8File -Path $stdoutFile -Text $stdout
    Write-Utf8File -Path $stderrFile -Text $stderr

    $run = [pscustomobject]@{
        exe_path         = $ExePath
        exe_key          = $ExeKey
        args             = (@($ArgumentList) -join ' ')
        env_text         = $envText
        work_dir         = $WorkDir
        exit_code        = $exitCode
        exit_hex         = $exitHex
        exit_u32         = $exitU32
        timed_out        = $timedOut
        start_error      = ''
        capture_note     = $captureNote
        duration_s       = [double]$duration
        stdout           = $stdout
        stderr           = $stderr
        stdout_file      = $stdoutFile
        stderr_file      = $stderrFile
        rss_os_peak_mib  = $(if ($maxPeakBytes -gt 0) { $maxPeakBytes / 1MB } elseif ($maxWsBytes -gt 0) { $maxWsBytes / 1MB } else { $null })
        rss_os_max_mib   = $(if ($maxWsBytes -gt 0) { $maxWsBytes / 1MB } else { $null })
        private_peak_mib = $(if ($maxPrivBytes -gt 0) { $maxPrivBytes / 1MB } else { $null })
        disk_read_mib    = $(if ($maxDiskRead -gt 0) { [double]$maxDiskRead / 1MB } else { $null })
        disk_read_ops    = $(if ($maxDiskOps -gt 0) { [double]$maxDiskOps } else { $null })
        cpu_s            = $(if ($maxCpu -gt 0) { $maxCpu } else { $null })
        io_samples       = $samples
        started_at       = $tStart.ToString('yyyy-MM-dd HH:mm:ss')
        finished_at      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        output_bytes     = ($stdout.Length + $stderr.Length)
    }

    try { $proc.Dispose() } catch { }
    return $run
}

# ================================================================
# log parsing
# ================================================================

function Remove-DuplicateLogLines {
    param([string]$Text)
    # The TUI repaints its whole log window into stdout on every update, so the
    # same log line appears many times in a redirected stdout capture. Metrics
    # must be read once, from the first occurrence of each distinct line.
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($Text -split "`n")) {
        $key = $line.TrimEnd()
        if ($key.Length -eq 0) { continue }
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$out.Add($line)
        }
    }
    return (@($out) -join "`n")
}

function Parse-ChildOutput {
    param([string]$Stdout, [string]$Stderr, [string]$ExtraLog)

    if ($null -eq $Stdout)  { $Stdout = '' }
    if ($null -eq $Stderr)  { $Stderr = '' }
    if ($null -eq $ExtraLog) { $ExtraLog = '' }

    $rawAll    = $Stdout + "`n" + $Stderr + "`n" + $ExtraLog
    $cleanOut  = Remove-AnsiEscapes $Stdout
    $cleanErr  = Remove-AnsiEscapes $Stderr
    $cleanLog  = Remove-AnsiEscapes $ExtraLog
    $cleanAll  = Remove-AnsiEscapes $rawAll

    # metric lines: prefer the TUI log file (written once per logf call); fall
    # back to de-duplicated stdout/stderr for diskrun and for missing log files
    $metricText = ''
    if ($cleanLog.Trim().Length -gt 0) {
        $metricText = Remove-DuplicateLogLines $cleanLog
    }
    else {
        $metricText = Remove-DuplicateLogLines ($cleanOut + "`n" + $cleanErr)
    }

    $p = [ordered]@{
        streamed              = $false
        arena_mib             = $null
        arena_why             = ''
        direct_io             = $null
        mlock                 = $null
        prefetch              = $null
        lookahead             = $null
        raised                = $null
        clamped               = $null
        registered_tensors    = $null
        registered_mib        = $null
        largest_tensor        = ''
        largest_tensor_mib    = $null
        alloc_failed          = $false
        odirect_fallback      = $false
        arena_runtime_error   = ''
        model_load_s          = $null
        prefill_s             = $null
        prefill_tokens        = $null
        prefill_io_s          = $null
        prefill_cmp_s         = $null
        tokens_generated      = $null
        gen_s                 = $null
        gen_io_s              = $null
        gen_cmp_s             = $null
        per_token             = @()
        per_token_samples     = @()
        io_total_s            = $null
        cmp_total_s           = $null
        io_reported           = $false
        rss_app_mib           = $null
        answer_log            = ''
        answer_found          = $false
        llama_perf_load_ms    = $null
        llama_perf_prompt_ms  = $null
        llama_perf_prompt_tok = $null
        llama_perf_eval_ms    = $null
        llama_perf_eval_runs  = $null
        error_text            = ''
        has_error             = $false
        has_crash_marker      = $false
        crash_markers         = @()
    }

    # ---- arena / streaming engine diagnostics
    $m = [regex]::Match($metricText, 'llama-disk: streaming weights from disk, arena = (\d+) MiB \(([^)]*)\), direct io = (\d+), mlock = (\d+), prefetch = (\d+) \(lookahead (\d+)\)')
    if ($m.Success) {
        $p.streamed   = $true
        $p.arena_mib  = [int]$m.Groups[1].Value
        $p.arena_why  = $m.Groups[2].Value.Trim()
        $p.direct_io  = [int]$m.Groups[3].Value
        $p.mlock      = [int]$m.Groups[4].Value
        $p.prefetch   = [int]$m.Groups[5].Value
        $p.lookahead  = [int]$m.Groups[6].Value
    }
    $m = [regex]::Match($metricText, "llama-disk: arena (\d+) MiB cannot hold the largest tensor '([^']*)' \((\d+) MiB\), raised to (\d+) MiB")
    if ($m.Success) {
        $p.raised = [pscustomobject]@{
            from       = [int]$m.Groups[1].Value
            tensor     = $m.Groups[2].Value
            tensor_mib = [int]$m.Groups[3].Value
            to         = [int]$m.Groups[4].Value
        }
    }
    $m = [regex]::Match($metricText, 'llama-disk: arena (\d+) MiB clamped to (\d+) MiB, only (\d+) MiB is free')
    if ($m.Success) {
        $p.clamped = [pscustomobject]@{
            from     = [int]$m.Groups[1].Value
            to       = [int]$m.Groups[2].Value
            free_mib = [int]$m.Groups[3].Value
        }
    }
    $m = [regex]::Match($metricText, "llama-disk: (\d+) tensors registered, (\d+) MiB to stream, largest tensor '([^']*)' (\d+) MiB")
    if ($m.Success) {
        $p.registered_tensors = [int]$m.Groups[1].Value
        $p.registered_mib     = [int]$m.Groups[2].Value
        $p.largest_tensor     = $m.Groups[3].Value
        $p.largest_tensor_mib = [int]$m.Groups[4].Value
    }
    if ([regex]::IsMatch($metricText, 'llama-disk: failed to allocate \d+ MiB arena')) {
        $p.alloc_failed = $true
    }
    if ([regex]::IsMatch($metricText, '(?i)(O_DIRECT unavailable|direct io unavailable|cannot use direct io|falling back to buffered)')) {
        $p.odirect_fallback = $true
    }
    $m = [regex]::Match($metricText, "arena is (\d+) MiB but the largest tensor '([^']*)' needs (\d+) MiB")
    if ($m.Success) {
        $p.arena_runtime_error = $m.Value
    }

    # ---- model load time
    $m = [regex]::Match($metricText, 'diskrun: model loaded in ([\d.]+) s')
    if ($m.Success) { $p.model_load_s = [double]$m.Groups[1].Value }
    if ($null -eq $p.model_load_s) {
        $m = [regex]::Match($metricText, '\[\s*([\d.]+)s\] model ready')
        if ($m.Success) { $p.model_load_s = [double]$m.Groups[1].Value }
    }
    if ($null -eq $p.model_load_s) {
        $m = [regex]::Match($metricText, 'load time\s*=\s*([\d.]+)\s*ms')
        if ($m.Success) { $p.model_load_s = [double]$m.Groups[1].Value / 1000.0 }
    }

    # ---- prefill timings
    $m = [regex]::Match($metricText, 'diskrun: prefill took ([\d.]+) s')
    if ($m.Success) { $p.prefill_s = [double]$m.Groups[1].Value }
    $m = [regex]::Match($metricText, 'prompt done: (\d+) tok in ([\d.]+)s \(([\d.]+) s/tok\), io ([\d.]+)s')
    if ($m.Success) {
        $p.prefill_tokens = [int]$m.Groups[1].Value
        $p.prefill_s      = [double]$m.Groups[2].Value
        $p.prefill_io_s   = [double]$m.Groups[4].Value
    }
    $ppMatches = [regex]::Matches($metricText, '\[\s*\d+:\d+\]\s*pp\s+\d+-\d+/\d+\s+io\s+([\d.]+)s\s+cmp\s+([\d.]+)s')
    if ($ppMatches.Count -gt 0) {
        $ioSum  = 0.0
        $cmpSum = 0.0
        foreach ($mm in $ppMatches) {
            $ioSum  += [double]$mm.Groups[1].Value
            $cmpSum += [double]$mm.Groups[2].Value
        }
        if ($null -eq $p.prefill_io_s) { $p.prefill_io_s = $ioSum }
        $p.prefill_cmp_s = $cmpSum
    }

    # ---- per token io/cmp (disktui style)
    $tokenRows = New-Object System.Collections.ArrayList
    $tMatches = [regex]::Matches($metricText, '\[\s*(\d+):(\d+)\]\s*t(\d+)\s+io\s+([\d.]+)s\s+cmp\s+([\d.]+)s\s+tot\s+([\d.]+)s\s+''(.*?)''')
    foreach ($mm in $tMatches) {
        [void]$tokenRows.Add([pscustomobject]@{
            index   = [int]$mm.Groups[3].Value
            io_s    = [double]$mm.Groups[4].Value
            cmp_s   = [double]$mm.Groups[5].Value
            total_s = [double]$mm.Groups[6].Value
            piece   = $mm.Groups[7].Value
            source  = 'disktui'
        })
    }
    if ($tokenRows.Count -eq 0) {
        $tMatches = [regex]::Matches($metricText, '\[\s*(\d+):(\d+)\]\s*t(\d+)\s+io\s+([\d.]+)s\s+cmp\s+([\d.]+)s\s+tot\s+([\d.]+)s')
        foreach ($mm in $tMatches) {
            [void]$tokenRows.Add([pscustomobject]@{
                index   = [int]$mm.Groups[3].Value
                io_s    = [double]$mm.Groups[4].Value
                cmp_s   = [double]$mm.Groups[5].Value
                total_s = [double]$mm.Groups[6].Value
                piece   = ''
                source  = 'disktui'
            })
        }
    }
    if ($tokenRows.Count -gt 0) {
        $p.per_token = @($tokenRows)
        $ioSum = 0.0
        $cmpSum = 0.0
        foreach ($row in $tokenRows) { $ioSum += $row.io_s; $cmpSum += $row.cmp_s }
        if ($null -eq $p.gen_io_s) { $p.gen_io_s = $ioSum }
        $p.gen_cmp_s = $cmpSum
    }

    # ---- per token samples (diskrun style: total step time only)
    $sampleRows = New-Object System.Collections.ArrayList
    $sMatches = [regex]::Matches($metricText, 'diskrun: token (\d+) id=(-?\d+) sample=([\d.]+) s')
    foreach ($mm in $sMatches) {
        [void]$sampleRows.Add([pscustomobject]@{
            index    = [int]$mm.Groups[1].Value
            token_id = [int]$mm.Groups[2].Value
            sample_s = [double]$mm.Groups[3].Value
        })
    }
    $p.per_token_samples = @($sampleRows)

    # ---- generation totals
    $m = [regex]::Match($metricText, 'diskrun: generated (\d+) tokens in ([\d.]+) s \(([\d.]+) s/token\)')
    if ($m.Success) {
        $p.tokens_generated = [int]$m.Groups[1].Value
        $p.gen_s            = [double]$m.Groups[2].Value
    }
    if ($null -eq $p.tokens_generated) {
        $m = [regex]::Match($metricText, 'gen (\d+) tok in ([\d.]+)s \(([\d.]+) s/tok\)\s+io ([\d.]+)s\s+rss (-?\d+) MiB')
        if ($m.Success) {
            $p.tokens_generated = [int]$m.Groups[1].Value
            $p.gen_s            = [double]$m.Groups[2].Value
            if ($null -eq $p.gen_io_s) { $p.gen_io_s = [double]$m.Groups[4].Value }
            if ([int]$m.Groups[5].Value -gt 0) { $p.rss_app_mib = [int]$m.Groups[5].Value }
        }
    }
    $m = [regex]::Match($metricText, 'diskrun: eog after (\d+) tokens')
    if ($m.Success -and $null -eq $p.tokens_generated) {
        $p.tokens_generated = [int]$m.Groups[1].Value
    }
    if ($null -eq $p.tokens_generated -and $sampleRows.Count -gt 0) {
        $maxIdx = 0
        foreach ($row in $sampleRows) { if ($row.index -gt $maxIdx) { $maxIdx = $row.index } }
        $p.tokens_generated = $maxIdx
    }
    if ($null -eq $p.tokens_generated -and $tokenRows.Count -gt 0) {
        $maxIdx = 0
        foreach ($row in $tokenRows) { if ($row.index -gt $maxIdx) { $maxIdx = $row.index } }
        $p.tokens_generated = $maxIdx
    }

    # ---- llama.cpp perf fallbacks (native runs)
    $m = [regex]::Match($metricText, 'prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens')
    if ($m.Success) {
        $p.llama_perf_prompt_ms  = [double]$m.Groups[1].Value
        $p.llama_perf_prompt_tok = [int]$m.Groups[2].Value
    }
    $m = [regex]::Match($metricText, 'eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*runs')
    if ($m.Success) {
        $p.llama_perf_eval_ms   = [double]$m.Groups[1].Value
        $p.llama_perf_eval_runs = [int]$m.Groups[2].Value
        if ($null -eq $p.tokens_generated) { $p.tokens_generated = [int]$m.Groups[2].Value }
    }
    $m = [regex]::Match($metricText, 'load time\s*=\s*([\d.]+)\s*ms')
    if ($m.Success) { $p.llama_perf_load_ms = [double]$m.Groups[1].Value }

    # ---- io/cmp totals
    $ioParts  = New-Object System.Collections.ArrayList
    $cmpParts = New-Object System.Collections.ArrayList
    if ($null -ne $p.prefill_io_s)  { [void]$ioParts.Add([double]$p.prefill_io_s) }
    if ($null -ne $p.prefill_cmp_s) { [void]$cmpParts.Add([double]$p.prefill_cmp_s) }
    if ($null -ne $p.gen_io_s)      { [void]$ioParts.Add([double]$p.gen_io_s) }
    if ($null -ne $p.gen_cmp_s)     { [void]$cmpParts.Add([double]$p.gen_cmp_s) }
    if ($ioParts.Count -gt 0) {
        $sum = 0.0
        foreach ($v in $ioParts) { $sum += [double]$v }
        $p.io_total_s = $sum
        $p.io_reported = $true
    }
    if ($cmpParts.Count -gt 0) {
        $sum = 0.0
        foreach ($v in $cmpParts) { $sum += [double]$v }
        $p.cmp_total_s = $sum
    }

    # ---- rss reported by the binaries
    $rssMatches = [regex]::Matches($metricText, 'rss\s*[=:]?\s*(-?\d+)\s*MiB')
    foreach ($mm in $rssMatches) {
        $v = [int]$mm.Groups[1].Value
        if ($v -gt 0 -and ($null -eq $p.rss_app_mib -or $v -gt $p.rss_app_mib)) {
            $p.rss_app_mib = $v
        }
    }

    # ---- answer line (disktui)
    $m = [regex]::Match($cleanLog, '(?m)^\s*answer:\s?(.*)$')
    if (-not $m.Success) {
        $m = [regex]::Match($Stdout, 'answer:[ \t]*([^\x1b\r\n]*)')
    }
    if (-not $m.Success) {
        $m = [regex]::Match($cleanOut, 'answer:[ \t]*([^\r\n]{0,400})')
    }
    if ($m.Success) {
        $answer = $m.Groups[1].Value.Trim()
        $p.answer_log = $answer
        if ($answer.Length -gt 0) { $p.answer_found = $true }
    }

    # ---- error and crash markers
    $errLines = New-Object System.Collections.ArrayList
    $errPattern = '(?i)\b(error|failed|failure|cannot|can not|unable|invalid|not found|no such file|missing)\b'
    foreach ($line in ($cleanAll -split "`n")) {
        if ($line -match $errPattern) {
            [void]$errLines.Add((Convert-ToAsciiText $line.Trim()))
            if ($errLines.Count -ge 8) { break }
        }
    }
    if ($errLines.Count -gt 0) {
        $p.has_error = $true
        $p.error_text = (@($errLines) -join ' | ')
    }

    $crashPattern = '(?i)(access violation|assertion failed|assert\(|terminate called|unhandled exception|stack overflow|segmentation fault|sigsegv|abort\(\)|0xC0000005|0xC0000409|fatal error)'
    $crashLines = New-Object System.Collections.ArrayList
    foreach ($line in ($cleanAll -split "`n")) {
        if ($line -match $crashPattern) {
            [void]$crashLines.Add((Convert-ToAsciiText $line.Trim()))
            if ($crashLines.Count -ge 5) { break }
        }
    }
    if ($crashLines.Count -gt 0) {
        $p.has_crash_marker = $true
        $p.crash_markers = @($crashLines)
    }

    return [pscustomobject]$p
}

# ---------------------------------------------------------------- text extraction
function Get-DiskrunGeneratedText {
    param([string]$Stdout)
    if ($null -eq $Stdout) { $Stdout = '' }
    $text = $Stdout.Replace("`r", '')
    if ($text.StartsWith($script:PromptText)) {
        $text = $text.Substring($script:PromptText.Length)
    }
    $trimmed = $text.TrimEnd()
    # drop a duplicated prompt echo at the very end (defensive)
    if ($trimmed.EndsWith($script:PromptText) -and $trimmed.Length -gt $script:PromptText.Length) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - $script:PromptText.Length).TrimEnd()
    }
    return $trimmed
}

function Get-DiskuiAnswerText {
    param([string]$Stdout, [string]$LogText)
    if ($null -eq $Stdout) { $Stdout = '' }
    if ($null -eq $LogText) { $LogText = '' }
    $cleanLog = Remove-AnsiEscapes $LogText
    $m = [regex]::Match($cleanLog, '(?m)^\s*answer:\s?(.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($Stdout, 'answer:[ \t]*([^\x1b\r\n]*)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $cleanOut = Remove-AnsiEscapes $Stdout
    $m = [regex]::Match($cleanOut, 'answer:[ \t]*([^\r\n]{0,400})')
    if ($m.Success) {
        $value = $m.Groups[1].Value
        foreach ($stopWord in @(' saved to ', '---- done ----', 'Q: ', 'A: ')) {
            $idx = $value.IndexOf($stopWord)
            if ($idx -ge 0) { $value = $value.Substring(0, $idx) }
        }
        return $value.Trim()
    }
    return ''
}

function Get-ReproCommand {
    param([string]$ExePath, [string[]]$ArgumentList, $EnvMap, [string]$StdInMode)
    $parts = New-Object System.Collections.ArrayList
    if ($EnvMap) {
        foreach ($k in @($EnvMap.Keys)) {
            $v = ([string]$EnvMap[$k]).Replace("'", "''")
            [void]$parts.Add(('$env:{0}=''{1}'';' -f $k, $v))
        }
    }
    $exeQuoted = "'" + $ExePath.Replace("'", "''") + "'"
    $argParts = New-Object System.Collections.ArrayList
    foreach ($a in @($ArgumentList)) {
        $s = [string]$a
        if ($s -match '\s') { [void]$argParts.Add("'" + $s.Replace("'", "''") + "'") }
        else { [void]$argParts.Add($s) }
    }
    $line = (@($parts) -join ' ')
    if ($line) { $line += ' ' }
    $line += ('& ' + $exeQuoted + ' ' + (@($argParts) -join ' '))
    if ($StdInMode -eq 'closed') { $line += ' < NUL' }
    return $line.Trim()
}

# ================================================================
# evaluation
# ================================================================

function New-CheckList {
    # the comma prevents PowerShell from enumerating the empty collection on return
    return ,(New-Object System.Collections.ArrayList)
}

function Add-Check {
    param($Checks, [string]$Name, [string]$Status, [string]$Detail)
    [void]$Checks.Add([pscustomobject]@{
        check  = $Name
        status = $Status
        detail = (Convert-ToAsciiText $Detail)
    })
}

function Compare-OutputText {
    param([string]$Left, [string]$Right)
    if ($null -eq $Left)  { $Left = '' }
    if ($null -eq $Right) { $Right = '' }
    if ($Left.Length -eq 0 -or $Right.Length -eq 0) {
        return [pscustomobject]@{
            compared = $false
            match    = $false
            detail   = ('cannot compare: left has {0} chars, right has {1} chars' -f $Left.Length, $Right.Length)
        }
    }
    if ($Left -ceq $Right) {
        return [pscustomobject]@{ compared = $true; match = $true; detail = 'identical text' }
    }
    $n = [Math]::Min($Left.Length, $Right.Length)
    $idx = -1
    for ($i = 0; $i -lt $n; $i++) {
        if ($Left[$i] -ne $Right[$i]) { $idx = $i; break }
    }
    if ($idx -lt 0) { $idx = $n }
    $start = [Math]::Max(0, $idx - 20)
    $lLen  = [Math]::Min(60, [Math]::Max(0, $Left.Length - $start))
    $rLen  = [Math]::Min(60, [Math]::Max(0, $Right.Length - $start))
    $lSnip = if ($lLen -gt 0) { Convert-ToAsciiText $Left.Substring($start, $lLen) } else { '' }
    $rSnip = if ($rLen -gt 0) { Convert-ToAsciiText $Right.Substring($start, $rLen) } else { '' }
    return [pscustomobject]@{
        compared   = $true
        match      = $false
        first_diff = $idx
        detail     = ('texts differ at char {0}: left_len={1} right_len={2}; left "{3}" vs right "{4}"' -f $idx, $Left.Length, $Right.Length, $lSnip, $rSnip)
    }
}

function Compare-TokenIds {
    param($Left, $Right)
    $L = @()
    $R = @()
    if ($null -ne $Left)  { $L = @($Left) }
    if ($null -ne $Right) { $R = @($Right) }
    if ($L.Count -eq 0 -or $R.Count -eq 0) {
        return [pscustomobject]@{
            compared = $false
            match    = $false
            detail   = ('cannot compare token ids: left has {0}, right has {1}' -f $L.Count, $R.Count)
        }
    }
    $n = [Math]::Min($L.Count, $R.Count)
    $firstDiff = -1
    for ($i = 0; $i -lt $n; $i++) {
        if ([int]$L[$i] -ne [int]$R[$i]) { $firstDiff = $i; break }
    }
    if ($firstDiff -lt 0 -and $L.Count -eq $R.Count) {
        return [pscustomobject]@{
            compared = $true
            match    = $true
            detail   = ('identical token ids ({0} tokens): {1}' -f $L.Count, (Format-IdList $L))
        }
    }
    if ($firstDiff -lt 0) { $firstDiff = $n }
    $leftIds  = ''
    $rightIds = ''
    if ($firstDiff -lt $L.Count)  { $leftIds  = [string]$L[$firstDiff] }  else { $leftIds  = '<end>' }
    if ($firstDiff -lt $R.Count)  { $rightIds = [string]$R[$firstDiff] }  else { $rightIds = '<end>' }
    return [pscustomobject]@{
        compared   = $true
        match      = $false
        first_diff = $firstDiff
        detail     = ('token ids differ at index {0}: left has {1} token(s) {2}, right has {3} token(s) {4}; left ids {5} vs right ids {6}' -f `
            $firstDiff, $L.Count, $leftIds, $R.Count, $rightIds, (Format-IdList $L), (Format-IdList $R))
    }
}

function Format-IdList {
    param($Ids, [int]$MaxItems = 16)
    $list = @()
    if ($null -ne $Ids) { $list = @($Ids) }
    if ($list.Count -eq 0) { return '(none)' }
    $shown = @()
    $limit = [Math]::Min($list.Count, $MaxItems)
    for ($i = 0; $i -lt $limit; $i++) { $shown += [string]$list[$i] }
    $text = ($shown -join ',')
    if ($list.Count -gt $MaxItems) { $text += ',...' }
    return $text
}

function Invoke-CaseEvaluation {
    param(
        $Definition,
        $Run,
        $Parsed,
        [string]$CaseDir,
        [int]$ExpectedAutoArenaMiB,
        [string]$ModelPath
    )

    $exp     = $Definition.expect
    $checks  = New-CheckList
    $issues  = New-CheckList

    # ---------------- reference/generated text extraction
    $generatedText = ''
    $answerText    = ''
    if ($Definition.exe_key -eq 'disktui') {
        $logPath = Join-Path $CaseDir 'disktui.log'
        $logText = Read-TextFileSafe -Path $logPath
        $answerText = Get-DiskuiAnswerText -Stdout $Run.stdout -LogText $logText
        $generatedText = $answerText
    }
    else {
        $generatedText = Get-DiskrunGeneratedText -Stdout $Run.stdout
    }

    # generated token ids (diskrun prints "diskrun: token %d id=%d sample=... s" per token;
    # this is the authoritative greedy-comparison key because stdout text can be ambiguous)
    $tokenIds = @()
    if (@($Parsed.per_token_samples).Count -gt 0) {
        $sortedSamples = @($Parsed.per_token_samples | Sort-Object -Property index)
        $tokenIds = @($sortedSamples | ForEach-Object { [int]$_.token_id })
    }

    $envMap = $Definition.env
    $command = Get-ReproCommand -ExePath $Run.exe_path -ArgumentList $Definition.args -EnvMap $envMap -StdInMode $Definition.stdin

    # ---------------- process start
    if ($Run.start_error) {
        Add-Check $checks 'process_start' 'FAIL' $Run.start_error
        $status = 'ERROR'
        return [pscustomobject]@{
            id = $Definition.id; name = $Definition.name; description = $Definition.description
            exe_key = $Definition.exe_key; exe_path = $Run.exe_path; command = $command
            env = $envMap; work_dir = $Run.work_dir; case_dir = $CaseDir
            status = $status; checks = @($checks); issues = @()
            duration_s = 0.0; exit_code = $null; exit_hex = ''; timed_out = $false
            start_error = $Run.start_error; capture_note = ''
            tokens = $null; model_load_s = $null; arena_mib = $null; arena_why = ''
            direct_io = $null; raised = $null; clamped = $null
            registered_tensors = $null; streamed_mib = $null
            largest_tensor = ''; largest_tensor_mib = $null
            io_total_s = $null; cmp_total_s = $null; io_reported = $false
            rss_os_peak_mib = $null; rss_os_max_mib = $null; private_peak_mib = $null
            rss_app_mib = $null; disk_read_mib = $null; cpu_s = $null
            generated_text = ''; answer_text = ''; text_source = 'none'
            generated_token_ids = @()
            stdout_file = ''; stderr_file = ''; extra_files = @()
            parsed = $Parsed
        }
    }
    Add-Check $checks 'process_start' 'PASS' ('started ' + (Split-Path -Leaf $Run.exe_path))

    # ---------------- timeout
    if ($Run.timed_out) {
        Add-Check $checks 'timeout' 'FAIL' ('process did not finish within the timeout and was killed: ' + $Run.capture_note)
    }
    else {
        Add-Check $checks 'timeout' 'PASS' ('finished in {0}s' -f (Format-Seconds $Run.duration_s))
    }

    # ---------------- exit code / crash
    $crashed = $false
    if ($Run.timed_out) {
        Add-Check $checks 'exit_code' 'SKIP' 'process was killed by the harness after the timeout, its exit code is not meaningful'
    }
    elseif ($null -eq $Run.exit_code) {
        Add-Check $checks 'exit_code' 'FAIL' 'no exit code could be captured'
    }
    else {
        $crashed = ($null -ne $Run.exit_u32 -and $Run.exit_u32 -ge [uint32]3221225472) # 0xC0000000
        if ($exp.exit -eq 'nonzero') {
            if ($Run.exit_code -ne 0) {
                Add-Check $checks 'exit_code' 'PASS' ('exit code {0} ({1}) as expected for the error path' -f $Run.exit_code, $Run.exit_hex)
            }
            else {
                Add-Check $checks 'exit_code' 'FAIL' 'exit code 0, but this case must fail with a nonzero exit code'
            }
        }
        else {
            if ($Run.exit_code -eq 0) {
                Add-Check $checks 'exit_code' 'PASS' 'exit code 0'
            }
            else {
                Add-Check $checks 'exit_code' 'FAIL' ('exit code {0} ({1}), expected 0' -f $Run.exit_code, $Run.exit_hex)
            }
        }
        if ($crashed) {
            Add-Check $checks 'crash_exit_code' 'FAIL' ('exit code {0} is a Windows exception/crash code, not a clean exit' -f $Run.exit_hex)
        }
    }

    # ---------------- streaming marker
    if ($exp.streaming -eq 'on') {
        if ($Parsed.streamed) {
            Add-Check $checks 'streaming_marker' 'PASS' ('"streaming weights from disk" line found: arena = {0} MiB ({1}), direct io = {2}, mlock = {3}, prefetch = {4}' -f $Parsed.arena_mib, $Parsed.arena_why, $Parsed.direct_io, $Parsed.mlock, $Parsed.prefetch)
        }
        elseif ($exp.allow_clean_failure -and $null -ne $Run.exit_code -and $Run.exit_code -ne 0) {
            Add-Check $checks 'streaming_marker' 'SKIP' 'clean-failure path: no arena line because loading failed (allowed for this case)'
        }
        else {
            Add-Check $checks 'streaming_marker' 'FAIL' 'expected a "llama-disk: streaming weights from disk, arena = ..." line, none found'
        }
    }
    elseif ($exp.streaming -eq 'off') {
        if ($Parsed.streamed) {
            Add-Check $checks 'streaming_marker' 'FAIL' ('streaming arena line found although LLAMA_DISK_STREAM_MB=0: ' + $Parsed.arena_why)
        }
        else {
            Add-Check $checks 'streaming_marker' 'PASS' 'no disk-streaming arena line (native path)'
        }
    }
    else {
        if ($Parsed.streamed) {
            Add-Check $checks 'streaming_marker' 'INFO' ('arena = {0} MiB ({1})' -f $Parsed.arena_mib, $Parsed.arena_why)
        }
        else {
            Add-Check $checks 'streaming_marker' 'INFO' 'no disk-streaming arena line (acceptable for this case)'
        }
    }

    # ---------------- arena sizing
    $largestNeed = $null
    if ($null -ne $Parsed.largest_tensor_mib) { $largestNeed = [int]$Parsed.largest_tensor_mib + 24 }
    if ($null -ne $exp.arena_requested -and $Parsed.streamed) {
        $requested = [int]$exp.arena_requested
        $arena     = $Parsed.arena_mib
        if ($exp.require_raise) {
            if ($null -ne $Parsed.raised) {
                $okFrom = ($Parsed.raised.from -eq $requested)
                $okSize = ($null -eq $largestNeed) -or ($arena -ge $largestNeed)
                if ($okFrom -and $okSize) {
                    Add-Check $checks 'arena_raise' 'PASS' ('requested {0} MiB cannot hold largest tensor, raised to {1} MiB (largest tensor {2} = {3} MiB)' -f $Parsed.raised.from, $Parsed.raised.to, $Parsed.raised.tensor, $Parsed.raised.tensor_mib)
                }
                elseif (-not $okFrom) {
                    Add-Check $checks 'arena_raise' 'FAIL' ('raise message starts from {0} MiB, expected {1} MiB' -f $Parsed.raised.from, $requested)
                }
                else {
                    Add-Check $checks 'arena_raise' 'FAIL' ('arena after raise = {0} MiB but largest tensor + 24 MiB = {1} MiB' -f $arena, $largestNeed)
                }
            }
            elseif ($null -ne $largestNeed -and $arena -lt $largestNeed) {
                Add-Check $checks 'arena_raise' 'FAIL' ('arena = {0} MiB is smaller than largest tensor + 24 MiB ({1} MiB) and no raise message was logged' -f $arena, $largestNeed)
            }
            else {
                Add-Check $checks 'arena_raise' 'PASS' ('no raise needed: arena {0} MiB already covers largest tensor + 24 MiB' -f $arena)
            }
            if ($null -ne $largestNeed -and $null -ne $arena -and $arena -lt $largestNeed) {
                Add-Check $checks 'arena_minimum' 'FAIL' ('arena {0} MiB < largest tensor + 24 MiB ({1} MiB)' -f $arena, $largestNeed)
            }
        }
        else {
            if ($arena -eq $requested) {
                Add-Check $checks 'arena_size' 'PASS' ('arena = requested {0} MiB' -f $requested)
            }
            else {
                Add-Check $checks 'arena_size' 'FAIL' ('arena = {0} MiB, expected {1} MiB' -f $arena, $requested)
            }
        }
    }
    if ($exp.arena_auto -and $Parsed.streamed) {
        if ($null -ne $Parsed.clamped) {
            Add-Check $checks 'arena_auto' 'WARN' ('auto arena clamped to {0} MiB (only {1} MiB free), expected {2} MiB' -f $Parsed.clamped.to, $Parsed.clamped.free_mib, $ExpectedAutoArenaMiB)
        }
        elseif ($null -ne $Parsed.raised) {
            Add-Check $checks 'arena_auto' 'FAIL' ('auto arena was raised from {0} to {1} MiB; auto sizing should be larger than the largest tensor' -f $Parsed.raised.from, $Parsed.raised.to)
        }
        elseif ($Parsed.arena_mib -eq $ExpectedAutoArenaMiB) {
            Add-Check $checks 'arena_auto' 'PASS' ('auto arena = {0} MiB = min(RAM/8, 2048)' -f $Parsed.arena_mib)
        }
        else {
            Add-Check $checks 'arena_auto' 'FAIL' ('auto arena = {0} MiB, expected {1} MiB = min(RAM/8, 2048); check the Windows memory query' -f $Parsed.arena_mib, $ExpectedAutoArenaMiB)
        }
    }
    if ($null -ne $Parsed.clamped) {
        Add-Check $checks 'arena_clamped' 'INFO' ('arena clamped from {0} to {1} MiB (free {2} MiB)' -f $Parsed.clamped.from, $Parsed.clamped.to, $Parsed.clamped.free_mib)
    }

    # ---------------- tensor registration (one model load -> expected tensor count)
    if ($null -ne $exp.expected_tensors -and $Parsed.streamed) {
        $expectedTensors = [int]$exp.expected_tensors
        if ($null -eq $Parsed.registered_tensors) {
            Add-Check $checks 'tensors_registered' 'WARN' ('no "N tensors registered" line found (expected {0} for a single model load)' -f $expectedTensors)
        }
        elseif ([int]$Parsed.registered_tensors -eq $expectedTensors) {
            Add-Check $checks 'tensors_registered' 'PASS' ('{0} tensors registered, {1} MiB to stream (single model load)' -f $Parsed.registered_tensors, $Parsed.registered_mib)
        }
        elseif ([int]$Parsed.registered_tensors -eq (2 * $expectedTensors)) {
            Add-Check $checks 'tensors_registered' 'FAIL' ('{0} tensors registered, expected {1}: the model appears to be registered twice (double registration bug)' -f $Parsed.registered_tensors, $expectedTensors)
        }
        else {
            Add-Check $checks 'tensors_registered' 'WARN' ('{0} tensors registered, expected {1} for this model; check for duplicate/partial registration' -f $Parsed.registered_tensors, $expectedTensors)
        }
    }

    # ---------------- token count
    $skipForCleanFailure = ($exp.allow_clean_failure -and $null -ne $Run.exit_code -and $Run.exit_code -ne 0)
    if (-not $skipForCleanFailure -and ($null -ne $exp.tokens_min -or $null -ne $exp.tokens_max)) {
        if ($null -eq $Parsed.tokens_generated) {
            if ($Run.exit_code -eq 0) {
                Add-Check $checks 'tokens_generated' 'WARN' 'could not determine the generated token count from the logs'
            }
            else {
                Add-Check $checks 'tokens_generated' 'SKIP' 'no token count because the run failed'
            }
        }
        else {
            $tok = [int]$Parsed.tokens_generated
            $minOk = ($null -eq $exp.tokens_min) -or ($tok -ge [int]$exp.tokens_min)
            $maxOk = ($null -eq $exp.tokens_max) -or ($tok -le [int]$exp.tokens_max)
            if ($minOk -and $maxOk) {
                Add-Check $checks 'tokens_generated' 'PASS' ('generated {0} token(s)' -f $tok)
            }
            elseif (-not $minOk) {
                Add-Check $checks 'tokens_generated' 'FAIL' ('generated {0} token(s), expected at least {1}' -f $tok, $exp.tokens_min)
            }
            else {
                Add-Check $checks 'tokens_generated' 'FAIL' ('generated {0} token(s), expected at most {1}' -f $tok, $exp.tokens_max)
            }
        }
    }

    # ---------------- model load time
    if ($null -ne $Parsed.model_load_s) {
        Add-Check $checks 'model_load_time' 'INFO' ('model load time {0} s' -f (Format-Seconds $Parsed.model_load_s))
    }
    elseif ($Run.exit_code -eq 0) {
        Add-Check $checks 'model_load_time' 'WARN' 'no model load time found in the logs (expected "model loaded in X s" or "[ X s] model ready")'
    }

    # ---------------- answer / generated text
    if ($exp.require_answer) {
        if ($generatedText.Length -gt 0) {
            $snippet = Convert-ToAsciiText $generatedText
            if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0, 200) + '...' }
            Add-Check $checks 'answer_text' 'PASS' ('generated text ({0} chars): "{1}"' -f $generatedText.Length, ($snippet -replace "`n", '\n'))
        }
        else {
            Add-Check $checks 'answer_text' 'FAIL' 'no generated/answer text could be extracted'
        }
    }
    if ($Definition.exe_key -eq 'disktui') {
        if ($Parsed.answer_found) {
            Add-Check $checks 'answer_line' 'PASS' ('TUI log contains "answer:" line: "{0}"' -f (Convert-ToAsciiText $answerText))
        }
        else {
            Add-Check $checks 'answer_line' 'FAIL' 'TUI output does not contain an "answer:" line'
        }
        $tuiLogPath = Join-Path $CaseDir 'disktui.log'
        if (Test-Path -LiteralPath $tuiLogPath -PathType Leaf) {
            Add-Check $checks 'tui_log_file' 'INFO' 'LLAMA_DISK_LOG file was written by the TUI'
        }
        else {
            Add-Check $checks 'tui_log_file' 'WARN' 'LLAMA_DISK_LOG file was not written; the TUI may ignore the env override on Windows'
        }
    }

    # ---------------- RSS bound
    if ($null -ne $exp.max_rss_mib) {
        $rss = $null
        if ($null -ne $Run.rss_os_peak_mib) { $rss = [double]$Run.rss_os_peak_mib }
        elseif ($null -ne $Parsed.rss_app_mib) { $rss = [double]$Parsed.rss_app_mib }
        if ($null -eq $rss) {
            Add-Check $checks 'rss_bound' 'WARN' 'RSS could not be measured (no samples and no rss line in the log)'
        }
        elseif ($rss -le [double]$exp.max_rss_mib) {
            Add-Check $checks 'rss_bound' 'PASS' ('peak RSS {0} MiB <= {1} MiB' -f (Format-Mib $rss), $exp.max_rss_mib)
        }
        else {
            Add-Check $checks 'rss_bound' 'FAIL' ('peak RSS {0} MiB > {1} MiB; streaming should keep memory bounded' -f (Format-Mib $rss), $exp.max_rss_mib)
        }
    }

    # ---------------- direct io flag
    if ($null -ne $exp.direct_io -and $Parsed.streamed) {
        $want = [int]$exp.direct_io
        if ($null -eq $Parsed.direct_io) {
            Add-Check $checks 'direct_io' 'WARN' 'no "direct io = N" flag in the arena line'
        }
        elseif ($Parsed.direct_io -eq $want) {
            Add-Check $checks 'direct_io' 'PASS' ('direct io = {0} as expected' -f $Parsed.direct_io)
        }
        elseif ($Parsed.odirect_fallback) {
            Add-Check $checks 'direct_io' 'WARN' ('direct io = {0}, expected {1}; the binary logged an O_DIRECT fallback (streaming still works, io timing is page-cache assisted)' -f $Parsed.direct_io, $want)
        }
        else {
            Add-Check $checks 'direct_io' 'FAIL' ('direct io = {0}, expected {1}; LLAMA_DISK_ODIRECT appears not to be honored' -f $Parsed.direct_io, $want)
        }
    }

    # ---------------- independent disk-read evidence
    if ($exp.require_disk_read -and $Parsed.streamed -and $Run.exit_code -eq 0) {
        if ($script:ProcIoAvailable -and $null -ne $Run.disk_read_mib) {
            $readMib = [double]$Run.disk_read_mib
            if ($readMib -ge 300) {
                Add-Check $checks 'disk_read_evidence' 'PASS' ('process I/O counters show {0} MiB read from disk while running' -f (Format-Mib $readMib))
            }
            else {
                Add-Check $checks 'disk_read_evidence' 'FAIL' ('process I/O counters show only {0} MiB read; streaming may not be engaged' -f (Format-Mib $readMib))
            }
        }
        else {
            Add-Check $checks 'disk_read_evidence' 'INFO' 'process I/O counters unavailable, cannot independently confirm disk reads'
        }
    }

    # ---------------- io timing availability
    if ($exp.streaming -eq 'on' -and $Parsed.streamed) {
        if ($Parsed.io_reported -and $null -ne $Parsed.io_total_s) {
            if ([double]$Parsed.io_total_s -gt 0.2) {
                Add-Check $checks 'io_time' 'PASS' ('total io time {0} s (cmp {1} s)' -f (Format-Seconds $Parsed.io_total_s), (Format-Seconds $Parsed.cmp_total_s))
            }
            else {
                Add-Check $checks 'io_time' 'WARN' ('io time only {0} s; expected non-trivial disk read time' -f (Format-Seconds $Parsed.io_total_s))
            }
        }
        else {
            Add-Check $checks 'io_time' 'INFO' 'this binary does not log per-token io/cmp seconds; only wall time is available'
        }
    }

    # ---------------- crash markers in output
    if ($Parsed.has_crash_marker) {
        $firstMarker = ''
        if ($Parsed.crash_markers.Count -gt 0) { $firstMarker = $Parsed.crash_markers[0] }
        if ($Definition.id -eq 'case6') {
            Add-Check $checks 'crash_markers' 'FAIL' ('crash/abort text in output: ' + $firstMarker)
        }
        else {
            Add-Check $checks 'crash_markers' 'WARN' ('crash/abort text in output: ' + $firstMarker)
        }
    }

    # ---------------- case specific behaviour
    switch ($Definition.id) {
        'case6' {
            if ($null -ne $Run.exit_code -and $Run.exit_code -ne 0 -and -not $Run.timed_out) {
                Add-Check $checks 'clean_nonzero_exit' 'PASS' ('clean nonzero exit code {0}' -f $Run.exit_code)
            }
            if ($Parsed.has_error) {
                Add-Check $checks 'error_message' 'PASS' ('error output: ' + $Parsed.error_text)
            }
            else {
                Add-Check $checks 'error_message' 'FAIL' 'no error/failure message found in stdout/stderr'
            }
            if ($Run.duration_s -le 120) {
                Add-Check $checks 'fails_fast' 'PASS' ('exited in {0} s' -f (Format-Seconds $Run.duration_s))
            }
            else {
                Add-Check $checks 'fails_fast' 'FAIL' ('took {0} s before exiting; a clean error should be immediate' -f (Format-Seconds $Run.duration_s))
            }
        }
        'case7' {
            if ($Run.exit_code -eq 0) {
                if ($null -ne $Parsed.raised -and $Parsed.raised.from -eq 32) {
                    Add-Check $checks 'tiny_arena_raised' 'PASS' ('arena raised from 32 to {0} MiB (largest tensor {1} = {2} MiB)' -f $Parsed.raised.to, $Parsed.raised.tensor, $Parsed.raised.tensor_mib)
                }
                elseif ($null -ne $Parsed.streamed) {
                    Add-Check $checks 'tiny_arena_raised' 'FAIL' ('run succeeded with a 32 MiB arena request but no "raised to fit the largest tensor" message (arena = {0} MiB)' -f $Parsed.arena_mib)
                }
                else {
                    Add-Check $checks 'tiny_arena_raised' 'FAIL' 'run succeeded but neither a raised-arena message nor an arena line was found'
                }
            }
            elseif (-not $Run.timed_out) {
                Add-Check $checks 'tiny_arena_raised' 'FAIL' ('expected the 32 MiB arena to be auto-raised and the run to succeed, but the process failed with exit code {0}: {1}' -f $Run.exit_code, $Parsed.error_text)
            }
        }
    }

    # ---------------- derive status
    $failCount = 0
    $warnCount = 0
    foreach ($c in $checks) {
        if ($c.status -eq 'FAIL') { $failCount++ }
        elseif ($c.status -eq 'WARN') { $warnCount++ }
    }
    if ($Run.start_error)      { $status = 'ERROR' }
    elseif ($Run.timed_out)    { $status = 'TIMEOUT' }
    elseif ($failCount -gt 0)  { $status = 'FAIL' }
    elseif ($warnCount -gt 0)  { $status = 'WARN' }
    else                       { $status = 'PASS' }

    foreach ($c in $checks) {
        if ($c.status -eq 'FAIL' -or $c.status -eq 'WARN') {
            [void]$issues.Add([pscustomobject]@{
                severity = $(if ($c.status -eq 'FAIL') { 'HIGH' } else { 'LOW' })
                case_id  = $Definition.id
                case_name = $Definition.name
                check    = $c.check
                message  = $c.detail
                repro    = $command
                case_dir = $CaseDir
            })
        }
    }

    $textSource = 'none'
    if ($generatedText.Length -gt 0) { $textSource = if ($Definition.exe_key -eq 'disktui') { 'tui-answer-line' } else { 'diskrun-stdout-after-prompt' } }

    $extraFiles = @()
    try {
        $extraFiles = @(Get-ChildItem -LiteralPath $CaseDir -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    }
    catch { }

    return [pscustomobject]@{
        id = $Definition.id; name = $Definition.name; description = $Definition.description
        exe_key = $Definition.exe_key; exe_path = $Run.exe_path; command = $command
        env = $envMap; work_dir = $Run.work_dir; case_dir = $CaseDir
        status = $status; checks = @($checks); issues = @($issues)
        duration_s = [double]$Run.duration_s; exit_code = $Run.exit_code; exit_hex = $Run.exit_hex
        timed_out = $Run.timed_out; start_error = $Run.start_error; capture_note = $Run.capture_note
        tokens = $Parsed.tokens_generated; model_load_s = $Parsed.model_load_s
        arena_mib = $Parsed.arena_mib; arena_why = $Parsed.arena_why
        direct_io = $Parsed.direct_io; raised = $Parsed.raised; clamped = $Parsed.clamped
        registered_tensors = $Parsed.registered_tensors; streamed_mib = $Parsed.registered_mib
        largest_tensor = $Parsed.largest_tensor; largest_tensor_mib = $Parsed.largest_tensor_mib
        io_total_s = $Parsed.io_total_s; cmp_total_s = $Parsed.cmp_total_s; io_reported = $Parsed.io_reported
        prefill_io_s = $Parsed.prefill_io_s; gen_io_s = $Parsed.gen_io_s
        rss_os_peak_mib = $Run.rss_os_peak_mib; rss_os_max_mib = $Run.rss_os_max_mib
        private_peak_mib = $Run.private_peak_mib; rss_app_mib = $Parsed.rss_app_mib
        disk_read_mib = $Run.disk_read_mib; cpu_s = $Run.cpu_s
        generated_text = $generatedText; answer_text = $answerText; text_source = $textSource
        generated_token_ids = @($tokenIds)
        stdout_file = $Run.stdout_file; stderr_file = $Run.stderr_file; extra_files = $extraFiles
        parsed = $Parsed
    }
}

# ================================================================
# per-case driver
# ================================================================

function Invoke-OneTestCase {
    param(
        $Definition,
        $BinInfo,
        [string]$RunDir,
        [int]$PollMs,
        [int]$TimeoutSec
    )

    $caseDir = Join-Path $RunDir ($Definition.id + '-' + $Definition.name)
    if (-not (Test-Path -LiteralPath $caseDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
    }

    $exePath = $null
    if ($BinInfo.resolved.Contains($Definition.exe_key)) { $exePath = $BinInfo.resolved[$Definition.exe_key] }

    $envMap = [ordered]@{}
    foreach ($k in @($Definition.env.Keys)) { $envMap[[string]$k] = [string]$Definition.env[$k] }
    if ($Definition.add_log_env) {
        $envMap['LLAMA_DISK_LOG'] = (Join-Path $caseDir 'disktui.log')
    }
    if ($Definition.add_home_env) {
        $envMap['HOME'] = $caseDir
        $envMap['USERPROFILE'] = $caseDir
    }

    if ([string]::IsNullOrWhiteSpace($exePath)) {
        $tried = @()
        if ($BinInfo.searched.Contains($Definition.exe_key)) { $tried = @($BinInfo.searched[$Definition.exe_key]) }
        $run = New-EmptyRun -Message ('binary ''' + $Definition.exe_key + ''' not found. Searched: ' + ($tried -join '; '))
        $run.exe_key = $Definition.exe_key
    }
    else {
        $timeout = $TimeoutSec
        if ($Definition.timeout_sec -gt 0) { $timeout = [int]$Definition.timeout_sec }
        $workDir = Split-Path -Parent $exePath
        $run = Invoke-TestProcess -ExePath $exePath -ArgumentList $Definition.args -EnvMap $envMap `
            -WorkDir $workDir -TimeoutSec $timeout -CaseDir $caseDir -PollMs $PollMs -ExeKey $Definition.exe_key
    }

    $extraLog = Read-TextFileSafe -Path (Join-Path $caseDir 'disktui.log')
    $parsed = Parse-ChildOutput -Stdout $run.stdout -Stderr $run.stderr -ExtraLog $extraLog
    $result = Invoke-CaseEvaluation -Definition $Definition -Run $run -Parsed $parsed -CaseDir $caseDir `
        -ExpectedAutoArenaMiB $script:ExpectedAutoArenaMiB -ModelPath $Model

    # the real per-child environment (includes the harness-added log/home overrides)
    $result.env = $envMap
    $result.command = Get-ReproCommand -ExePath $run.exe_path -ArgumentList $Definition.args -EnvMap $envMap -StdInMode $Definition.stdin

    $meta = [ordered]@{
        run_id       = $script:CurrentRunId
        case_id      = $result.id
        name         = $result.name
        description  = $result.description
        exe_key      = $result.exe_key
        exe_path     = $result.exe_path
        command      = $result.command
        env          = $result.env
        work_dir     = $result.work_dir
        status       = $result.status
        exit_code    = $result.exit_code
        exit_hex     = $result.exit_hex
        duration_s   = $result.duration_s
        timed_out    = $result.timed_out
        start_error  = $result.start_error
        capture_note = $result.capture_note
        stdout_file  = $result.stdout_file
        stderr_file  = $result.stderr_file
        extra_files  = $result.extra_files
        metrics      = [ordered]@{
            tokens           = $result.tokens
            token_ids        = @($result.generated_token_ids)
            model_load_s     = $result.model_load_s
            arena_mib        = $result.arena_mib
            arena_why        = $result.arena_why
            direct_io        = $result.direct_io
            io_total_s       = $result.io_total_s
            cmp_total_s      = $result.cmp_total_s
            rss_os_peak_mib  = $result.rss_os_peak_mib
            rss_app_mib      = $result.rss_app_mib
            disk_read_mib    = $result.disk_read_mib
            cpu_s            = $result.cpu_s
        }
        generated_text = $result.generated_text
        checks       = $result.checks
        parsed       = $result.parsed
    }
    try {
        Write-Utf8File -Path (Join-Path $caseDir 'meta.json') -Text ($meta | ConvertTo-Json -Depth 12)
    }
    catch { }
    return $result
}

# ================================================================
# reporting helpers
# ================================================================

function Format-EnvMapText {
    param($EnvMap)
    if ($null -eq $EnvMap -or $EnvMap.Count -eq 0) { return '(none)' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($k in @($EnvMap.Keys)) {
        [void]$parts.Add(('{0}={1}' -f $k, [string]$EnvMap[$k]))
    }
    return (@($parts) -join '; ')
}

function Format-StatusCounts {
    param($Overall)
    return ('PASS {0}, WARN {1}, FAIL {2}, TIMEOUT {3}, ERROR {4}, SKIP {5}' -f `
        $Overall.counts.PASS, $Overall.counts.WARN, $Overall.counts.FAIL, `
        $Overall.counts.TIMEOUT, $Overall.counts.ERROR, $Overall.counts.SKIP)
}

function Format-MdCell {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = Convert-ToAsciiText ([string]$Value)
    $s = $s.Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ')
    if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
    return $s
}

function Write-SummaryJson {
    param([string]$Path, $Payload)
    $json = $Payload | ConvertTo-Json -Depth 14
    Write-Utf8File -Path $Path -Text $json
}

function Write-SummaryMarkdown {
    param([string]$Path, $Payload)

    $lines = New-Object System.Collections.ArrayList
    function Add-Line {
        param([string]$Text)
        [void]$lines.Add([string]$Text)
    }
    function Add-Row {
        param([object[]]$Cells)
        $cellTexts = @()
        foreach ($c in $Cells) { $cellTexts += (Format-MdCell $c) }
        Add-Line ('| ' + ($cellTexts -join ' | ') + ' |')
    }

    Add-Line ('# diskinfer Windows port - verification run ' + $Payload.run_id)
    Add-Line ''
    Add-Line ('Generated: ' + $Payload.generated_at)
    Add-Line ''
    Add-Line ('## Overall verdict: ' + $Payload.overall.status)
    Add-Line ''
    Add-Line ('- Case results: ' + (Format-StatusCounts $Payload.overall))
    Add-Line ('- Required cross-case greedy check: ' + $Payload.cross_case.required_verdict)
    Add-Line ('- Cases executed: ' + (@($Payload.cases | ForEach-Object { $_.id }) -join ', '))
    Add-Line ''

    Add-Line '## Environment'
    Add-Line ''
    Add-Line '| Item | Value |'
    Add-Line '| --- | --- |'
    Add-Row @('OS', ($Payload.machine.os_caption + ' ' + $Payload.machine.os_version + ' build ' + $Payload.machine.os_build))
    Add-Row @('CPU', ($Payload.machine.cpu_name + ' (' + $Payload.machine.physical_cores + ' cores / ' + $Payload.machine.logical_cores + ' threads)'))
    Add-Row @('RAM', ($Payload.machine.total_ram_mib.ToString() + ' MiB total, ' + $Payload.machine.free_ram_mib.ToString() + ' MiB free at start'))
    Add-Row @('PowerShell', $Payload.machine.powershell_version)
    Add-Row @('Machine', $Payload.machine.computer_name)
    Add-Line ''

    Add-Line '## Model'
    Add-Line ''
    Add-Line '| Item | Value |'
    Add-Line '| --- | --- |'
    Add-Row @('Path', $Payload.model.path)
    Add-Row @('Size', ($Payload.model.length.ToString() + ' bytes'))
    Add-Row @('Last write', $Payload.model.last_write)
    if ($Payload.model.sha256) { Add-Row @('SHA256', $Payload.model.sha256) }
    Add-Row @('Policy check', $(if ($Payload.model.policy_ok) { 'allowed model' } else { 'unlisted model (override)' }))
    Add-Line ''

    Add-Line '## Binaries'
    Add-Line ''
    Add-Line ('Search order: ' + (@($Payload.binaries.search_dirs) -join ' ; '))
    Add-Line ''
    Add-Line '| Key | Path | Size | Last write | SHA256 (16) | Sibling DLLs | Stale DLLs |'
    Add-Line '| --- | --- | --- | --- | --- | --- | --- |'
    foreach ($b in @($Payload.binaries.exes)) {
        if ($b.exists) {
            Add-Row @($b.key, $b.path, $b.length, $b.last_write, $b.sha256_16, (@($b.sibling_dlls).Count), $b.stale_dll_count)
        }
        else {
            Add-Row @($b.key, 'NOT FOUND', '', '', '', '', '')
        }
    }
    Add-Line ''

    Add-Line '## Results table'
    Add-Line ''
    Add-Line '| Case | Name | Exe | Env | Exit | Tokens | Token IDs | Arena MiB | Direct IO | Load s | io s | cmp s | RSS MiB | Disk read MiB | Wall s | Status |'
    Add-Line '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    foreach ($c in @($Payload.cases)) {
        $rss = ''
        if ($null -ne $c.rss_os_peak_mib) { $rss = Format-Mib $c.rss_os_peak_mib }
        elseif ($null -ne $c.rss_app_mib) { $rss = [string]$c.rss_app_mib + ' (app)' }
        $idList = Format-IdList $c.generated_token_ids
        Add-Row @(
            $c.id, $c.name, $c.exe_key, (Format-EnvMapText $c.env), $c.exit_code, $c.tokens,
            $idList, $c.arena_mib, $c.direct_io, (Format-Seconds $c.model_load_s),
            (Format-Seconds $c.io_total_s), (Format-Seconds $c.cmp_total_s), $rss,
            (Format-Mib $c.disk_read_mib), (Format-Seconds $c.duration_s), $c.status
        )
    }
    Add-Line ''

    Add-Line '## Per-case details'
    Add-Line ''
    foreach ($c in @($Payload.cases)) {
        Add-Line ('### ' + $c.id + ' ' + $c.name + ' - ' + $c.status)
        Add-Line ''
        Add-Line ('- exe: ' + $c.exe_path)
        Add-Line ('- env: ' + (Format-EnvMapText $c.env))
        Add-Line ('- repro: `' + $c.command + '`')
        Add-Line ('- wall time: ' + (Format-Seconds $c.duration_s) + ' s; exit code: ' + $(if ($null -ne $c.exit_code) { [string]$c.exit_code + ' (' + $c.exit_hex + ')' } else { 'n/a' }) + '; tokens: ' + $(if ($null -ne $c.tokens) { [string]$c.tokens } else { 'n/a' }))
        if ($null -ne $c.arena_mib) {
            $raiseText = ''
            if ($null -ne $c.raised) { $raiseText = ('; raised from {0} to {1} MiB for largest tensor {2} ({3} MiB)' -f $c.raised.from, $c.raised.to, $c.raised.tensor, $c.raised.tensor_mib) }
            Add-Line ('- arena: ' + $c.arena_mib + ' MiB (' + $c.arena_why + ')' + $raiseText)
        }
        if ($null -ne $c.largest_tensor_mib) {
            Add-Line ('- register: largest tensor ''' + $c.largest_tensor + ''' ' + $c.largest_tensor_mib + ' MiB; streamed tensors ' + $c.registered_tensors + ', ' + $c.streamed_mib + ' MiB')
        }
        if ($null -ne $c.io_total_s) {
            Add-Line ('- io/cmp: total io ' + (Format-Seconds $c.io_total_s) + ' s, total cmp ' + (Format-Seconds $c.cmp_total_s) + ' s')
        }
        else {
            Add-Line '- io/cmp: not reported by this binary'
        }
        Add-Line ('- rss: os peak ' + (Format-Mib $c.rss_os_peak_mib) + ' MiB, app rss ' + $(if ($null -ne $c.rss_app_mib) { [string]$c.rss_app_mib } else { 'n/a' }) + ' MiB, private peak ' + (Format-Mib $c.private_peak_mib) + ' MiB')
        Add-Line ('- process io: ' + (Format-Mib $c.disk_read_mib) + ' MiB read; cpu ' + (Format-Seconds $c.cpu_s) + ' s')
        if ($c.generated_text) {
            $text = Convert-ToAsciiText $c.generated_text
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
            Add-Line ('- generated text (' + $c.text_source + '): `' + ($text -replace "`n", '\n') + '`')
        }
        if (@($c.generated_token_ids).Count -gt 0) {
            Add-Line ('- greedy token ids (' + @($c.generated_token_ids).Count + '): ' + (Format-IdList $c.generated_token_ids 24))
        }
        Add-Line ''
        Add-Line '| Check | Status | Detail |'
        Add-Line '| --- | --- | --- |'
        foreach ($chk in @($c.checks)) { Add-Row @($chk.check, $chk.status, $chk.detail) }
        Add-Line ''
        Add-Line ('Logs: `' + $c.stdout_file + '` , `' + $c.stderr_file + '`')
        Add-Line ''
    }

    Add-Line '## Cross-case greedy comparison'
    Add-Line ''
    if (@($Payload.cross_checks).Count -eq 0) {
        Add-Line 'No cross-case comparison was possible (no generated text/token ids on both sides).'
    }
    else {
        Add-Line 'Token ids are the authoritative check: diskrun prints "diskrun: token N id=X" for every greedy token. Text is a secondary check.'
        Add-Line ''
        Add-Line '| Pair | Required | Token IDs A | Token IDs B | Token IDs result | Text result | Result | Detail |'
        Add-Line '| --- | --- | --- | --- | --- | --- | --- | --- |'
        foreach ($x in @($Payload.cross_checks)) {
            Add-Row @($x.label, $x.required, $x.token_ids_a, $x.token_ids_b, $x.id_result, $x.text_result, $x.result, $x.detail)
        }
        Add-Line ''
        Add-Line ('Required verdict: ' + $Payload.cross_case.required_verdict)
    }
    Add-Line ''

    Add-Line '## Issues and defects'
    Add-Line ''
    if (@($Payload.issues).Count -eq 0) {
        Add-Line 'No issues were recorded.'
    }
    else {
        $n = 0
        foreach ($i in @($Payload.issues)) {
            $n++
            Add-Line ('### ' + $n + '. [' + $i.severity + '] ' + $i.case_id + ' ' + $i.case_name + ' - ' + $i.check)
            Add-Line ''
            Add-Line ('- ' + $i.message)
            Add-Line ('- repro: `' + $i.repro + '`')
            Add-Line ('- logs: `' + $i.case_dir + '`')
            Add-Line ''
        }
    }

    Add-Line '## Evidence excerpts'
    Add-Line ''
    foreach ($c in @($Payload.cases)) {
        if ($c.status -eq 'PASS') { continue }
        Add-Line ('### ' + $c.id + ' ' + $c.name + ' (' + $c.status + ')')
        Add-Line ''
        $arenaMatches = @(Find-TextMatches -Paths @($c.stderr_file, $c.stdout_file) -Pattern 'llama-disk:' -MaxMatches 8)
        if ($arenaMatches.Count -gt 0) {
            Add-Line 'llama-disk lines:'
            Add-Line '```'
            foreach ($line in $arenaMatches) { Add-Line $line }
            Add-Line '```'
            Add-Line ''
        }
        $tail = @(Get-TextTailExcerpt -Path $c.stderr_file -Count 12)
        if ($tail.Count -gt 0) {
            Add-Line 'stderr tail:'
            Add-Line '```'
            foreach ($line in $tail) { Add-Line $line }
            Add-Line '```'
            Add-Line ''
        }
    }

    Add-Line '## Notes and caveats'
    Add-Line ''
    foreach ($note in @($Payload.notes)) { Add-Line ('- ' + $note) }
    Add-Line ''

    Write-Utf8File -Path $Path -Text ((@($lines)) -join "`r`n")
}

# ================================================================
# main
# ================================================================
Initialize-ProcIoCouners

$runStart = Get-Date
$runId = 'run-' + $runStart.ToString('yyyyMMdd-HHmmss')
$script:CurrentRunId = $runId

Write-Step '============================================================'
Write-Step ' diskinfer Windows port - verification harness'
Write-Step '============================================================'

$machine = Get-MachineInfo
$modelInfo = Get-ModelInfo -Path $Model -AllowUnlisted:$AllowUnlistedModel -Hash:$HashModel

Write-Step ('Run id  : ' + $runId)
Write-Step ('Host    : ' + $machine.computer_name + ' | ' + $machine.os_caption + ' ' + $machine.os_version + ' build ' + $machine.os_build)
Write-Step ('CPU     : ' + $machine.cpu_name + ' (' + $machine.logical_cores + ' threads)')
Write-Step ('RAM     : ' + $machine.total_ram_mib + ' MiB total, ' + $machine.free_ram_mib + ' MiB free')
Write-Step ('PS      : ' + $machine.powershell_version + ' | ' + $machine.dotnet)
Write-Step ('Model   : ' + $modelInfo.path)
Write-Step (('Model   : ') + $modelInfo.length + ' bytes, last write ' + $modelInfo.last_write)

if (-not $modelInfo.exists) {
    Write-Step ''
    Write-Step 'FATAL: model file not found. The only allowed model is:'
    Write-Step ('  ' + $script:AllowedModelLeaf + ' (' + $script:AllowedModelSize + ' bytes)')
    foreach ($r in @($modelInfo.reasons)) { Write-Step ('  ' + $r) }
    exit 3
}
if ($modelInfo.fatal) {
    Write-Step ''
    Write-Step 'FATAL: model policy check failed (hard rule: only the allowed Qwen3.5-0.8B Q6_K GGUF):'
    foreach ($r in @($modelInfo.reasons)) { Write-Step ('  ' + $r) }
    exit 3
}

$script:ExpectedAutoArenaMiB = 2048
if ($machine.total_ram_mib -gt 0) {
    $script:ExpectedAutoArenaMiB = [int][Math]::Min([Math]::Floor([double]$machine.total_ram_mib / 8.0), 2048)
}
if ($script:ExpectedAutoArenaMiB -lt 176) { $script:ExpectedAutoArenaMiB = 176 }
Write-Step ('Auto    : expected auto arena = ' + $script:ExpectedAutoArenaMiB + ' MiB (min(RAM/8, 2048))')

$binInfo = Resolve-PortBinaries -PrimaryDir $BinDir -FallbackDir $FallbackBinDir
$binDetails = Get-BinaryDetails -BinInfo $binInfo
Write-Step ''
Write-Step 'Binaries:'
foreach ($b in @($binDetails)) {
    if ($b.exists) {
        Write-Step ('  {0,-10} {1}  ({2} bytes, {3})' -f $b.key, $b.path, $b.length, $b.last_write)
    }
    else {
        $tried = @()
        if ($binInfo.searched.Contains($b.key)) { $tried = @($binInfo.searched[$b.key]) }
        Write-Step ('  {0,-10} NOT FOUND' -f $b.key)
        Write-Step ('             searched: ' + ($tried -join ' ; '))
    }
}

$allDefs = @(Get-CaseDefinitions -ModelPath $Model)
$selectedDefs = @(Select-CaseDefinitions -Definitions $allDefs -Filter $Cases)
if ($selectedDefs.Count -eq 0) {
    Write-Step ''
    Write-Step 'FATAL: no test cases selected. Available:'
    foreach ($d in @($allDefs)) { Write-Step ('  ' + $d.id + ' (' + $d.name + ')') }
    exit 4
}
Write-Step ''
Write-Step ('Cases   : ' + (@($selectedDefs | ForEach-Object { $_.id }) -join ', '))

if ($DryRun) {
    Write-Step ''
    Write-Step '----- DRY RUN: planned commands (nothing will be executed) -----'
    foreach ($d in @($selectedDefs)) {
        $exe = $null
        if ($binInfo.resolved.Contains($d.exe_key)) { $exe = $binInfo.resolved[$d.exe_key] }
        if (-not $exe) { $exe = '<missing: ' + $d.exe_key + '.exe>' }
        $plannedEnv = [ordered]@{}
        foreach ($k in @($d.env.Keys)) { $plannedEnv[[string]$k] = [string]$d.env[$k] }
        if ($d.add_log_env) { $plannedEnv['LLAMA_DISK_LOG'] = '<case-dir>/disktui.log' }
        if ($d.add_home_env) { $plannedEnv['HOME'] = '<case-dir>'; $plannedEnv['USERPROFILE'] = '<case-dir>' }
        $timeout = if ($d.timeout_sec -gt 0) { [int]$d.timeout_sec } else { [int]$TimeoutSec }
        Write-Step ''
        Write-Step ('  ' + $d.id + ' / ' + $d.name)
        Write-Step ('    exe     : ' + $exe)
        Write-Step ('    env     : ' + (Format-EnvMapText $plannedEnv))
        Write-Step ('    args    : ' + (@($d.args) -join ' '))
        Write-Step ('    stdin   : ' + $d.stdin + '; timeout: ' + $timeout + ' s')
    }
    Write-Step ''
    Write-Step 'DRY RUN finished, no process was started and no file was written.'
    exit 0
}

$runDir = Join-Path $LogDir $runId
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Write-Step ('Run dir : ' + $runDir)
Write-Step ''

$issues = New-Object System.Collections.ArrayList
$notes  = New-Object System.Collections.ArrayList

# ---------------- preflight issues
if (-not $binInfo.primary_exists) {
    [void]$issues.Add([pscustomobject]@{
        severity = 'LOW'; case_id = 'preflight'; case_name = 'binary-lookup'; check = 'primary_bin_dir'
        message = ('primary binary dir does not exist: ' + $BinDir + ' (fallback: ' + $FallbackBinDir + ')')
        repro = ('Test-Path ''' + $BinDir + ''''); case_dir = $runDir
    })
}
$caseRequirements = @{
    case1 = 'diskrun'; case2 = 'diskrun'; case3 = 'diskrun'; case4 = 'diskrun'
    case5 = 'disktui'; case6 = 'diskrun'; case7 = 'diskrun'
}
foreach ($key in @($binInfo.resolve_spec.Keys)) {
    if ($null -eq $binInfo.resolved[$key]) {
        $needed = $false
        foreach ($d in @($selectedDefs)) {
            if ($d.exe_key -eq $key) { $needed = $true }
        }
        [void]$issues.Add([pscustomobject]@{
            severity = $(if ($needed) { 'HIGH' } else { 'LOW' })
            case_id = 'preflight'; case_name = 'binary-lookup'; check = 'missing_binary'
            message = ('no executable found for key ''' + $key + ''' (looked for: ' + (@($binInfo.searched[$key]) -join ' ; ') + ')')
            repro = ('Test-Path (Join-Path ''' + $BinDir + ''' ''' + $key + '.exe'')')
            case_dir = $runDir
        })
    }
}
foreach ($b in @($binDetails)) {
    if ($b.exists -and $b.stale_dll_count -gt 0) {
        [void]$issues.Add([pscustomobject]@{
            severity = 'LOW'; case_id = 'preflight'; case_name = 'binary-lookup'; check = 'stale_sibling_dlls'
            message = ('{0} has {1} sibling DLL(s) older than the executable; possible stale-mix in the output folder' -f $b.path, $b.stale_dll_count)
            repro = ('Get-ChildItem ''' + (Split-Path -Parent $b.path) + ''' -Filter *.dll | Select Name,LastWriteTime')
            case_dir = $runDir
        })
    }
}
if (-not $script:ProcIoAvailable) {
    [void]$notes.Add('Process I/O counters are unavailable (Add-Type failed); disk-read evidence is limited to the parsed logs.')
    [void]$issues.Add([pscustomobject]@{
        severity = 'LOW'; case_id = 'preflight'; case_name = 'io-counters'; check = 'proc_io_counters'
        message = 'Windows process I/O counters could not be read in this session.'
        repro = 'pwsh -NoProfile -Command "Add-Type ... GetProcessIoCounters ..."'
        case_dir = $runDir
    })
}

# ---------------- run the selected cases sequentially
$results = New-Object System.Collections.ArrayList
$resultsById = @{}
foreach ($def in @($selectedDefs)) {
    Write-Step ('--- running ' + $def.id + ' (' + $def.name + ') ---')
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-OneTestCase -Definition $def -BinInfo $binInfo -RunDir $runDir -PollMs $PollMs -TimeoutSec $TimeoutSec
    $stopwatch.Stop()
    [void]$results.Add($result)
    $resultsById[$result.id] = $result
    $rssText = ''
    if ($null -ne $result.rss_os_peak_mib) { $rssText = (Format-Mib $result.rss_os_peak_mib) + ' MiB' }
    Write-Step ('    -> {0}: {1}  exit={2}  wall={3}s  tokens={4}  arena={5}  rss={6}' -f `
        $def.id, $result.status, $(if ($null -ne $result.exit_code) { [string]$result.exit_code } else { 'n/a' }), `
        (Format-Seconds $result.duration_s), $(if ($null -ne $result.tokens) { [string]$result.tokens } else { 'n/a' }), `
        $(if ($null -ne $result.arena_mib) { [string]$result.arena_mib } else { 'n/a' }), $rssText)
    Write-Step ''
}

# ---------------- diagnostic case2b if case1/case2 text differs
if (-not $NoDiagnostics -and $resultsById.ContainsKey('case1') -and $resultsById.ContainsKey('case2')) {
    $c1 = $resultsById['case1']
    $c2 = $resultsById['case2']
    $preIds  = Compare-TokenIds -Left $c1.generated_token_ids -Right $c2.generated_token_ids
    $preText = Compare-OutputText -Left $c1.generated_text -Right $c2.generated_text
    $needsDiagnostic = ($preIds.compared -and -not $preIds.match) -or (-not $preIds.compared -and $preText.compared -and -not $preText.match)
    if ($needsDiagnostic) {
        Write-Step 'case1/case2 greedy output differs; running diagnostic case2b (native + GGML_CPU_DISABLE_FUSION=1)'
        $def2b = [pscustomobject]@{
            id           = 'case2b'
            name         = 'native-baseline-fusion-off'
            exe_key      = 'diskrun'
            args         = @()
            env          = [ordered]@{ 'LLAMA_DISK_STREAM_MB' = '0'; 'GGML_CPU_DISABLE_FUSION' = '1' }
            timeout_sec  = 0
            stdin        = 'closed'
            add_log_env  = $false
            add_home_env = $false
            description  = 'Diagnostic only: native path with op fusion disabled, to classify a case1/case2 text difference.'
            expect       = (New-CaseExpectation -Overrides @{
                streaming         = 'off'
                require_answer    = $true
                require_disk_read = $false
            })
        }
        # args must be the real argument list, not the repro string
        $def2b.args = @('-m', $Model, '-p', $script:PromptText, '-n', '8', '-c', '128', '-b', '4', '-ub', '4', '-t', '4')
        $result2b = Invoke-OneTestCase -Definition $def2b -BinInfo $binInfo -RunDir $runDir -PollMs $PollMs -TimeoutSec $TimeoutSec
        [void]$results.Add($result2b)
        $resultsById[$result2b.id] = $result2b
        Write-Step ('    -> case2b: ' + $result2b.status + '  tokens=' + $(if ($null -ne $result2b.tokens) { [string]$result2b.tokens } else { 'n/a' }))
        Write-Step ''
    }
}

# ---------------- cross-case comparison (greedy token ids first, text as fallback)
$crossChecks = New-Object System.Collections.ArrayList
$pairs = @(
    [pscustomobject]@{ id = 'case1-vs-case2'; a = 'case1'; b = 'case2'; required = $true;  label = 'streamed 200 MiB arena vs native baseline (greedy token ids must be identical)' },
    [pscustomobject]@{ id = 'case1-vs-case3'; a = 'case1'; b = 'case3'; required = $false; label = 'streamed 200 MiB arena vs auto arena' },
    [pscustomobject]@{ id = 'case1-vs-case4'; a = 'case1'; b = 'case4'; required = $false; label = 'streaming with direct I/O vs direct I/O off' },
    [pscustomobject]@{ id = 'case1-vs-case7'; a = 'case1'; b = 'case7'; required = $false; label = '200 MiB arena request vs 32 MiB request (both raised)' },
    [pscustomobject]@{ id = 'case1-vs-case2b'; a = 'case1'; b = 'case2b'; required = $false; label = 'diagnostic: streamed vs native with fusion disabled' }
)
foreach ($pair in $pairs) {
    if (-not $resultsById.ContainsKey($pair.a) -or -not $resultsById.ContainsKey($pair.b)) { continue }
    $ra = $resultsById[$pair.a]
    $rb = $resultsById[$pair.b]
    $idCmp   = Compare-TokenIds -Left $ra.generated_token_ids -Right $rb.generated_token_ids
    $textCmp = Compare-OutputText -Left $ra.generated_text -Right $rb.generated_text

    $idResult = 'SKIP'
    if ($idCmp.compared) { if ($idCmp.match) { $idResult = 'MATCH' } else { $idResult = 'MISMATCH' } }
    $textResult = 'SKIP'
    if ($textCmp.compared) { if ($textCmp.match) { $textResult = 'MATCH' } else { $textResult = 'MISMATCH' } }
    $resultText = $idResult
    if ($resultText -eq 'SKIP') { $resultText = $textResult }

    $detailParts = @()
    if ($idResult -ne 'SKIP') { $detailParts += ('token ids: ' + $idCmp.detail) }
    else { $detailParts += ('token ids: not comparable (' + $idCmp.detail + ')') }
    if ($textResult -ne 'SKIP') { $detailParts += ('text: ' + $textCmp.detail) }
    else { $detailParts += 'text: not comparable' }
    $detail = ($detailParts -join ' | ')

    $leftPreview = ''
    $rightPreview = ''
    if ($ra.generated_text) {
        $leftPreview = Convert-ToAsciiText $ra.generated_text
        if ($leftPreview.Length -gt 80) { $leftPreview = $leftPreview.Substring(0, 80) + '...' }
        $leftPreview = $leftPreview -replace "`n", '\n'
    }
    if ($rb.generated_text) {
        $rightPreview = Convert-ToAsciiText $rb.generated_text
        if ($rightPreview.Length -gt 80) { $rightPreview = $rightPreview.Substring(0, 80) + '...' }
        $rightPreview = $rightPreview -replace "`n", '\n'
    }
    [void]$crossChecks.Add([pscustomobject]@{
        id             = $pair.id
        label          = $pair.label
        required       = $pair.required
        a_case         = $pair.a
        b_case         = $pair.b
        result         = $resultText
        id_result      = $idResult
        text_result    = $textResult
        detail         = $detail
        token_ids_a    = Format-IdList $ra.generated_token_ids
        token_ids_b    = Format-IdList $rb.generated_token_ids
        token_count_a  = @($ra.generated_token_ids).Count
        token_count_b  = @($rb.generated_token_ids).Count
        left_preview   = $leftPreview
        right_preview  = $rightPreview
        left_len       = $ra.generated_text.Length
        right_len      = $rb.generated_text.Length
        a_dir          = $ra.case_dir
        b_dir          = $rb.case_dir
    })
}

$requiredPairs = @($crossChecks | Where-Object { $_.required })
$requiredMismatch = @($requiredPairs | Where-Object { $_.result -eq 'MISMATCH' })
$requiredChecked  = @($requiredPairs | Where-Object { $_.result -ne 'SKIP' })
$requiredIdChecked = @($requiredPairs | Where-Object { $_.id_result -ne 'SKIP' })
$requiredIdMismatch = @($requiredPairs | Where-Object { $_.id_result -eq 'MISMATCH' })
$requiredVerdict  = 'NOT CHECKED'
if ($requiredIdMismatch.Count -gt 0) {
    $requiredVerdict = 'FAIL - streamed and native greedy token ids differ (correctness bug)'
}
elseif ($requiredMismatch.Count -gt 0) {
    $requiredVerdict = 'FAIL - streamed and native greedy text differs (correctness bug)'
}
elseif ($requiredIdChecked.Count -gt 0) {
    $requiredVerdict = ('PASS - streamed and native greedy token ids are identical ({0} tokens)' -f $requiredIdChecked[0].token_count_a)
}
elseif ($requiredChecked.Count -gt 0) {
    $requiredVerdict = 'PASS - streamed and native greedy text are identical (token ids unavailable)'
}

if ($requiredMismatch.Count -gt 0) {
    $badPair = $requiredMismatch[0]
    $diagnosis = 'A greedy token-id/text difference between the streaming and native paths is a correctness bug.'
    $diag = $crossChecks | Where-Object { $_.id -eq 'case1-vs-case2b' }
    if ($null -ne $diag -and $diag.result -eq 'MATCH') {
        $diagnosis = 'The difference disappears with GGML_CPU_DISABLE_FUSION=1, so it is probably op-fusion numerics rather than the streaming engine; still a streamed-vs-native mismatch.'
    }
    elseif ($null -ne $diag -and $diag.result -eq 'MISMATCH') {
        $diagnosis = 'The difference persists with GGML_CPU_DISABLE_FUSION=1, which points at the streaming/compute path itself.'
    }
    $msg = ('{0} Detail: {1}' -f $diagnosis, $badPair.detail)
    $issue = [pscustomobject]@{
        severity = 'HIGH'; case_id = 'cross-check'; case_name = $badPair.id
        check = 'greedy_token_ids_match'; message = $msg
        repro = ($resultsById['case1'].command + '   vs   ' + $resultsById['case2'].command)
        case_dir = ($badPair.a_dir + ' ; ' + $badPair.b_dir)
    }
    [void]$issues.Add($issue)
    $c1 = $resultsById['case1']
    $checkName = 'greedy_token_ids_match_native'
    if ($badPair.id_result -eq 'SKIP') { $checkName = 'text_matches_native' }
    $extraCheck = [pscustomobject]@{ check = $checkName; status = 'FAIL'; detail = $msg }
    $c1.checks = @($c1.checks) + $extraCheck
    $c1.issues = @($c1.issues) + $issue
    $c1.status = 'FAIL'
}
elseif ($requiredChecked.Count -gt 0) {
    $c1 = $resultsById['case1']
    $okPair = $requiredChecked[0]
    if ($okPair.id_result -eq 'MATCH') {
        $extraCheck = [pscustomobject]@{ check = 'greedy_token_ids_match_native'; status = 'PASS'; detail = ('streamed greedy token ids are identical to the native baseline ({0} tokens): {1}' -f $okPair.token_count_a, $okPair.token_ids_a) }
    }
    else {
        $extraCheck = [pscustomobject]@{ check = 'text_matches_native'; status = 'PASS'; detail = 'streamed output is byte-identical to the native baseline (token ids unavailable): ' + $okPair.left_preview }
    }
    $c1.checks = @($c1.checks) + $extraCheck
}

# ---------------- collect issues from case results
foreach ($r in @($results)) {
    foreach ($i in @($r.issues)) {
        $exists = $false
        foreach ($known in @($issues)) {
            if ($known.case_id -eq $i.case_id -and $known.check -eq $i.check -and $known.message -eq $i.message) { $exists = $true; break }
        }
        if (-not $exists) { [void]$issues.Add($i) }
    }
}

# ---------------- notes
if (@($results | Where-Object { $_.exe_key -eq 'diskrun' -and $_.arena_mib -ne $null -and -not $_.io_reported }).Count -gt 0) {
    [void]$notes.Add('diskrun does not log per-token io/cmp seconds; for diskrun cases only wall time, process I/O counters and RSS are available. disktui logs io/cmp per token.')
}
if (@($results | Where-Object { $_.direct_io -eq 0 -and $_.id -ne 'case4' }).Count -gt 0) {
    [void]$notes.Add('At least one streaming run reported direct io = 0; disk reads may be served from the Windows page cache, so io timings are not raw-disk timings.')
}
if (@($binInfo.missing).Count -gt 0) {
    [void]$notes.Add('Missing binaries: ' + (@($binInfo.missing) -join ', ') + '. Cases that need them were marked ERROR instead of being skipped silently.')
}
[void]$notes.Add('All runs used only the allowed model Qwen3.5-0.8B-Q6_K.gguf; no other model was downloaded, converted or executed.')
[void]$notes.Add('stdout/stderr for every case were captured to separate files; disktui stdout intentionally contains ANSI escape sequences.')
[void]$notes.Add('RSS is the harness-sampled process working-set peak (OS counter) unless noted; app-reported rss values come from the binaries and are 0/-1 when the port reports them on Windows.')
[void]$notes.Add('Environment variables are applied per child process via ProcessStartInfo.Environment and every LLAMA_DISK_*/GGML_CPU_DISABLE_FUSION variable is stripped first, so no env leaks between cases.')

# ---------------- overall status
$counts = [ordered]@{ PASS = 0; WARN = 0; FAIL = 0; TIMEOUT = 0; ERROR = 0; SKIP = 0 }
foreach ($r in @($results)) {
    if ($counts.Contains($r.status)) { $counts[$r.status] = $counts[$r.status] + 1 }
    else { $counts[$r.status] = 1 }
}
$overallStatus = 'PASS'
if ($counts.FAIL + $counts.TIMEOUT + $counts.ERROR + $requiredMismatch.Count -gt 0) { $overallStatus = 'FAIL' }
elseif ($counts.WARN -gt 0) { $overallStatus = 'WARN' }

$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$payload = [ordered]@{
    schema_version = 1
    run_id         = $runId
    generated_at   = $generatedAt
    script         = $PSCommandPath
    machine        = $machine
    model          = $modelInfo
    binaries       = [ordered]@{
        primary_dir  = $BinDir
        fallback_dir = $FallbackBinDir
        search_dirs  = @($binInfo.search_dirs)
        exes         = @($binDetails)
        missing      = @($binInfo.missing)
    }
    selection      = @($selectedDefs | ForEach-Object { $_.id })
    overall        = [ordered]@{
        status = $overallStatus
        counts = $counts
    }
    cross_case     = [ordered]@{
        required_verdict   = $requiredVerdict
        required_checked   = ($requiredChecked.Count -gt 0)
        required_match     = ($requiredMismatch.Count -eq 0 -and $requiredChecked.Count -gt 0)
        token_ids_checked  = ($requiredIdChecked.Count -gt 0)
        token_ids_match    = ($requiredIdMismatch.Count -eq 0 -and $requiredIdChecked.Count -gt 0)
    }
    cases          = @($results)
    cross_checks   = @($crossChecks)
    issues         = @($issues)
    notes          = @($notes)
}

$summaryJsonPath = Join-Path $runDir 'summary.json'
$summaryMdPath   = Join-Path $runDir 'summary.md'
Write-SummaryJson -Path $summaryJsonPath -Payload $payload
Write-SummaryMarkdown -Path $summaryMdPath -Payload $payload

# latest pointers (best effort)
try {
    $latestJson = Join-Path $LogDir 'latest-summary.json'
    $latestMd   = Join-Path $LogDir 'latest-summary.md'
    Write-Utf8File -Path $latestJson -Text ([System.IO.File]::ReadAllText($summaryJsonPath))
    Write-Utf8File -Path $latestMd -Text ([System.IO.File]::ReadAllText($summaryMdPath))
    Write-Utf8File -Path (Join-Path $LogDir 'latest-run.txt') -Text ($runDir + "`r`n")
}
catch { }

# ---------------- console summary
Write-Step ''
Write-Step '================================ SUMMARY ================================'
Write-Step ''
Write-Step ('{0,-7} {1,-6} {2,-26} {3,8} {4,6} {5,7} {6,8} {7,8}' -f 'case', 'status', 'name', 'wall_s', 'exit', 'tokens', 'arena', 'rss_mib')
foreach ($r in @($results)) {
    Write-Step ('{0,-7} {1,-6} {2,-26} {3,8} {4,6} {5,7} {6,8} {7,8}' -f `
        $r.id, $r.status, $r.name, (Format-Seconds $r.duration_s), $(if ($null -ne $r.exit_code) { [string]$r.exit_code } else { 'n/a' }), `
        $(if ($null -ne $r.tokens) { [string]$r.tokens } else { '-' }), `
        $(if ($null -ne $r.arena_mib) { [string]$r.arena_mib } else { '-' }), `
        $(if ($null -ne $r.rss_os_peak_mib) { (Format-Mib $r.rss_os_peak_mib) } elseif ($null -ne $r.rss_app_mib) { [string]$r.rss_app_mib } else { '-' }))
}
Write-Step ''
Write-Step ('Cross-case text check: ' + $requiredVerdict)
foreach ($x in @($crossChecks)) {
    Write-Step ('  {0,-18} {1,-9} required={2}  {3}' -f $x.id, $x.result, $x.required, $x.detail)
}
Write-Step ''
Write-Step ('ISSUES: ' + @($issues).Count + ' (' + (@($issues | Where-Object { $_.severity -eq 'HIGH' }).Count) + ' high)')
foreach ($i in @($issues | Where-Object { $_.severity -eq 'HIGH' })) {
    Write-Step ('  [HIGH] ' + $i.case_id + ' / ' + $i.check + ': ' + $i.message)
}
Write-Step ''
Write-Step ('OVERALL: ' + $overallStatus + '  (' + (Format-StatusCounts $payload.overall) + ')')
Write-Step ('Summary JSON : ' + $summaryJsonPath)
Write-Step ('Summary MD   : ' + $summaryMdPath)
Write-Step ('Raw logs     : ' + $runDir)

if ($overallStatus -eq 'FAIL') { exit 1 }
exit 0
