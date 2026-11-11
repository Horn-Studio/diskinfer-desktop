#requires -Version 5.1
<#
.SYNOPSIS
    Build the diskinfer llama.cpp fork for Windows x64 with MSVC (Visual Studio 2022).

.DESCRIPTION
    Windows counterpart of build-android.sh.

    Produces self-contained Release executables in the output directory:
        disktui.exe           (built from target llama-diskui)
        diskrun.exe           (built from target llama-diskrun)
        diskc.exe             (built from target llama-diskc: streaming chat engine
                               used by the PySide6 workbench chat mode)
        llama-completion.exe  (built from target llama-completion)

    By default everything is static: static llama/ggml/common libraries plus the
    static MSVC runtime (-DBUILD_SHARED_LIBS=OFF, CMAKE_MSVC_RUNTIME_LIBRARY=
    MultiThreaded), so the exes need no VC++ redistributable and no DLLs next to
    them. Use -SharedLibs to keep shared libraries instead (the DLLs are copied
    to the output directory as well).

    Uses the "Visual Studio 17 2022" generator with -A x64; cmake locates MSBuild
    on its own, so no vcvars/developer prompt is needed.

    Image paths (all optional, defaults shown):
        -Source  <repo>\src\llama.cpp-fork
        -BuildDir <repo>\build\win-x64
        -OutDir   <repo>\build\out\win-x64

.PARAMETER Source
    llama.cpp fork source tree (the directory containing src\llama-disk.cpp).
    Defaults to $env:DISKINFER_SRC when set, otherwise <repo>\src\llama.cpp-fork.

.PARAMETER BuildDir
    CMake build tree. Defaults to <script dir>\win-x64.
    Note: the default is the same tree the interactive/dev builds use; pass
    -BuildDir for a side-by-side build.

.PARAMETER OutDir
    Directory the final exes are copied to. Defaults to <script dir>\out\win-x64.

.PARAMETER Jobs
    Parallel compile jobs, passed to MSBuild as /m:<Jobs>. Defaults to
    $env:JOBS when set, otherwise the number of logical processors.

.PARAMETER Targets
    CMake targets to build. Defaults to 'llama-diskui','llama-diskrun','llama-diskc',
    'llama-completion'.

.PARAMETER Clean
    Remove the build tree first (and stale copies in the output dir). This is
    the safest option when switching between static and shared builds.

.PARAMETER SharedLibs
    Build with shared libraries (BUILD_SHARED_LIBS=ON) instead of the default
    static single-file exes. The produced DLLs are copied next to the exes.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build-windows.ps1

.EXAMPLE
    pwsh -NoProfile -File build-windows.ps1 -Clean -Jobs 12

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build-windows.ps1 -SharedLibs

