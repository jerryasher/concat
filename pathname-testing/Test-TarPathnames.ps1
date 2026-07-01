#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Evaluates and compares pathname behaviors between Windows 11 system tar (bsdtar) and GNU tar.
.DESCRIPTION
    This script provides an automated matrix framework to create file trees and run archival
    indexing tests across multiple tar engines. It aggregates outputs into a final comparative table.
.PARAMETER Mode
    The operational phase to execute:
    'All'      - Executes the full fixture generation, archival, and analysis cycle.
    'Create'   - Only builds the dummy file system under the mock workspace directory.
    'Invoke'   - Invokes each tar engine.
    'Analyze'  - Compares the outputs of pre-existing test logs and maps them to a summary table.
    'Remove'   - Deletes the fixture files (and any directories created for them), reversing 'Create'.
.PARAMETER GnuTarPath
    The explicit absolute path to your scoop-installed GNU tar binary.
    Defaults to 'C:\me\scoop\apps\git\usr\bin\tar.exe'.
.EXAMPLE
    .\Test-TarPathnames.ps1 -Mode All -Verbose
    Runs the entire test cycle, logging file creation and command invocations.
.EXAMPLE
    .\Test-TarPathnames.ps1 -Mode Create -WhatIf
    Simulates folder construction without committing changes to disk.
.EXAMPLE
    .\Test-TarPathnames.ps1 -Mode Remove -Verbose
    Removes the fixture files and any now-empty directories created for them.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [ValidateSet("All", "Create", "Invoke", "Analyze", "Remove")]
    [string]$Mode = "Create",

    [string]$GnuTarPath = "C:\me\scoop\apps\git\usr\bin\tar.exe",

    # Stable since Windows 10 1803 (bsdtar/libarchive shipped in System32).
    # Revisit if a future Windows release relocates or removes it.
    [string]$BsdTarPath = "$env:SystemRoot\System32\tar.exe"
)



Write-Host "Running PowerShell version: $($PSVersionTable.PSVersion)"

$ErrorActionPreference = "Stop"

# --- Configuration & Paths ---
$SandboxRoot = (Get-Location).Path
$FixtureRoot = "workspace\pathtest"
$ArchiveRoot = Join-Path $FixtureRoot "archives"
$ListRoot = Join-Path $FixtureRoot "lists"

# Comprehensive Edge Case Mapping
$PathMatrix = @(
    # relative pathnames
    "down\down.txt",
    "./cat.txt",
    "..\work.txt",
    "../../j.txt",
    ".\My Documents\space file.txt",
    "./My.Documents/file.with.periods.txt",
    ".\Dir.With.Periods\Sub.Dir\another.file.txt",
    "./Mixed\Slashes/mixed.txt",
    "foo\bar123456789.txt",
    "foo///barzzzzz123456789.txt",
    ".\foo\\bar.txt",
    # absolute pathnames
    "C:/me/jerry/.dotfile",
    "C:\absolute\backslash\path.txt",
    "/mnt/drive/c/users/bobcratchett/bobcratchett.txt"
    # breaks powershell -> , "trailing-slash-dir/"
    # breaks powershell -> ,"trailing-backslash-dir\"
)

