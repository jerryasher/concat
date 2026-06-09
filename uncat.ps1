#Requires -Version 5.1

<#
.SYNOPSIS
    Verifies or extracts the contents of a concat.ps1 archive.

.DESCRIPTION
    Reads a concatenated archive produced by concat.ps1 and either verifies
    its integrity or extracts its files.

    Without -Output, runs in verify mode: parses the manifest, checks that
    every file block is present and well-formed, and confirms that the
    actual content byte count matches the Size field in both the file header
    and trailer. Reports up to 10 errors before halting. Exits 0 on success,
    1 on any verification failure.

    With -Output, extracts files into the specified directory, recreating
    subdirectory structure from the relative paths in the archive. Warns and
    prompts before overwriting existing files unless -Force is supplied.

    Accepts the archive path from the pipeline, enabling:
        concat.ps1 | uncat.ps1
        concat.ps1 | uncat.ps1 -List
        concat.ps1 | uncat.ps1 -Output C:\restore

.PARAMETER Archive
    Path to the archive file to verify or extract. Accepts pipeline input.

.PARAMETER Output
    Directory to extract files into. If omitted, runs in verify mode.
    The directory is created if it does not exist.
    Defaults to $env:TEMP if the switch is provided without a value.

.PARAMETER List
    Prints a per-file status table in addition to the summary. Valid in
    both verify and extract modes.

.PARAMETER Force
    Suppresses the overwrite prompt during extraction. Has no effect in
    verify mode.

.PARAMETER Help
    Displays this help and exits.

.EXAMPLE
    .\uncat.ps1 Handbook.md
    Verifies the archive and prints a summary.

.EXAMPLE
    .\uncat.ps1 Handbook.md -List
    Verifies the archive and prints a per-file status table.

.EXAMPLE
    .\uncat.ps1 Handbook.md -Output C:\restore
    Extracts all files into C:\restore, prompting before any overwrites.

.EXAMPLE
    .\uncat.ps1 Handbook.md -Output C:\restore -Force
    Extracts all files, overwriting without prompting.

.EXAMPLE
    .\concat.ps1 | .\uncat.ps1
    Concatenates *.md files then immediately verifies the archive.

.EXAMPLE
    .\concat.ps1 | .\uncat.ps1 -List
    Concatenates *.md files then verifies with a per-file status table.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline)]
    [string] $Archive,

    [string] $Output,

    [switch] $List,

    [switch] $Force,

    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Show-Help {
    Get-Help -Name $PSCommandPath -Full
    exit 0
}

function Exit-WithError {
    param([string] $Message)
    Write-Error $Message
    exit 1
}

# ── Parameter handling ────────────────────────────────────────────────────────

if ($Help) { Show-Help }

if (-not $Archive -or $Archive -eq '') {
    Exit-WithError 'No archive file specified. Use -Help for usage.'
}

if (-not (Test-Path $Archive)) {
    Exit-WithError "Archive not found: $Archive"
}

$archivePath = [IO.Path]::GetFullPath(
    [IO.Path]::Combine((Get-Location).Path, $Archive))

Write-Verbose "Archive     : $archivePath"

$extractMode = $PSBoundParameters.ContainsKey('Output')
if ($extractMode) {
    if (-not $Output -or $Output -eq '') {
        $Output = $env:TEMP
    }
    $outputDir = [IO.Path]::GetFullPath(
        [IO.Path]::Combine((Get-Location).Path, $Output))
    Write-Verbose "Output dir  : $outputDir"
}

# ── Parse archive ─────────────────────────────────────────────────────────────

Write-Verbose "Reading archive..."
$lines = [IO.File]::ReadAllLines($archivePath, [Text.Encoding]::UTF8)

# Marker patterns.
$reArchiveStart   = '^<!-- ={10,} ARCHIVE HEADER START ={10,} -->$'
$reArchiveEnd     = '^<!-- ={10,} ARCHIVE HEADER END ={10,} -->$'
$reTrailerStart   = '^<!-- ={10,} ARCHIVE TRAILER START ={10,} -->$'
$reTrailerEnd     = '^<!-- ={10,} ARCHIVE TRAILER END ={10,} -->$'
$reFileStart      = '^<!-- ={10,} FILE START ={10,} -->$'
$reFileHeading    = '^# File: (\d+) Path: "([^"]+)"$'
$reFileSize       = '^Size: (\d+) bytes$'
$reFileModified   = '^Last Modified: (.+)$'
$reFileContentStart = '^<!-- ={10,} FILE CONTENT START ={10,} -->$'
$reFileContentEnd   = '^<!-- ={10,} FILE CONTENT END ={10,} -->$'
$reFileEndHeading = '^# END File: (\d+) Path: "([^"]+)"$'
$reFileEnd        = '^<!-- ={10,} FILE END ={10,} -->$'
$reManifestRow    = '^\|\s*(\d+)\s*\|'
$reTrailerCount   = '^# End of Archive: Total Files: (\d+)$'