.EXAMPLE
    pwsh -NoProfile -File build-windows.ps1 -BuildDir F:\tmp\win-test -OutDir F:\tmp\out-test -Clean
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$BuildDir,
    [string]$OutDir,
    [int]$Jobs = 0,
    [string[]]$Targets = @('llama-diskui', 'llama-diskrun', 'llama-diskc', 'llama-completion'),
    [switch]$Clean,
    [switch]$SharedLibs
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Resolve-FullPath([string]$Path) {
    # resolves relative to the PowerShell location (not the process CWD) and
    # does not require the path to exist
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-SafeRemovalPath([string]$Path) {
    # guard for -Clean: never remove a drive root, a repo path, or a shallow
    # system directory
    $full = (Resolve-FullPath $Path).TrimEnd('\')
    if (-not $full) { return $false }
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not $root) { return $false }
    if ($full -eq $root.TrimEnd('\')) { return $false }
    $protected = @($repoRoot, $Source, $here)
    foreach ($p in $protected) {
        $pc = (Resolve-FullPath $p).TrimEnd('\')
        if ($full -eq $pc) { return $false }
        if ($pc.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $parts = @($full.Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 3) { return $false }
    return $true
}

function ConvertTo-MiB([long]$Bytes) {
    return [math]::Round($Bytes / 1MB, 1)
}

# ---------------------------------------------------------------------------
# parameters / paths
# ---------------------------------------------------------------------------

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$repoRoot = Split-Path -Parent $here

if (-not $Source) {
    if ($env:DISKINFER_SRC) {
        $Source = $env:DISKINFER_SRC
    } else {
        $Source = Join-Path $repoRoot 'src\llama.cpp-fork'
        # the desktop repo keeps one shared src/ at its root and the Windows tree in windows/
        if (-not (Test-Path -LiteralPath (Join-Path $Source 'src\llama-disk.cpp'))) {
            $shared = Join-Path (Split-Path -Parent $repoRoot) 'src\llama.cpp-fork'
            if (Test-Path -LiteralPath (Join-Path $shared 'src\llama-disk.cpp')) { $Source = $shared }
        }
    }
}
if (-not $BuildDir) { $BuildDir = Join-Path $here 'win-x64' }
if (-not $OutDir) { $OutDir = Join-Path $here 'out\win-x64' }

$Source = Resolve-FullPath $Source
$BuildDir = Resolve-FullPath $BuildDir
$OutDir = Resolve-FullPath $OutDir

if ($Jobs -le 0) {
    $envJobs = [int]0
    if ($env:JOBS -and [int]::TryParse($env:JOBS, [ref]$envJobs) -and $envJobs -gt 0) {
        $Jobs = $envJobs
    } else {
        $Jobs = [Environment]::ProcessorCount
    }
}
if ($Jobs -lt 1) { $Jobs = 1 }

$targetList = @()
foreach ($t in $Targets) {
    if ($null -ne $t -and $t.Trim()) { $targetList += $t.Trim() }
}
if ($targetList.Count -eq 0) {
    Fail 'no build targets given (use -Targets llama-diskui,llama-diskrun,llama-diskc,llama-completion)'
}
$Targets = $targetList

$modeText = 'static (single-file exes, static MSVC runtime)'
if ($SharedLibs) { $modeText = 'shared (exes need the DLLs copied next to them)' }

$cmakeCMD = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmakeCMD) {
    Fail 'cmake was not found in PATH. Install CMake 3.20 or newer (for example: winget install Kitware.CMake) and reopen the terminal.'
}
$cmakeExe = $cmakeCMD.Definition

$diskCore = Join-Path $Source 'src\llama-disk.cpp'
if (-not (Test-Path -LiteralPath $diskCore -PathType Leaf)) {
    Fail ("fork source not found at '$Source' (expected src\llama-disk.cpp). " +
          'If the repository lives elsewhere, pass -Source <path> or set DISKINFER_SRC.')
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Step 'diskinfer Windows build'
Write-Host ("  source    : {0}" -f $Source)
Write-Host ("  build dir : {0}" -f $BuildDir)
Write-Host ("  out dir   : {0}" -f $OutDir)
Write-Host ("  targets   : {0}" -f ($Targets -join ' '))
Write-Host ("  jobs      : {0}" -f $Jobs)
Write-Host ("  libraries : {0}" -f $modeText)
$cmakeFirstLine = 'unknown'
try {
    $versionOut = @(& $cmakeExe --version 2>&1)
    if ($versionOut.Count -gt 0) { $cmakeFirstLine = ([string]$versionOut[0]).Trim() }
} catch {
    $cmakeFirstLine = 'unknown'
}
Write-Host ("  cmake     : {0}" -f $cmakeFirstLine)

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------

if ($Clean) {
    if (Test-Path -LiteralPath $BuildDir) {
        if (-not (Test-SafeRemovalPath -Path $BuildDir)) {
            Fail "refusing to remove build dir '$BuildDir' (-Clean safety check failed; remove it manually if that is really intended)"
        }
        Write-Step "removing build dir: $BuildDir"
        Remove-Item -LiteralPath $BuildDir -Recurse -Force
    }
    # drop stale copies so the output dir only reflects this build
    if (Test-Path -LiteralPath $OutDir -PathType Container) {
        Write-Step "removing stale outputs from: $OutDir"
        foreach ($name in @('disktui.exe', 'diskrun.exe', 'diskc.exe', 'llama-completion.exe')) {
            $stale = Join-Path $OutDir $name
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
        }
        $staleDlls = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        foreach ($dll in $staleDlls) { Remove-Item -LiteralPath $dll.FullName -Force }
    }
}

# warn when an existing build tree was configured with the other library mode;
# cmake reconfigures fine, but a fresh tree is more predictable
$cacheFile = Join-Path $BuildDir 'CMakeCache.txt'
if (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
    $wanted = 'OFF'
    if ($SharedLibs) { $wanted = 'ON' }
    $line = Select-String -LiteralPath $cacheFile -Pattern '^BUILD_SHARED_LIBS:BOOL=' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $line) {
        $current = ($line.Line -split '=', 2)[1]
        if ($current -ne $wanted) {
            Write-Host ''
            Write-Host ("note: '{0}' was configured with BUILD_SHARED_LIBS={1}, switching to {2}." -f $BuildDir, $current, $wanted) -ForegroundColor Yellow
            Write-Host '      Pass -Clean for a guaranteed pristine build tree.' -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

Write-Step 'configuring'
if (-not (Test-Path -LiteralPath $BuildDir -PathType Container)) {
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
}

$cmakeArgs = @(
    '-S', $Source,
    '-B', $BuildDir,
    '-G', 'Visual Studio 17 2022',
    '-A', 'x64',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_EXAMPLES=ON',
    '-DLLAMA_BUILD_SERVER=OFF',
    '-DLLAMA_CURL=OFF',
    '-DGGML_OPENMP=OFF',
    '-DGGML_NATIVE=OFF',
    '-DGGML_LLAMAFILE=OFF',
    '-DDISKINFER_UI_VERSION=1.1-preview'
)
if ($SharedLibs) {
    $cmakeArgs += '-DBUILD_SHARED_LIBS=ON'
} else {
    $cmakeArgs += '-DBUILD_SHARED_LIBS=OFF'
    $cmakeArgs += '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
}

Write-Host ('  cmake ' + ($cmakeArgs -join ' '))
& $cmakeExe @cmakeArgs
if ($LASTEXITCODE -ne 0) {
    Fail ("cmake configure failed with exit code {0}. Visual Studio 2022 with the 'Desktop development with C++' workload is required. If this build dir was configured before with other options, rerun with -Clean." -f $LASTEXITCODE)
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

Write-Step ("building targets: {0}" -f ($Targets -join ' '))
$buildArgs = @('--build', $BuildDir, '--config', 'Release', '--target') + $Targets + @('--', ("/m:{0}" -f $Jobs))
Write-Host ('  cmake ' + ($buildArgs -join ' '))
& $cmakeExe @buildArgs
if ($LASTEXITCODE -ne 0) {
    Fail ("build failed with exit code {0}. See the compiler output above; if the tree was configured with different options, rerun with -Clean." -f $LASTEXITCODE)
}

# ---------------------------------------------------------------------------
# collect outputs
# ---------------------------------------------------------------------------

Write-Step 'collecting outputs'
$binRelease = Join-Path $BuildDir 'bin\Release'
if (-not (Test-Path -LiteralPath $binRelease -PathType Container)) {
    Fail "build output directory not found: $binRelease (the build did not produce bin\Release)"
}

if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$exports = @(
    [pscustomobject]@{ From = 'llama-diskui.exe';     To = 'disktui.exe' },
    [pscustomobject]@{ From = 'llama-diskrun.exe';    To = 'diskrun.exe' },
    [pscustomobject]@{ From = 'llama-diskc.exe';      To = 'diskc.exe' },
    [pscustomobject]@{ From = 'llama-completion.exe'; To = 'llama-completion.exe' }
)
foreach ($e in $exports) {
    $from = Join-Path $binRelease $e.From
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) {
        Fail "expected build output not found: $from"
    }
    $to = Join-Path $OutDir $e.To
    Copy-Item -LiteralPath $from -Destination $to -Force
    Write-Host ("  {0,-24} -> {1}" -f $e.From, $to)
}

$dlls = @(Get-ChildItem -LiteralPath $binRelease -Filter '*.dll' -File -ErrorAction SilentlyContinue)
if ($dlls.Count -gt 0) {
    if ($SharedLibs) {
        foreach ($dll in $dlls) {
            Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $OutDir $dll.Name) -Force
        }
        Write-Host ("  copied {0} DLL(s) (shared build)" -f $dlls.Count)
    } else {
        Write-Host ("note: {0} DLL(s) are present in {1} although a static build was requested." -f $dlls.Count, $binRelease) -ForegroundColor Yellow
        Write-Host '      They are leftovers from an earlier shared configure and were NOT copied. Use -Clean for a pristine tree.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# post-build checks
# ---------------------------------------------------------------------------

Write-Step 'verifying outputs'
$expected = @('disktui.exe', 'diskrun.exe', 'diskc.exe', 'llama-completion.exe')
$sizes = @()
foreach ($name in $expected) {
    $path = Join-Path $OutDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "missing expected output: $path"
    }
    $bytes = (Get-Item -LiteralPath $path).Length
    if ($bytes -le 0) {
        Fail "zero-length output: $path"
    }
    $sizes += [pscustomobject]@{ Name = $name; Bytes = $bytes }
    Write-Host ("  ok {0} ({1} MiB)" -f $name, (ConvertTo-MiB $bytes))
}

$completionExe = Join-Path $OutDir 'llama-completion.exe'
$versionText = ''
$versionCode = -1
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $versionText = ((& $completionExe --version 2>&1 | Out-String) -replace "`r", '').Trim()
    $versionCode = $LASTEXITCODE
} catch {
    $versionText = ''
    $versionCode = -1
} finally {
    $ErrorActionPreference = $savedEap
}

$runOk = $false
$versionLine = ''
if ($versionCode -eq 0) {
    $runOk = $true
    $versionLine = ($versionText -split "\n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if (-not $versionLine) { $versionLine = '(no output)' }
} else {
    # very old builds may not know --version: fall back to -h and accept the
    # usage exit code as long as the tool actually printed its usage text
    $helpText = ''
    $helpCode = -1
    $ErrorActionPreference = 'Continue'
    try {
        $helpText = ((& $completionExe -h 2>&1 | Out-String) -replace "`r", '').Trim()
        $helpCode = $LASTEXITCODE
    } catch {
        $helpText = ''
        $helpCode = -1
    } finally {
        $ErrorActionPreference = $savedEap
    }
    if ($helpText.Length -gt 0 -and $helpText -match 'usage') {
        $runOk = $true
        $versionLine = ("--version unsupported, -h prints usage (exit {0})" -f $helpCode)
    }
}
if (-not $runOk) {
    Fail ("llama-completion.exe does not run correctly (--version exit {0}). This usually means a missing DLL or a broken link. Output: {1}" -f $versionCode, $versionText)
}
Write-Host ("  ok llama-completion --version: {0}" -f $versionLine)

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

$stopwatch.Stop()
$totalBytes = [long]0
foreach ($s in $sizes) { $totalBytes += $s.Bytes }
$outDlls = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)

Write-Host ''
Write-Host '=== done ===' -ForegroundColor Green
Write-Host ("  out dir   : {0}" -f $OutDir)
foreach ($s in $sizes) {
    Write-Host ("  {0,-22} {1,10:N1} MiB" -f $s.Name, (ConvertTo-MiB $s.Bytes))
}
if ($outDlls.Count -gt 0) {
    Write-Host ("  plus {0} DLL(s) ({1:N1} MiB)" -f $outDlls.Count, (ConvertTo-MiB (($outDlls | Measure-Object -Property Length -Sum).Sum)))
}
Write-Host ("  total     : {0,10:N1} MiB" -f (ConvertTo-MiB $totalBytes))
Write-Host ("  version   : {0}" -f $versionLine)
Write-Host ("  build time: {0:N1} min" -f ($stopwatch.Elapsed.TotalMinutes))
Write-Host ''
Write-Host ("next: run {0}" -f (Join-Path $OutDir 'llama-completion.exe'))

exit 0