# --- Shared path canonicalization ---
# Used by both New-Fixture and Remove-Fixture so that "what got created"
# and "what should get deleted" are always computed the exact same way.
function Resolve-FixturePaths {
    [CmdletBinding()]
    param($Paths, $SandboxRoot, $FixtureRoot)

    $ResolvedEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($RawPath in $Paths) {
        # Treat both drive-letter paths (C:\... or C:/...) and leading-slash
        # paths (/mnt/...) as absolute. IsPathRooted alone misses some
        # forward-slash drive-letter cases on certain PS versions, so the
        # explicit drive-letter regex backs it up.
        $IsAbsolute = [System.IO.Path]::IsPathRooted($RawPath) -or ($RawPath -match '^[a-zA-Z]:')

        if ($IsAbsolute) {
            # Absolute paths are written to their literal on-disk location so
            # that tar, given the original path, can actually find them.
            # Normalize forward slashes so GetFullPath resolves correctly.
            $NormalizedPath = $RawPath -replace '/', '\'
            $ResolvedPath = [System.IO.Path]::GetFullPath($NormalizedPath)
        }
        else {
            # Relative paths are anchored inside the sandbox. Collapse runs of
            # separators (foo///bar) and mixed slashes before combining.
            $NormalizedPath = $RawPath -replace '[\\/]+', '\'
            $ResolvedPath = Join-Path -Path $SandboxRoot -ChildPath $FixtureRoot -AdditionalChildPath $NormalizedPath
            $ResolvedPath = [System.IO.Path]::GetFullPath($ResolvedPath)
        }

        $ResolvedEntries.Add([PSCustomObject]@{
                RawPath      = $RawPath
                ResolvedPath = $ResolvedPath
                IsAbsolute   = $IsAbsolute
            })
    }

    return $ResolvedEntries
}

# --- PHASE 1: Fixture Gen Engine ---
function New-Fixture {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Paths, $SandboxRoot, $FixtureRoot)

    Write-Host "[PHASE 1] New-Fixture - Creating test files."
    Write-Verbose "  SandboxRoot is: $SandboxRoot"
    Write-Verbose "  Generating tree at: $FixtureRoot"
    Write-Verbose ""

    $ResolvedEntries = Resolve-FixturePaths -Paths $Paths -SandboxRoot $SandboxRoot -FixtureRoot $FixtureRoot

    foreach ($FixtureEntry in $ResolvedEntries) {
        $ParentDir = Split-Path $FixtureEntry.ResolvedPath -Parent

        Write-Verbose "RawPath:        $($FixtureEntry.RawPath)"
        Write-Verbose "  IsAbsolute:   $($FixtureEntry.IsAbsolute)"

        if ($PSCmdlet.ShouldProcess($FixtureEntry.ResolvedPath, "Create File and Parent Directories")) {
            try {
                if (-not (Test-Path $ParentDir)) {
                    $null = New-Item -ItemType Directory -Path $ParentDir -Force
                    Write-Host "$ParentDir"
                }
            }
            catch {
                Write-Warning "Failed to create directory: $ParentDir`n  Reason: $_"
                continue
            }

            try {
                Set-Content -Path $FixtureEntry.ResolvedPath -Value "Tar Node Target: $($FixtureEntry.RawPath)"
                Write-Host "$($FixtureEntry.ResolvedPath)"
            }
            catch {
                Write-Warning "Failed to create file: $($FixtureEntry.ResolvedPath)`n  Reason: $_"
                continue
            }
        }
        Write-Verbose ""
    }
    Write-Verbose ""
    Write-Host
}

# --- Cleanup Engine ---

function Remove-DirectoryTree {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SandboxRoot,
        [string]$GivenPath
    )

    # Normalize separators
    $RelativePath = $GivenPath -replace '[\\/]+', '/'

    # Reject absolute paths
    if ([System.IO.Path]::IsPathRooted($GivenPath)) {
        throw "Absolute paths are not allowed: $GivenPath"
    }

    # Extract top-level component
    $TopLevelComponent = $RelativePath.Split('/')[0]

    # If it's ".", do nothing
    if ($TopLevelComponent -eq '.') {
        Write-Verbose "  Top-level component is '.', nothing to remove."
        return
    }

    # Build full path
    $ResolvedRoot = Join-Path $SandboxRoot $TopLevelComponent
    $ResolvedRoot = [System.IO.Path]::GetFullPath($ResolvedRoot)
    Write-Verbose "  Resolved subtree root: $ResolvedRoot"

    # Ensure the resolved path is still inside $SandboxRoot
    $SandboxRootResolved = [System.IO.Path]::GetFullPath($SandboxRoot)
    if (-not $ResolvedRoot.StartsWith($SandboxRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete outside sandbox: $ResolvedRoot"
    }

    # Delete the subtree
    if ($PSCmdlet.ShouldProcess($ResolvedRoot, "Remove directory")) {

        if (-not (Test-Path $ResolvedRoot)) {
            Write-Verbose "  Already gone (or never created): $ResolvedRoot"
            return $ResolvedRoot
        }

        try {
            Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force -ErrorAction Stop
            Write-Host "FixtureRoot: $ResolvedRoot"
        }
        catch {
            Write-Warning "Failed to remove subtree '$ResolvedRoot': $_"
            throw
        }
    }

    return $ResolvedRoot
}

