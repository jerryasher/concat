#Requires -Version 5.1

<#
.SYNOPSIS
    Concatenates multiple Markdown files into a single LLM-friendly archive.

.DESCRIPTION
    Produces a single UTF-8/LF text archive containing multiple Markdown files,
    wrapped in XML-style markers with redundant metadata. The archive is
    designed for ingestion by large language models such as Claude, ChatGPT,
    and Gemini.

    Files are validated for UTF-8 encoding before processing. If any file fails
    validation the script aborts immediately and produces no output.

    All paths in the archive use forward slashes regardless of platform.
    All paths are resolved relative to the caller's PowerShell working
    directory (Get-Location). The location of concat.ps1 itself has no
    effect on where output is written or how paths are computed.

.PARAMETER Files
    One or more filenames or wildcard patterns to include. Defaults to
    "*.md" if omitted. Patterns are resolved relative to the current
    working directory. Wildcard results are sorted alphabetically
    (case-insensitive). Explicit filenames preserve the order given.

.PARAMETER Output
    Output filename or path. Defaults to Handbook.md, written to the
    current working directory.

.PARAMETER Exclude
    Comma-separated list of relative paths to skip. Both forward and back
    slashes are accepted; all comparisons use forward slashes.
    Example: "docs/README.md,LICENSE.md"

.PARAMETER Limit
    Maximum number of files to process. Defaults to unlimited.

.PARAMETER WhatIf
    Dry-run mode. Displays the resolved output path and the manifest of
    files that would be processed, in order. No output file is written.

.PARAMETER List
    Prints a per-file manifest table after writing the archive. Shows file
    number, normalized byte count, and relative path for each file written.

.PARAMETER Help
    Displays this help and exits.

.EXAMPLE
    .\concat.ps1
    Concatenates all *.md files in the current directory into Handbook.md.

.EXAMPLE
    .\concat.ps1 -Output Homelab.md
    Concatenates all *.md files into Homelab.md.

