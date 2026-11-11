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
# messages: en / zh-Hans / zh-Hant, auto-detected (contract v5 §1.3):
#   --lang CLI > DISKINFER_LANG > LANG/LC_ALL > CurrentUICulture > en.
# This file is saved as UTF-8 with BOM: Windows PowerShell 5.1 then decodes the
# CJK messages correctly. The launcher resolves the language, exports it as
# DISKINFER_LANG and the new disktui.exe reads the same env var, so launcher and
# TUI always agree on the language.
#
# version: 1.1-preview

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$repoRoot = Split-Path -Parent $scriptDir

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
$script:L10N = 'en'

function Convert-LangTag([string]$Tag) {
    $t = ''
    if ($null -ne $Tag) { $t = $Tag.ToLowerInvariant() }
    if ($t -match 'hant|tw|hk|mo') { return 'zh-Hant' }
    if ($t -match '^zh') { return 'zh-Hans' }
    return 'en'
}

function Find-LangArg([string[]]$ArgList) {
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = [string]$ArgList[$i]
        if ($a -like '--lang=*') { return $a.Substring(7) }
        if ($a -eq '--lang' -and $i + 1 -lt $ArgList.Count) { return [string]$ArgList[$i + 1] }
    }
    return ''
}

function Set-DiskinferLanguage([string]$CliLang) {
    $tag = $CliLang
    if (-not $tag) { $tag = $env:DISKINFER_LANG }
    if (-not $tag) { $tag = $env:LC_ALL }
    if (-not $tag) { $tag = $env:LANG }
    if (-not $tag) {
        try { $tag = [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch { $tag = 'en' }
    }
    $script:L10N = Convert-LangTag $tag
    $env:DISKINFER_LANG = $script:L10N
}

# T <en> <zh-Hans> <zh-Hant>
function T([string]$En, [string]$Hans, [string]$Hant) {
    switch ($script:L10N) {
        'zh-Hans' { return $Hans }
        'zh-Hant' { return $Hant }
        default   { return $En }
    }
}

$allArgs = @($args)
Set-DiskinferLanguage (Find-LangArg $allArgs)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Usage {
    switch ($script:L10N) {
        'zh-Hans' {
            Write-Host @'
diskinfer 1.1-preview - Windows 启动器

用法: diskinfer.ps1 [问题词...]
      diskinfer.ps1 -m PATH [--arena MiB] [问题词...] [引擎参数]

  在以下目录里找唯一的 *.gguf 模型文件（不带 -m 时）：
      %USERPROFILE%\models、.\models、%USERPROFILE%\Downloads\models
      （有多个 -> 退出码 2，一个都没有 -> 退出码 1）
  -m PATH        模型文件（.gguf）
  --arena MiB    权重 arena 大小（设置 LLAMA_DISK_STREAM_MB；引擎会把它抬到
                 能装下最大张量，上限 2048 MiB）
                 默认 = 内存总量 / 8，收窄到 176..2048 MiB
  --lang TAG     界面语言（启动器与 TUI，经 DISKINFER_LANG 传给引擎）:
                 auto / en / zh-Hans / zh-Hant（默认按系统）
  -n N           最多生成 token 数（默认 256，受上下文限制）
  -c N           上下文大小（默认 256）
  -ub N          prefill 批大小（默认 4；1 = 最省内存，prefill 最慢）
  -t N           线程数（默认 4，桌面可试 8-16）
  --temp F       采样温度（默认 1.0）
  --top-k N      默认 20
  --top-p F      默认 0.95
  --raw          原始补全模式（默认）
  --chat         使用聊天模板（关闭 thinking）
  --sys "text"   --chat 的 system 消息
  --debug        磁盘流式诊断日志（LLAMA_DISK_DEBUG=1）
  -l, --list     列出搜索目录里找到的模型并退出
  -h, --help     显示本帮助并退出

环境变量:
  LLAMA_DISK_LOG       默认: %TEMP%\diskinfer.log
  LLAMA_DISK_STREAM_MB arena 大小 MiB（--arena 会覆盖它）
  DISKINFER_DISKTUI    显式指定 disktui.exe 路径（测试旁路构建用）

示例:
  diskinfer.ps1 "The capital of France is"
  diskinfer.ps1 -m D:\models\qwen.gguf --arena 1024 -n 64 --chat "hello"

模型搜索顺序:
  %USERPROFILE%\models\*.gguf
  .\models\*.gguf
  %USERPROFILE%\Downloads\models\*.gguf
'@
            return
        }
        'zh-Hant' {
            Write-Host @'
diskinfer 1.1-preview - Windows 啟動器

用法: diskinfer.ps1 [問題詞...]
      diskinfer.ps1 -m PATH [--arena MiB] [問題詞...] [引擎參數]

  在以下目錄裡找唯一的 *.gguf 模型檔（不帶 -m 時）：
      %USERPROFILE%\models、.\models、%USERPROFILE%\Downloads\models
      （有多個 -> 結束碼 2，一個都沒有 -> 結束碼 1）
  -m PATH        模型檔（.gguf）
  --arena MiB    權重 arena 大小（設定 LLAMA_DISK_STREAM_MB；引擎會把它抬到
                 能裝下最大張量，上限 2048 MiB）
                 預設 = 記憶體總量 / 8，收窄到 176..2048 MiB
  --lang TAG     介面語言（啟動器與 TUI，經 DISKINFER_LANG 傳給引擎）:
                 auto / en / zh-Hans / zh-Hant（預設依系統）
  -n N           最多產生 token 數（預設 256，受上下文限制）
  -c N           上下文大小（預設 256）
  -ub N          prefill 批大小（預設 4；1 = 最省記憶體，prefill 最慢）
  -t N           執行緒數（預設 4，桌機可試 8-16）
  --temp F       取樣溫度（預設 1.0）
  --top-k N      預設 20
  --top-p F      預設 0.95
  --raw          原始補全模式（預設）
  --chat         使用聊天模板（關閉 thinking）
  --sys "text"   --chat 的 system 訊息
  --debug        磁碟串流診斷日誌（LLAMA_DISK_DEBUG=1）
  -l, --list     列出搜尋目錄裡找到的模型並離開
  -h, --help     顯示本說明並離開

環境變數:
  LLAMA_DISK_LOG       預設: %TEMP%\diskinfer.log
  LLAMA_DISK_STREAM_MB arena 大小 MiB（--arena 會覆蓋它）
  DISKINFER_DISKTUI    明確指定 disktui.exe 路徑（測試旁路建置用）

範例:
  diskinfer.ps1 "The capital of France is"
  diskinfer.ps1 -m D:\models\qwen.gguf --arena 1024 -n 64 --chat "hello"

模型搜尋順序:
  %USERPROFILE%\models\*.gguf
  .\models\*.gguf
  %USERPROFILE%\Downloads\models\*.gguf
'@
            return
        }
        default {
            Write-Host @'
diskinfer 1.1-preview - Windows launcher

usage: diskinfer.ps1 [question words...]
       diskinfer.ps1 -m PATH [--arena MiB] [question words...] [engine args]

  -m PATH        model file (.gguf). if omitted, exactly one *.gguf is searched
                 for in: %USERPROFILE%\models, .\models,
                 %USERPROFILE%\Downloads\models (several models -> exit 2,
                 none -> exit 1)
  --arena MiB    weight arena size (sets LLAMA_DISK_STREAM_MB; the engine
                 raises it to fit the largest tensor and caps it at 2048 MiB)
                 default = total RAM / 8, clamped to 176..2048 MiB
  --lang TAG     UI language for the launcher and the TUI (exported to the
                 engine as DISKINFER_LANG): auto / en / zh-Hans / zh-Hant
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
    }
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
    if ($a -eq '--lang') {
        # consumed here; the resolved language is exported to disktui.exe via DISKINFER_LANG
        if ($null -ne $next) { $i += 2 } else { $i++ }
        continue
    }
    if ($a -like '--lang=*') {
        $i++
        continue
    }
    if ($a -eq '-l' -or $a -eq '--list' -or $a -eq '-list') {
        $models = @(Find-GgufModels)
        Write-Host (T 'model search dirs:' '模型搜索目录:' '模型搜尋目錄:')
        foreach ($dir in (Get-SearchDirs)) {
            $state = T 'missing' '不存在' '不存在'
            if (Test-Path -LiteralPath $dir -PathType Container) { $state = T 'exists' '存在' '存在' }
            Write-Host ("  {0}  [{1}]" -f $dir, $state)
        }
        if ($models.Count -eq 0) {
            Write-Host (T 'no *.gguf model found' '没有找到 *.gguf 模型' '沒有找到 *.gguf 模型')
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
            Write-Host (T 'diskinfer: -m needs a model path' 'diskinfer: -m 需要一个模型路径' 'diskinfer: -m 需要一個模型路徑')
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
            Write-Host (T "diskinfer: --arena needs a positive number in MiB (got '$text')" "diskinfer: --arena 需要一个正整数（MiB，收到 '$text'）" "diskinfer: --arena 需要一個正整數（MiB，收到 '$text'）")
            exit 2
        }
        $arenaMiB = $parsed
        $arenaGiven = $true
        $i++
        continue
    }
    if ($a -eq '--arena') {
        if ($null -eq $next) {
            Write-Host (T 'diskinfer: --arena needs a number in MiB' 'diskinfer: --arena 需要一个数字（MiB）' 'diskinfer: --arena 需要一個數字（MiB）')
            exit 2
        }
        $parsed = [int64]0
        if (-not [int64]::TryParse($next, [ref]$parsed) -or $parsed -lt 1) {
            Write-Host (T "diskinfer: --arena needs a positive number in MiB (got '$next')" "diskinfer: --arena 需要一个正整数（MiB，收到 '$next'）" "diskinfer: --arena 需要一個正整數（MiB，收到 '$next'）")
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
        Write-Host (T 'diskinfer: no .gguf model found' 'diskinfer: 没有找到 .gguf 模型' 'diskinfer: 沒有找到 .gguf 模型')
        Write-Host (T 'searched:' '搜索过:' '搜尋過:')
        foreach ($dir in (Get-SearchDirs)) {
            $state = T 'missing' '不存在' '不存在'
            if (Test-Path -LiteralPath $dir -PathType Container) { $state = T 'no *.gguf inside' '目录里没有 *.gguf' '目錄裡沒有 *.gguf' }
            Write-Host ("  {0}  [{1}]" -f $dir, $state)
        }
        Write-Host ''
        Write-Host (T 'put a .gguf model in one of those dirs, or pass -m PATH' '把 .gguf 模型放进上面任一目录，或者用 -m PATH 指定' '把 .gguf 模型放進上面任一目錄，或者用 -m PATH 指定')
        exit 1
    } else {
        Write-Host (T ("diskinfer: found {0} .gguf models, pass -m PATH to choose one:" -f $models.Count) ("diskinfer: 找到 {0} 个 .gguf 模型，用 -m PATH 选一个:" -f $models.Count) ("diskinfer: 找到 {0} 個 .gguf 模型，用 -m PATH 選一個:" -f $models.Count))
        foreach ($m in $models) {
            Write-Host ("  {0}" -f $m)
        }
        exit 2
    }
} else {
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        Write-Host (T ("diskinfer: model not found: {0}" -f $modelPath) ("diskinfer: 模型不存在: {0}" -f $modelPath) ("diskinfer: 模型不存在: {0}" -f $modelPath))
        exit 1
    }
    $modelPath = [System.IO.Path]::GetFullPath($modelPath)
}

# ---------------------------------------------------------------------------
# locate disktui.exe
# ---------------------------------------------------------------------------

$disktui = Find-DisktuiExe
if (-not $disktui) {
    Write-Host (T 'diskinfer: disktui.exe not found. looked for:' 'diskinfer: 没有找到 disktui.exe。找过:' 'diskinfer: 沒有找到 disktui.exe。找過:')
    if ($env:DISKINFER_DISKTUI) { Write-Host ("  {0}  (DISKINFER_DISKTUI)" -f $env:DISKINFER_DISKTUI) }
    Write-Host ("  {0}" -f (Join-Path $scriptDir 'disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'bin\disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'build\out\win-x64\disktui.exe'))
    Write-Host ("  {0}" -f (Join-Path $repoRoot 'build\win-x64\bin\Release\llama-diskui.exe'))
    Write-Host ''
    Write-Host (T 'build it first:' '请先构建:' '請先建置:')
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

Write-Host (T ("diskinfer: model {0}" -f $modelPath) ("diskinfer: 模型 {0}" -f $modelPath) ("diskinfer: 模型 {0}" -f $modelPath))
if ($arenaMiB -gt 0) {
    Write-Host (T ("diskinfer: arena {0} MiB" -f $arenaMiB) ("diskinfer: arena {0} MiB" -f $arenaMiB) ("diskinfer: arena {0} MiB" -f $arenaMiB))
}
Write-Host (T ("diskinfer: log {0}" -f $env:LLAMA_DISK_LOG) ("diskinfer: 日志 {0}" -f $env:LLAMA_DISK_LOG) ("diskinfer: 日誌 {0}" -f $env:LLAMA_DISK_LOG))
Write-Host (T ("diskinfer: exec {0}" -f $disktui) ("diskinfer: 执行 {0}" -f $disktui) ("diskinfer: 執行 {0}" -f $disktui))

$exitCode = 1
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $disktui @runArgsArray
    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }
} catch {
    Write-Host (T ("diskinfer: failed to start disktui.exe: {0}" -f $_.Exception.Message) ("diskinfer: 启动 disktui.exe 失败: {0}" -f $_.Exception.Message) ("diskinfer: 啟動 disktui.exe 失敗: {0}" -f $_.Exception.Message))
    $exitCode = 1
} finally {
    $ErrorActionPreference = $savedPreference
}

exit $exitCode
