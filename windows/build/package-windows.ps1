#requires -Version 5.1
<#
.SYNOPSIS
    Package the diskinfer Windows x64 build into a release zip.

.DESCRIPTION
    Mirrors the layout of the 1.0 preview package (dist\diskinfer-windows-1.0-preview-win-x64):

        bin\                 disktui.exe / diskrun.exe / diskc.exe / llama-completion.exe
        device\              Windows launcher (diskinfer.ps1 + diskinfer.cmd)
        gui\                 PySide6 workbench (screenshots, README, requirements, run-workbench.cmd)
        src\llama.cpp-fork\  full llama.cpp fork source (upstream v0.9.0 + diskinfer changes)
        test\                regression harness and report
        README.md            project readme
        LICENSE              llama.cpp license
        VERSION.txt          package identity
        SHA256SUMS.txt       per-file checksums of this package

    Outputs (written to -DistDir, default <repo>\dist):
        diskinfer-windows-<Version>-win-x64.zip
        SHA256SUMS.txt       SHA256 of the zip (1.0-preview format: "<HASH>  <zip name>")

.PARAMETER Version
    Package version tag, default "1.1-preview".

.PARAMETER Root
    Repository root, defaults to the parent of the build directory holding this script.

.PARAMETER BinDir
    Directory holding the four freshly built executables,
    defaults to <Root>\build\out\win-x64.

.PARAMETER DistDir
    Output directory, defaults to <Root>\dist.

.PARAMETER NoZip
    Only assemble the package directory, do not create/refresh the zip and dist checksum.

.PARAMETER KeepStage
    Leave the staging tree in <Root>\build\pkg-stage instead of moving it to DistDir.

.EXAMPLE
    pwsh -File build\package-windows.ps1
    pwsh -File build\package-windows.ps1 -Version 1.1-preview -NoZip
#>
[CmdletBinding()]
param(
    [string]$Version  = '1.1-preview',
    [string]$Root     = '',
    [string]$BinDir   = '',
    [string]$DistDir  = '',
    [switch]$NoZip,
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Copy-Tree([string]$Source, [string]$Dest, [string[]]$ExcludeDirs, [string[]]$ExcludeFiles) {
    if (-not (Test-Path -LiteralPath $Source)) { Fail "missing source directory: $Source" }
    $rc = @($Source, $Dest, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if ($ExcludeDirs.Count -gt 0) { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rc += '/XF'; $rc += $ExcludeFiles }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail ("robocopy failed for {0} -> {1} (exit {2})" -f $Source, $Dest, $LASTEXITCODE) }
}

function Get-FileSizeMiB([string]$Path) {
    return [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
}

function Get-TreeSizeMiB([string]$Path) {
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

# ---------------------------------------------------------------------------
# inputs
# ---------------------------------------------------------------------------
$here = $PSScriptRoot
if (-not $Root)    { $Root    = Split-Path -Parent $here }
if (-not $BinDir)  { $BinDir  = Join-Path $Root 'build\out\win-x64' }
if (-not $DistDir) { $DistDir = Join-Path $Root 'dist' }

$exeNames = @('disktui.exe', 'diskrun.exe', 'diskc.exe', 'llama-completion.exe')
$pkgName  = "diskinfer-windows-$Version-win-x64"
$stage    = Join-Path $Root 'build\pkg-stage'
$srcTree  = Join-Path $Root 'src\llama.cpp-fork'
if (-not (Test-Path -LiteralPath (Join-Path $srcTree 'src\llama-disk.cpp'))) {
    $shared = Join-Path (Split-Path -Parent $Root) 'src\llama.cpp-fork'
    if (Test-Path -LiteralPath (Join-Path $shared 'src\llama-disk.cpp')) { $srcTree = $shared }
}

Write-Host "package : $pkgName"
Write-Host "root    : $Root"
Write-Host "bin     : $BinDir"
Write-Host "dist    : $DistDir"

if (-not (Test-Path -LiteralPath $srcTree)) { Fail "source tree not found: $srcTree (expected the llama.cpp fork with src\llama-disk.cpp)" }
if (-not (Test-Path -LiteralPath (Join-Path $srcTree 'src\llama-disk.cpp'))) { Fail "source tree is not the diskinfer fork: $srcTree" }
foreach ($e in $exeNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $BinDir $e))) {
        Fail ("missing build output {0}; run build\build-windows.ps1 first" -f (Join-Path $BinDir $e))
    }
}
# the desktop repo keeps the shared root README simple and the detailed Windows notes
# in windows-README.md; a standalone windows checkout only has README.md
$readmeSrc = Join-Path $Root 'windows-README.md'
if (-not (Test-Path -LiteralPath $readmeSrc)) { $readmeSrc = Join-Path $Root 'README.md' }
if (-not (Test-Path -LiteralPath $readmeSrc)) { Fail "missing $readmeSrc" }
if (-not (Test-Path -LiteralPath (Join-Path $Root 'device\diskinfer.ps1'))) { Fail "missing $Root\device\diskinfer.ps1" }
if (-not (Test-Path -LiteralPath (Join-Path $Root 'gui\workbench.py'))) { Fail "missing $Root\gui\workbench.py" }

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$distStage = Join-Path $DistDir $pkgName