# ── Pass 1: parse manifest from header ───────────────────────────────────────

$manifestFiles  = [System.Collections.Generic.List[hashtable]]::new()
$inHeader       = $false
$headerFound    = $false
$trailerFound   = $false
$trailerCount   = 0

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]

    if ($line -match $reArchiveStart) {
        $inHeader    = $true
        $headerFound = $true
        continue
    }
    if ($line -match $reArchiveEnd) {
        $inHeader = $false
        continue
    }
    if ($inHeader -and $line -match $reManifestRow) {
        $cols = $line -split '\|' | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' }
        if ($cols.Count -ge 4 -and $cols[0] -match '^\d+$') {
            $manifestFiles.Add(@{
                Num      = [int]$cols[0]
                Modified = $cols[1]
                Bytes    = [int]$cols[2]
                RelPath  = $cols[3].Trim('"')
            })
        }
    }
    if ($line -match $reTrailerStart) {
        # Peek ahead for the count line.
        if (($i + 1) -lt $lines.Count -and
            $lines[$i + 1] -match $reTrailerCount) {
            $trailerCount = [int]$Matches[1]
        }
        $trailerFound = $true
    }
}

if (-not $headerFound) {
    Exit-WithError ('Archive header not found. ' +
                   'File may be corrupt or not a concat archive.')
}
if (-not $trailerFound) {
    Exit-WithError 'Archive trailer not found. File may be truncated.'
}

Write-Verbose "Manifest    : $($manifestFiles.Count) entries"
Write-Verbose "Trailer     : reports $trailerCount file(s)"

# ── Pass 2: parse file blocks ─────────────────────────────────────────────────

$fileBlocks = [System.Collections.Generic.List[hashtable]]::new()
$i          = 0

while ($i -lt $lines.Count) {
    if ($lines[$i] -notmatch $reFileStart) { $i++; continue }

    # FILE START found — read heading line.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileHeading) {
        Exit-WithError "Malformed file heading at line $($i + 1)."
    }
    $fileNum  = [int]$Matches[1]
    $relPath  = $Matches[2]

    # Size line.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileSize) {
        Exit-WithError "Malformed size line at line $($i + 1)."
    }
    $headerBytes = [int]$Matches[1]

    # Last Modified line.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileModified) {
        Exit-WithError "Malformed Last Modified line at line $($i + 1)."
    }

    # FILE CONTENT START.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileContentStart) {
        Exit-WithError "Missing FILE CONTENT START at line $($i + 1)."
    }
    $i++

    # Collect content lines until FILE CONTENT END.
    $contentLines = [System.Collections.Generic.List[string]]::new()
    while ($i -lt $lines.Count -and $lines[$i] -notmatch $reFileContentEnd) {
        $contentLines.Add($lines[$i])
        $i++
    }
    if ($i -ge $lines.Count) {
        Exit-WithError "Missing FILE CONTENT END for file $fileNum '$relPath'."
    }

    # FILE CONTENT END found — read END heading.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileEndHeading) {
        Exit-WithError "Malformed END heading at line $($i + 1)."
    }
    $endFileNum = [int]$Matches[1]
    $endRelPath = $Matches[2]

    # Trailer size line.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileSize) {
        Exit-WithError "Malformed trailer size line at line $($i + 1)."
    }
    $trailerBytes = [int]$Matches[1]

    # FILE END.
    $i++
    if ($i -ge $lines.Count -or $lines[$i] -notmatch $reFileEnd) {
        Exit-WithError "Missing FILE END marker at line $($i + 1)."
    }
    $i++

    # Normalize content: trim trailing blank lines, add one LF.
    $content = ($contentLines -join "`n").TrimEnd("`n") + "`n"
    $contentBytes = [Text.Encoding]::UTF8.GetByteCount($content)

    $fileBlocks.Add(@{
        Num           = $fileNum
        RelPath       = $relPath
        HeaderBytes   = $headerBytes
        TrailerBytes  = $trailerBytes
        ContentBytes  = $contentBytes
        EndFileNum    = $endFileNum
        EndRelPath    = $endRelPath
        Content       = $content
    })
}

Write-Verbose "File blocks : $($fileBlocks.Count) parsed"

# ── Verification ──────────────────────────────────────────────────────────────

$errors     = [System.Collections.Generic.List[string]]::new()
$maxErrors  = 10

function Add-Error {
    param([string] $Message)
    if ($errors.Count -lt $maxErrors) {
        $errors.Add($Message)
    }
}

# Manifest count vs trailer count.
if ($manifestFiles.Count -ne $trailerCount) {
    Add-Error ("Manifest has $($manifestFiles.Count) entries but " +
               "trailer reports $trailerCount.")
}

# File block count vs manifest count.
if ($fileBlocks.Count -ne $manifestFiles.Count) {
    Add-Error ("Manifest has $($manifestFiles.Count) entries but " +
               "$($fileBlocks.Count) file block(s) were found.")
}