# Deletes the empty directories crawling up through parent till hitting root or a
# non-empty directory. Used to clean up any leftover empty folders after file deletion.
function Remove-EmptyDirectoryChain {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$StartDir
    )

    $CurrentDir = $StartDir

    while ($true) {
        # Stop at filesystem root (C:\, \, or a UNC share root)
        $PathRoot = [System.IO.Path]::GetPathRoot($CurrentDir)
        if ([string]::IsNullOrEmpty($CurrentDir) -or $CurrentDir -eq $PathRoot) {
            Write-Verbose "  Reached filesystem root, stopping climb: $CurrentDir"
            break
        }

        $HasChildren = [bool](Get-ChildItem -LiteralPath $CurrentDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($HasChildren) {
            Write-Verbose "  Directory not empty, stopping climb: $CurrentDir"
            break
        }

        if ($PSCmdlet.ShouldProcess($CurrentDir, "Remove empty directory")) {
            try {
                Remove-Item -LiteralPath $CurrentDir -Force -ErrorAction Stop
                Write-Host "EmptyDir: $CurrentDir"
            }
            catch {
                Write-Warning "Could not remove directory '$CurrentDir': $_"
                throw
            }
        }

        $CurrentDir = Split-Path $CurrentDir -Parent
        Write-Verbose "  Climbing to parent: $CurrentDir"
    }
}

function Remove-Fixture {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Paths, $SandboxRoot, $FixtureRoot)

    Write-Host "[CLEANUP] Removing fixture files. Removing $FixtureRoot."

    $ResolvedEntries = Resolve-FixturePaths -Paths $Paths -SandboxRoot $SandboxRoot -FixtureRoot $FixtureRoot

    foreach ($FixtureEntry in $ResolvedEntries) {
        Write-Verbose "RawPath:        $($FixtureEntry.RawPath)"
        Write-Verbose "  IsAbsolute:   $($FixtureEntry.IsAbsolute)"

        if (-not $PSCmdlet.ShouldProcess($FixtureEntry.ResolvedPath, "Remove File")) {
            continue
        }

        if (-not (Test-Path $FixtureEntry.ResolvedPath -PathType Leaf)) {
            Write-Verbose "  Already gone (or never created): $($FixtureEntry.ResolvedPath)"
            continue
        }

        try {
            Remove-Item -Path $FixtureEntry.ResolvedPath -Force -ErrorAction Stop
            Write-Host "File: $($FixtureEntry.ResolvedPath)"

            if ($FixtureEntry.IsAbsolute) {
                Remove-EmptyDirectoryChain -StartDir (Split-Path $FixtureEntry.ResolvedPath -Parent)
            }
        }
        catch {
            Write-Warning "Failed to remove file '$($FixtureEntry.ResolvedPath)': $_"
            continue
        }
        Write-Verbose ""
    }
    Write-Verbose ""

    # Finally, remove $FixtureRoot itself
    Remove-DirectoryTree -SandboxRoot $SandboxRoot -GivenPath $FixtureRoot
}