# ---------------------------------------------------------------------------
# stage
# ---------------------------------------------------------------------------
Write-Step 'assembling package tree'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# bin: the four executables produced by build\build-windows.ps1
$binStage = Join-Path $stage 'bin'
New-Item -ItemType Directory -Force -Path $binStage | Out-Null
foreach ($e in $exeNames) {
    Copy-Item -LiteralPath (Join-Path $BinDir $e) -Destination $binStage -Force
}

Copy-Tree (Join-Path $Root 'device') (Join-Path $stage 'device') @() @()
Copy-Tree (Join-Path $Root 'gui')    (Join-Path $stage 'gui')    @('runs', '__pycache__') @('*.pyc', '*.pyo')
Copy-Tree (Join-Path $Root 'test')   (Join-Path $stage 'test')   @('__pycache__') @('*.pyc', '*.pyo')
Copy-Tree $srcTree (Join-Path $stage 'src\llama.cpp-fork') @('.git', '__pycache__') @('*.pyc', '*.pyo')

Copy-Item -LiteralPath $readmeSrc -Destination $stage -Force
$licenseSrc = Join-Path $srcTree 'LICENSE'
if (Test-Path -LiteralPath $licenseSrc) {
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $stage 'LICENSE') -Force
} elseif (Test-Path -LiteralPath (Join-Path $Root 'LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $Root 'LICENSE') -Destination (Join-Path $stage 'LICENSE') -Force
} else {
    Fail 'no LICENSE found (looked for src\llama.cpp-fork\LICENSE and .\LICENSE)'
}

$versionText = @(
    "diskinfer-windows $Version-win-x64",
    'llama.cpp fork: upstream v0.9.0 (cd959bae) + diskinfer disk-streaming changes',
    ("packaged: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ("binaries: " + ($exeNames -join ', ')),
    'gui: PySide6 workbench in gui\ (python gui\workbench.py)'
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stage 'VERSION.txt'), $versionText + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# per-file checksums inside the package
# ---------------------------------------------------------------------------
Write-Step 'writing SHA256SUMS.txt (per-file, package root)'
$stageLen = (Resolve-Path -LiteralPath $stage).Path.TrimEnd('\').Length + 1
$files = Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object FullName
$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    $rel = $f.FullName.Substring($stageLen).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    $lines.Add(("{0}  {1}" -f $hash, $rel))
}
[System.IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$stageSize = Get-TreeSizeMiB $stage
$stageFiles = (Get-ChildItem -LiteralPath $stage -Recurse -File | Measure-Object).Count
Write-Host ("  files: {0}, size: {1} MiB" -f $stageFiles, $stageSize)

# ---------------------------------------------------------------------------
# move the tree into dist (like the 1.0 package: zip + extracted directory),
# keeping the 1.0 preview package untouched
# ---------------------------------------------------------------------------
if (-not $KeepStage) {
    Write-Step "moving package tree -> $distStage"
    if (Test-Path -LiteralPath $distStage) { Remove-Item -LiteralPath $distStage -Recurse -Force }
    Move-Item -LiteralPath $stage -Destination $distStage -Force
}

# ---------------------------------------------------------------------------
# zip + dist checksum
# ---------------------------------------------------------------------------
$zipPath = Join-Path $DistDir "$pkgName.zip"
if ($NoZip) {
    Write-Step 'skipping zip (-NoZip)'
    Write-Host ("package tree: {0}" -f $(if ($KeepStage) { $stage } else { $distStage }))
    exit 0
}

Write-Step "creating zip -> $zipPath"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (-not ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
$zipSource = if ($KeepStage) { $stage } else { $distStage }
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $zipSource, $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false)

$zipSize  = Get-FileSizeMiB $zipPath
$zipHash  = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
$sumPath  = Join-Path $DistDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($sumPath, ("{0}  {1}`n" -f $zipHash, (Split-Path -Leaf $zipPath)), (New-Object System.Text.UTF8Encoding($false)))

Write-Step 'done'
Write-Host ("  package   : {0} ({1} files, {2} MiB)" -f $(if ($KeepStage) { $stage } else { $distStage }), $stageFiles, $stageSize)
Write-Host ("  zip       : {0} ({1} MiB)" -f $zipPath, $zipSize)
Write-Host ("  sha256    : {0}" -f $zipHash)
Write-Host ("  checksums : {0}" -f $sumPath)
exit 0