# Per-file checks.
$listRows = [System.Collections.Generic.List[hashtable]]::new()

foreach ($block in $fileBlocks) {
    if ($errors.Count -ge $maxErrors) { break }

    $status = 'OK'
    $notes  = ''

    # Header/trailer file number consistency.
    if ($block.EndFileNum -ne $block.Num) {
        Add-Error ("File $($block.Num): END marker shows file number " +
                   "$($block.EndFileNum).")
        $status = 'FAIL'
    }

    # Header/trailer path consistency.
    if ($block.EndRelPath -ne $block.RelPath) {
        Add-Error ("File $($block.Num): END marker path" +
                   " '$($block.EndRelPath)' does not match" +
                   " header '$($block.RelPath)'.")  
        $status = 'FAIL'
    }

    # Header size vs actual content.
    if ($block.HeaderBytes -ne $block.ContentBytes) {
        Add-Error ("File $($block.Num) '$($block.RelPath)': header size " +
                   "$($block.HeaderBytes) but content is " +
                   "$($block.ContentBytes) bytes.")
        $status = 'FAIL'
    }

    # Trailer size vs actual content.
    if ($block.TrailerBytes -ne $block.ContentBytes) {
        Add-Error ("File $($block.Num) '$($block.RelPath)': trailer size " +
                   "$($block.TrailerBytes) but content is " +
                   "$($block.ContentBytes) bytes.")
        $status = 'FAIL'
    }

    # Header size vs trailer size.
    if ($block.HeaderBytes -ne $block.TrailerBytes) {
        Add-Error ("File $($block.Num) '$($block.RelPath)': header size " +
                   "$($block.HeaderBytes) disagrees with trailer size " +
                   "$($block.TrailerBytes).")
        $status = 'FAIL'
    }

    if ($status -eq 'FAIL' -and $notes -eq '') { $notes = 'see errors' }

    $listRows.Add(@{
        Num     = $block.Num
        Bytes   = $block.ContentBytes
        Status  = $status
        Path    = $block.RelPath
    })
}

# ── Extract mode: overwrite check ─────────────────────────────────────────────

if ($extractMode -and $errors.Count -eq 0) {
    $conflicts = $fileBlocks | Where-Object {
        $destPath = [IO.Path]::Combine(
            $outputDir,
            $_.RelPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Test-Path $destPath
    }

    if ($conflicts -and -not $Force) {
        Write-Host ''
        Write-Host "The following files already exist in $outputDir :"
        foreach ($c in $conflicts) {
            Write-Host "  $($c.RelPath)"
        }
        Write-Host ''
        $answer = Read-Host 'Overwrite? [Y/N]'
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Extraction cancelled.'
            exit 0
        }
    }
}

# ── Print list table if requested ─────────────────────────────────────────────

if ($List) {
    Write-Host ''
    Write-Host ('| {0,-4} | {1,8} | {2,-6} | {3}' -f
        '#', 'Bytes', 'Status', 'Relative Path')
    Write-Host ('| {0,-4} | {1,8} | {2,-6} | {3}' -f
        '----', '--------', '------', '-------------')
    foreach ($row in $listRows) {
        Write-Host ('| {0,-4} | {1,8} | {2,-6} | "{3}"' -f
            $row.Num, $row.Bytes, $row.Status, $row.Path)
    }
    Write-Host ''
}

# ── Halt if verification errors found ────────────────────────────────────────

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host "Verification failed with $($errors.Count) error(s):"
    foreach ($e in $errors) {
        Write-Host "  ERROR: $e"
    }
    if ($errors.Count -ge $maxErrors) {
        Write-Host "  (halted after $maxErrors errors)"
    }
    Write-Host ''
    exit 1
}

# ── Extract files ─────────────────────────────────────────────────────────────

if ($extractMode) {
    if (-not (Test-Path $outputDir)) {
        [void] (New-Item -ItemType Directory -Path $outputDir -Force)
        Write-Verbose "Created     : $outputDir"
    }

    foreach ($block in $fileBlocks) {
        $destPath = [IO.Path]::Combine(
            $outputDir,
            $block.RelPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $destDir  = [IO.Path]::GetDirectoryName($destPath)

        if (-not (Test-Path $destDir)) {
            [void] (New-Item -ItemType Directory -Path $destDir -Force)
            Write-Verbose "Created dir : $destDir"
        }

        Write-Verbose "Extracting  : $($block.RelPath)"
        [IO.File]::WriteAllText(
            $destPath,
            $block.Content,
            (New-Object Text.UTF8Encoding $false))   # UTF-8, no BOM
    }

    Write-Host "Extracted $($fileBlocks.Count) file(s) to:"
    Write-Host "  $outputDir"
}
else {
    # Verify mode summary.
    Write-Host "Verified $($fileBlocks.Count) file(s). All checks passed."
    Write-Host "  $archivePath"
}