.EXAMPLE
    .\concat.ps1 docs/*.md *.md -Exclude "README.md,docs/scratch.md"
    Concatenates matching files, skipping the two excluded paths.

.EXAMPLE
    .\concat.ps1 -Limit 5 -WhatIf
    Shows which files would be processed (up to 5), without writing output.

.EXAMPLE
    .\concat.ps1 -List
    Concatenates *.md files and prints a per-file manifest table.

.EXAMPLE
    .\concat.ps1 -List | .\uncat.ps1 -List
    Concatenates, prints manifest, then verifies with per-file status.

.EXAMPLE
    .\concat.ps1 | .\uncat.ps1
    Concatenates *.md files then immediately verifies the archive.

.EXAMPLE
    .\concat.ps1 | .\uncat.ps1 -List
    Concatenates *.md files then verifies with a per-file status table.

#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Files,

    [Alias('O')]
    [string] $Output = 'Handbook.md',

    [string] $Exclude = '',

    [int] $Limit = 0,

    [switch] $List,

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

# Resolve output path relative to PowerShell CWD, not .NET CWD.
function Resolve-OutputPath {
    param([string] $OutputParam)
    if ([IO.Path]::IsPathRooted($OutputParam)) {
        return $OutputParam
    }
    return [IO.Path]::Combine((Get-Location).Path, $OutputParam)
}

# Canonicalize a path to a forward-slash relative path from PS CWD.
function Get-RelativePath {
    param([string] $FullPath)
    $cwd = (Get-Location).Path.TrimEnd(
               [IO.Path]::DirectorySeparatorChar) +
           [IO.Path]::DirectorySeparatorChar
    $rel = if ($FullPath.StartsWith(
                   $cwd, [StringComparison]::OrdinalIgnoreCase)) {
               $FullPath.Substring($cwd.Length)
           }
           else {
               $FullPath
           }
    return $rel.Replace('\', '/')
}

# Validate that a file's raw bytes are valid UTF-8. Returns nothing on
# success; throws a descriptive string on the first invalid sequence.
function Assert-ValidUtf8 {
    param([string] $FullPath)

    $bytes   = [IO.File]::ReadAllBytes($FullPath)
    $lineNum = 1
    $i       = 0

    while ($i -lt $bytes.Length) {
        $b = $bytes[$i]

        if      ($b -lt 0x80) { $seqLen = 1 }
        elseif  ($b -lt 0xC2) {
            throw ("Invalid UTF-8 in '$FullPath' at line $lineNum, " +
                   "byte $i (unexpected continuation or overlong " +
                   "byte 0x$("{0:X2}" -f $b))")
        }
        elseif  ($b -lt 0xE0) { $seqLen = 2 }
        elseif  ($b -lt 0xF0) { $seqLen = 3 }
        elseif  ($b -le 0xF4) { $seqLen = 4 }
        else {
            throw ("Invalid UTF-8 in '$FullPath' at line $lineNum, " +
                   "byte $i (byte 0x$("{0:X2}" -f $b) out of range)")
        }

        for ($j = 1; $j -lt $seqLen; $j++) {
            if (($i + $j) -ge $bytes.Length -or
                ($bytes[$i + $j] -band 0xC0) -ne 0x80) {
                throw ("Invalid UTF-8 in '$FullPath' at line $lineNum, " +
                       "byte $($i + $j) (bad continuation byte)")
            }
        }

        if ($b -eq 0x0A) { $lineNum++ }
        $i += $seqLen
    }
}

# Read a file, validate UTF-8, normalize CRLF -> LF.
# Returns hashtable with Content and NormBytes.
function Read-NormalizedFile {
    param([string] $FullPath)

    Assert-ValidUtf8 -FullPath $FullPath

    $raw        = [IO.File]::ReadAllText($FullPath, [Text.Encoding]::UTF8)
    $normalized = $raw.Replace("`r`n", "`n").Replace("`r", "`n")
    $normBytes  = [Text.Encoding]::UTF8.GetByteCount($normalized)

    return @{ Content = $normalized; NormBytes = $normBytes }
}

# Format a DateTime as the friendly archive date string.
function Format-ArchiveDate {
    param([datetime] $Date)
    return $Date.ToString('yyyy-MM-dd HH:mm:ss')
}

# Append a line to a StringBuilder with LF line ending.
# $Builder is passed explicitly; PS 5.1 functions do not reliably
# close over script-scope variables.
function Add-Line {
    param(
        [System.Text.StringBuilder] $Builder,
        [string] $Text = ''
    )
    [void] $Builder.Append($Text)
    [void] $Builder.Append("`n")
}

# ── Parameter handling ────────────────────────────────────────────────────────

if ($Help) { Show-Help }

if (-not $Files -or $Files.Count -eq 0) {
    $Files = @('*.md')
}

# Resolve output path now, anchored to PS CWD.
$resolvedOutput = Resolve-OutputPath $Output
Write-Verbose "Output path : $resolvedOutput"
Write-Verbose "Working dir : $(Get-Location)"

# Build the exclude set (forward-slash canonicalized).
$excludeSet = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)

if ($Exclude -ne '') {
    foreach ($e in ($Exclude -split ',')) {
        $trimmed = $e.Trim().Replace('\', '/')
        if ($trimmed -ne '') { [void] $excludeSet.Add($trimmed) }
    }
}

if ($excludeSet.Count -gt 0) {
    Write-Verbose "Excluding   : $($excludeSet -join ', ')"
}

# ── Resolve file list ─────────────────────────────────────────────────────────

$resolvedFiles = New-Object `
    'System.Collections.Generic.List[System.IO.FileInfo]'

foreach ($pattern in $Files) {
    $wcType  = [System.Management.Automation.WildcardPattern]
    $isWildcard = $wcType::ContainsWildcardCharacters($pattern)
    $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue |
             Where-Object { -not $_.PSIsContainer }
    if ($found) {
        if ($isWildcard) {
            # Sort wildcard expansions alphabetically, case-insensitive.
            $found = $found | Sort-Object -Property Name
        }
        foreach ($f in $found) { $resolvedFiles.Add($f) }
    }
}

Write-Verbose "Files found : $($resolvedFiles.Count)"

# Deduplicate by full path while preserving order.
$seen = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)
$dedupedFiles = New-Object `
    'System.Collections.Generic.List[System.IO.FileInfo]'

foreach ($f in $resolvedFiles) {
    if ($seen.Add($f.FullName)) { $dedupedFiles.Add($f) }
}

# Apply exclusions.
$filteredFiles = $dedupedFiles |
    Where-Object { -not $excludeSet.Contains((Get-RelativePath $_.FullName)) }

$excludedCount = $dedupedFiles.Count - @($filteredFiles).Count
if ($excludedCount -gt 0) {
    Write-Verbose "Excluded    : $excludedCount file(s)"
}

# Apply limit.
if ($Limit -gt 0) {
    $filteredFiles = $filteredFiles | Select-Object -First $Limit
    Write-Verbose "Limit       : $Limit applied"
}

$filteredFiles = @($filteredFiles)

if ($filteredFiles.Count -eq 0) {
    Write-Host 'No files found. Exiting.'
    exit 1
}

Write-Verbose "Processing  : $($filteredFiles.Count) file(s)"

# ── Build file metadata ───────────────────────────────────────────────────────
# Validate UTF-8 eagerly for all files before writing anything.

$fileEntries = New-Object 'System.Collections.Generic.List[hashtable]'

foreach ($f in $filteredFiles) {
    $relPath = Get-RelativePath $f.FullName
    Write-Verbose "Validating  : $relPath"

    try {
        $normalized = Read-NormalizedFile -FullPath $f.FullName
    }
    catch {
        Exit-WithError "Encoding error: $_"
    }

    Write-Verbose "  OK $($normalized.NormBytes) bytes (normalized)"

    $fileEntries.Add(@{
        RelPath      = $relPath
        ModifiedDate = Format-ArchiveDate $f.LastWriteTime
        NormBytes    = $normalized.NormBytes
        Content      = $normalized.Content
    })
}

# ── WhatIf / dry-run ──────────────────────────────────────────────────────────

if ($WhatIfPreference) {
    $totalFiles = $fileEntries.Count
    Write-Host ''
    Write-Host 'WhatIf: no output file will be written.'
    Write-Host "Output would be written to:"
    Write-Host "  $resolvedOutput"
    Write-Host ''
    Write-Host 'Files that would be processed:'
    Write-Host ''
    Write-Host ('| {0,-4} | {1,-19} | {2,8} | {3}' -f
        '#', 'Modification Date', 'Bytes', 'Relative Path')
    Write-Host ('| {0,-4} | {1,-19} | {2,8} | {3}' -f
        '----', '-------------------', '--------', '-------------')
    $num = 1
    foreach ($entry in $fileEntries) {
        Write-Host ('| {0,-4} | {1,-19} | {2,8} | "{3}"' -f
            $num, $entry.ModifiedDate, $entry.NormBytes, $entry.RelPath)
        $num++
    }
    Write-Host ''
    Write-Host "Total files: $totalFiles"
    Write-Host ''
    exit 0
}

# ── Build archive in memory ───────────────────────────────────────────────────

$sb         = [System.Text.StringBuilder]::new()
$totalFiles = $fileEntries.Count
$divider    = '<!-- ========== {0} ========== -->'

# ── Archive header ────────────────────────────────────────────────────────────

Add-Line $sb ($divider -f 'ARCHIVE HEADER START')
Add-Line $sb
# Archive description prose; long lines are intentional output text.
Add-Line $sb 'Description:'
Add-Line $sb 'This archive contains multiple UTF-8/LF normalized text files concatenated into'
Add-Line $sb 'a single linear stream. Each file is wrapped in XML-style markers with redundant'
Add-Line $sb 'metadata to help LLMs reliably separate content.'
Add-Line $sb
Add-Line $sb 'Manifest:'
Add-Line $sb ('| {0,-4} | {1,-19} | {2,8} | {3}' -f
    '#', 'Modification Date', 'Bytes', 'Relative Path')
Add-Line $sb ('| {0,-4} | {1,-19} | {2,8} | {3}' -f
    '----', '-------------------', '--------', '-------------')

$num = 1
foreach ($entry in $fileEntries) {
    Add-Line $sb ('| {0,-4} | {1,-19} | {2,8} | "{3}"' -f
        $num, $entry.ModifiedDate, $entry.NormBytes, $entry.RelPath)
    $num++
}

Add-Line $sb
Add-Line $sb ($divider -f 'ARCHIVE HEADER END')
Add-Line $sb

# ── Per-file blocks ───────────────────────────────────────────────────────────

$num = 1
foreach ($entry in $fileEntries) {
    Add-Line $sb ($divider -f 'FILE START')
    Add-Line $sb "# File: $num Path: `"$($entry.RelPath)`""
    Add-Line $sb "Size: $($entry.NormBytes) bytes"
    Add-Line $sb "Last Modified: $($entry.ModifiedDate)"
    Add-Line $sb ($divider -f 'FILE CONTENT START')

    $content = $entry.Content.TrimEnd("`n")
    [void] $sb.Append($content)
    [void] $sb.Append("`n")

    Add-Line $sb ($divider -f 'FILE CONTENT END')
    Add-Line $sb "# END File: $num Path: `"$($entry.RelPath)`""
    Add-Line $sb "Size: $($entry.NormBytes) bytes"
    Add-Line $sb ($divider -f 'FILE END')
    Add-Line $sb

    $num++
}

# ── Archive trailer ───────────────────────────────────────────────────────────

Add-Line $sb ($divider -f 'ARCHIVE TRAILER START')
Add-Line $sb "# End of Archive: Total Files: $totalFiles"
Add-Line $sb 'This marks the end of the concatenated archive.'
Add-Line $sb ($divider -f 'ARCHIVE TRAILER END')

# ── Write output ──────────────────────────────────────────────────────────────

$archiveText = $sb.ToString()

Write-Verbose "Writing     : $resolvedOutput"

try {
    [IO.File]::WriteAllText(
        $resolvedOutput,
        $archiveText,
        (New-Object Text.UTF8Encoding $false)   # UTF-8, no BOM
    )
}
catch {
    Exit-WithError "Failed to write output file: $_"
}

# Verify the file was actually written and is non-empty.
if (-not (Test-Path $resolvedOutput)) {
    Exit-WithError "Output file not found after write: $resolvedOutput"
}
$writtenSize = (Get-Item $resolvedOutput).Length
if ($writtenSize -eq 0) {
    Exit-WithError "Output file is empty after write: $resolvedOutput"
}

Write-Verbose "Verified    : $writtenSize bytes on disk"
Write-Host "Wrote $totalFiles file(s) to:"
Write-Host "  $resolvedOutput"

if ($List) {
    Write-Host ''
    Write-Host ('| {0,-4} | {1,8} | {2}' -f
        '#', 'Bytes', 'Relative Path')
    Write-Host ('| {0,-4} | {1,8} | {2}' -f
        '----', '--------', '-------------')
    $num = 1
    foreach ($entry in $fileEntries) {
        Write-Host ('| {0,-4} | {1,8} | "{2}"' -f
            $num, $entry.NormBytes, $entry.RelPath)
        $num++
    }
    Write-Host ''
}

Write-Output $resolvedOutput