# --- PHASE 2: Archive Execution Engine ---
function Invoke-TarEngine {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($EngineName, $BinaryPath, $Paths, $ArchiveOut, $LogOut)

    Write-Host "[PHASE 2] Invoking Archive Engine: [$EngineName]"

    if (-not (Test-Path $BinaryPath -PathType Leaf)) {
        Write-Warning "Target binary for $EngineName not found at '$BinaryPath'. Skipping execution."
        return
    }

    # Ensure container directories exist
    $null = New-Item -ItemType Directory -Path (Split-Path $ArchiveOut) -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path (Split-Path $LogOut) -Force -ErrorAction SilentlyContinue

    # Clean up old iterations
    Remove-Item $ArchiveOut -Force -ErrorAction SilentlyContinue
    Remove-Item $LogOut -Force -ErrorAction SilentlyContinue

    if ($PSCmdlet.ShouldProcess($ArchiveOut, "Compile target entries using $EngineName")) {
        foreach ($Entry in $Paths) {
            if ($EngineName -eq "gnutar" -and $Entry -match '^[a-zA-Z]:') {
                & $BinaryPath --force-local -rf $ArchiveOut $Entry 2>$null
            }
            else {
                & $BinaryPath -rf $ArchiveOut $Entry 2>$null
            }
            Write-Verbose "  Added entry: $Entry"
        }

        if (Test-Path $ArchiveOut) {
            & $BinaryPath -tf $ArchiveOut | Out-File -FilePath $LogOut -Encoding utf8
        }
    }
}

# --- PHASE 3: Tabular Analysis & Collation ---
function Show-TarAnalysis {
    param($BsdLog, $GnuLog, $OriginalPaths)

    Write-Host "[PHASE 3] Compiling structural difference records..."

    $BsdLines = if (Test-Path $BsdLog) { Get-Content $BsdLog } else { @() }
    $GnuLines = if (Test-Path $GnuLog) { Get-Content $GnuLog } else { @() }

    $ReportTable = [System.Collections.Generic.List[PSCustomObject]]::new()

    for ($i = 0; $i -lt $OriginalPaths.Count; $i++) {
        $ReportTable.Add([PSCustomObject]@{
                Index        = $i + 1
                InputPath    = $OriginalPaths[$i]
                BsdtarResult = if ($i -lt $BsdLines.Count) { $BsdLines[$i] } else { "[No Output / Failed]" }
                GnutarResult = if ($i -lt $GnuLines.Count) { $GnuLines[$i] } else { "[No Output / Failed]" }
            })
    }

    Write-Host "`n--- TAR PATHNAME TREATMENT COMPARISON SUMMARY ---" -ForegroundColor Cyan
    $ReportTable | Format-Table -AutoSize
}

# --- Main Application Thread Control ---
if ($Mode -eq "All" -or $Mode -eq "Create") {
    New-Fixture -Paths $PathMatrix -SandboxRoot $SandboxRoot -FixtureRoot $FixtureRoot
}

if ($Mode -eq "All" -or $Mode -eq "Invoke") {
    $BsdArchive = Join-Path -Path $SandboxRoot -ChildPath $ArchiveRoot -AdditionalChildPath "test-bsdtar.tar"
    $BsdLog = Join-Path -Path $SandboxRoot -ChildPath $ListRoot -AdditionalChildPath "actual-bsdtar.txt"
    Invoke-TarEngine -EngineName "bsdtar" -BinaryPath $BsdTarPath -Paths $PathMatrix -ArchiveOut $BsdArchive -LogOut $BsdLog

    # $GnuArchive = Join-Path -Path $SandboxRoot -ChildPath $ArchiveRoot -AdditionalChildPath "test-gnutar.tar"
    # $GnuLog = Join-Path -Path $SandboxRoot -ChildPath $ListRoot -AdditionalChildPath "actual-gnutar.txt"
    # Invoke-TarEngine -EngineName "gnutar" -BinaryPath $GnuTarPath -Paths $PathMatrix -ArchiveOut $GnuArchive -LogOut $GnuLog
}

if ($Mode -eq "All" -or $Mode -eq "Analyze") {
    Show-TarAnalysis -BsdLog (Join-Path -Path $SandboxRoot -ChildPath $ListRoot -AdditionalChildPath "actual-bsdtar.txt") -GnuLog (Join-Path -Path $SandboxRoot -ChildPath $ListRoot -AdditionalChildPath "actual-gnutar.txt") -OriginalPaths $PathMatrix
}

if ($Mode -eq "Remove") {
    Remove-Fixture -Paths $PathMatrix -SandboxRoot $SandboxRoot -FixtureRoot $FixtureRoot
}

Write-Host "Done."
