# LLM‑Friendly Concatenated Archive Format (v5.4)

This repository contains a PowerShell script (`concat.ps1`) that produces a
single UTF‑8/LF text archive containing multiple Markdown files. The archive
is designed specifically for ingestion by large language models (LLMs) such as
Microsoft Copilot, Claude, ChatGPT, and Gemini.

The format avoids binary containers (ZIP, TAR) and instead uses a linear,
self‑describing text structure with explicit XML‑style markers and redundant
metadata. This ensures that LLMs can reliably separate files, reconstruct
boundaries, and understand the archive's structure.

A companion script (`uncat.ps1`) verifies or extracts the archive.

## Requirements

### PowerShell Version
Requires **PowerShell 5.1**. No external modules or dependencies.

### Core Behavior
- Concatenate selected files into a single output file.
- Works on ASCII and UTF-8 files; output is UTF-8 (no BOM).
- Normalize line endings to LF.
- Provide a manifest of files.
- Preserve the order in which files are specified.
- Wildcard expansions are sorted alphabetically, case-insensitive.
- Support explicit filenames and wildcard patterns.
- **If no file arguments are provided, default to `"*.md"`**.
- Starts with a standardized header.
- Files are denoted with standardized delimiter blocks.
- Ends with a standardized trailer.

## Path Resolution

All paths are resolved relative to the caller's PowerShell working directory
(`Get-Location`). The location of `concat.ps1` itself MUST NOT influence
where output is written or how relative paths are computed.

Input paths MUST be canonicalized to backslashes before comparing against
`Get-Location`, because `Get-Item` preserves whatever separator style was
used on the command line. Mixing `..\` and `../` arguments would otherwise
cause segment comparison to fail, producing absolute paths in the
manifest instead of relative ones.

All paths stored in the archive MUST use forward slashes regardless of
how they were specified on the command line.

### Tar-Like Relative Paths

Relative paths in the manifest MUST be computed the way `tar` would
express them: the shortest path, relative to the current working
directory, that reaches the file — using leading `../` segments for
files outside the working directory's subtree, rather than collapsing
them to an absolute path.

This is computed by comparing the path segments of the resolved absolute
file path against the path segments of the current working directory,
finding the longest shared prefix, and then emitting one `..` for each
remaining working-directory segment followed by the remaining file
segments. A file directly inside (or beneath) the working directory
therefore has no leading `..`; a file in a sibling or ancestor directory
does.

If the file and the working directory do not share a common root at all
(for example, the file is on a different drive letter on Windows), no
relative path can express the relationship. In that case the full
absolute path is stored instead, normalized to forward slashes.

Example: running the script from a different directory still writes output
to the caller's working directory, and relative paths are stored correctly
regardless of input separator style:

```powershell
Set-Location C:\Projects\Homelab
..\tools\concat.ps1 ..\docs\setup.md ../notes.md
# writes C:\Projects\Homelab\Handbook.md
# manifest stores: "../docs/setup.md" and "../notes.md"
```

Example of files reached from a subdirectory, mixing separator styles:

```powershell
Set-Location C:\me\workspace\concat\foo
..\concat.ps1 ..\lorem.md ../LICENSE
# manifest stores: "../lorem.md" and "../LICENSE"
```


## Parameters

- **`-Output` / `-O`**
  Output filename. Defaults to `Handbook.md`, written to the current
  working directory.

- **`-WhatIf`**
  Dry-run mode. Displays the resolved output path and the manifest of
  files that would be processed, in order. No output file is written.
  Exit code is 0.

- **`-List`**
  Prints a per-file manifest table after writing the archive, showing
  file number, normalized byte count, and relative path for each file.

- **`-Verbose`**
  Prints diagnostics including: resolved output path, working directory,
  file counts (discovered / excluded / processed), per-file UTF-8
  validation results, and post-write verification.

- **`-Limit`**
  Restricts how many files are processed. Defaults to unlimited.

- **`-Exclude`**
  Comma‑separated list of relative paths to skip. Both forward and back
  slashes are accepted. Example: `"docs/README.md,LICENSE.md"`

- **`-Help`**
  Shows help and exits.

- **File list parameter**
  Accepts explicit filenames and wildcards. Defaults to `"*.md"` if
  omitted.

## Processing Order

Implementations MUST process files in this order:

1. Expand wildcards (sorted alphabetically, case-insensitive).
2. Remove excluded files.
3. Deduplicate (preserve first occurrence).
4. Apply `-Limit`.
5. Validate UTF-8 (fail-fast; no output written if any file fails).
6. Build and write archive.

## Encoding Requirements

### Normalization
All input and output must be normalized to:
- **UTF‑8 (no BOM)**
- **LF line endings**

### UTF‑8 Validation (Fail‑Fast)
If any file contains invalid UTF‑8:
- Stop immediately.
- Print error with file name, line number, and byte position.
- Produce no output file.
- Exit with non‑zero status.

## Success Conditions

A successful run MUST:

1. Create the output file.
2. Verify the output file exists and is non-empty after writing.
3. Print the fully resolved output path.
4. Print the number of files written.
5. Exit with code 0.

Example output:

```
Wrote 13 file(s) to:
  C:\me\workspace\Homelab\Handbook.md
```

## No Files Found

If no files match the provided patterns (after exclusions and limit):
- Print: `No files found. Exiting.`
- Exit with code 1.
- No output file is created.

## Edge Case Behavior

### Relative Output Path
The output file is always written relative to the PowerShell working
directory, not the script's location.

Given:
```
Current directory: C:\Work
Script location:   C:\Tools\concat.ps1
```
Running:
```powershell
C:\Tools\concat.ps1
```
Produces: `C:\Work\Handbook.md`

### WhatIf Shows Resolved Path
`-WhatIf` must display the fully resolved output path so the caller can
verify where the file *would* have been written:

```
WhatIf: no output file will be written.
Output would be written to:
  C:\Work\Handbook.md
```

## Archive Structure

The generated archive contains:

1. **Global Archive Header**
2. **Manifest Table**
3. **Repeated File Blocks**
   - File Header
   - File Content
   - File Trailer
4. **Global Archive Trailer**

Notes:

1. All structural markers use XML‑style comments:

```
<!-- ========== SECTION NAME ========== -->
```

2. Each delimiter block consists of an opening XML comment, a single `#`
   heading line (which renders as a navigable heading in Markdown editors
   such as MarkText), and a closing XML comment.

3. All file paths are relative, use forward slashes, and are enclosed in
   double quotes to protect spaces.

4. File content begins immediately after the `FILE CONTENT START` marker
   line and ends immediately before the `FILE CONTENT END` marker line.
   The `Size` byte count reflects the content bytes exactly.


## Global Archive Header

The archive header is a template. All `$PLACEHOLDER` tokens must be
substituted with actual values at archive generation time. The manifest
table must contain one row per file included in the archive.

```
<!-- ========== ARCHIVE HEADER START ========== -->

Description:
This archive contains multiple UTF-8/LF normalized text files concatenated into
a single linear stream. Each file is wrapped in XML-style markers with redundant
metadata to help LLMs reliably separate content.

Manifest:
| #           | Modification Date   | Bytes         | Relative Path         |
|-------------|---------------------|---------------|-----------------------|
| $FILE_NUM   | $MODIFIED_DATE      | $NORM_BYTES   | "$REL_PATH"           |
| $FILE_NUM   | $MODIFIED_DATE      | $NORM_BYTES   | "$REL_PATH"           |
| ...         | ...                 | ...           | ...                   |

<!-- ========== ARCHIVE HEADER END ========== -->
```

Example with real values:

```
<!-- ========== ARCHIVE HEADER START ========== -->

Description:
This archive contains multiple UTF-8/LF normalized text files concatenated into
a single linear stream. Each file is wrapped in XML-style markers with redundant
metadata to help LLMs reliably separate content.

Manifest:
| #  | Modification Date   | Bytes | Relative Path          |
|----|---------------------|-------|------------------------|
|  1 | 2025-11-03 14:22:00 |  4821 | "docs/setup.md"        |
|  2 | 2025-11-03 09:10:00 |  1203 | "README.md"            |
| ...| ...                 | ...   | ...                    |

<!-- ========== ARCHIVE HEADER END ========== -->
```

---

## Per‑File Header

Each file begins with a header block. All `$PLACEHOLDER` tokens must be
substituted with actual values. All pathnames are relative and enclosed in
double quotes to protect spaces.

```
<!-- ========== FILE START ========== -->
# File: $FILE_NUM Path: "$REL_PATH"
Size: $NORM_BYTES bytes
Last Modified: $MODIFIED_DATE
<!-- ========== FILE CONTENT START ========== -->
```

Example with real values:

```
<!-- ========== FILE START ========== -->
# File: 1 Path: "docs/setup.md"
Size: 4821 bytes
Last Modified: 2025-11-03 14:22:00
<!-- ========== FILE CONTENT START ========== -->
```

## Per‑File Trailer

Each file ends with a trailer block that mirrors the header values for
verification. All `$PLACEHOLDER` tokens must be substituted with the same
values used in the corresponding file header.

```
<!-- ========== FILE CONTENT END ========== -->
# END File: $FILE_NUM Path: "$REL_PATH"
Size: $NORM_BYTES bytes
<!-- ========== FILE END ========== -->
```

Example with real values:

```
<!-- ========== FILE CONTENT END ========== -->
# END File: 1 Path: "docs/setup.md"
Size: 4821 bytes
<!-- ========== FILE END ========== -->
```

---

## Global Archive Trailer

The archive ends with a trailer. `$TOTAL_FILES` must be substituted with
the total number of files written to the archive.

```
<!-- ========== ARCHIVE TRAILER START ========== -->
# End of Archive: Total Files: $TOTAL_FILES
This marks the end of the concatenated archive.
<!-- ========== ARCHIVE TRAILER END ========== -->
```

Example with real values:

```
<!-- ========== ARCHIVE TRAILER START ========== -->
# End of Archive: Total Files: 17
This marks the end of the concatenated archive.
<!-- ========== ARCHIVE TRAILER END ========== -->
```

---

## Example Usage

Concatenate all Markdown files:

```powershell
.\concat.ps1
```

Specify output:

```powershell
.\concat.ps1 -Output Homelab.md
```

Exclude files:

```powershell
.\concat.ps1 -Exclude "README.md,LICENSE.md"
```

Limit number of files:

```powershell
.\concat.ps1 -Limit 5
```

Print per-file manifest table after writing:

```powershell
.\concat.ps1 -List
```

Concatenate, print manifest, then verify:

```powershell
.\concat.ps1 -List | .\uncat.ps1 -List
```

Dry run with verbose diagnostics:

```powershell
.\concat.ps1 -WhatIf -Verbose
```

Show help:

```powershell
.\concat.ps1 -Help
```

---

# uncat.ps1

`uncat.ps1` is the companion script to `concat.ps1`. It reads a concat
archive and either verifies its integrity or extracts its files.

## uncat.ps1 Requirements

### PowerShell Version
Requires **PowerShell 5.1**. No external modules or dependencies.

### Core Behavior
- Without `-Output`: verify mode. Parses the archive, checks all file
  blocks, and confirms content byte counts match the `Size` fields in
  both file header and trailer.
- With `-Output <dir>`: extract mode. Recreates files and subdirectory
  structure under the specified directory.
- With `-WhatIf`: dry-run mode. Reports the archive path and manifest
  (and, with `-Output`, destination paths) without verifying, reading
  file blocks, or writing anything.
- Reports up to 10 verification errors before halting.
- Exits 0 on success, 1 on any verification or extraction failure.
- Accepts the archive path from the pipeline for use with `concat.ps1`.

## uncat.ps1 Parameters

- **`-Archive`** (positional, pipeline)
  Path to the archive file. Accepts pipeline input from `concat.ps1`.

- **`-Output <dir>`**
  Directory to extract files into. Created if it does not exist.
  Defaults to `$env:TEMP` if the switch is provided without a value.
  If omitted entirely, runs in verify mode.

- **`-WhatIf`**
  Dry-run mode. Shows the resolved archive path and the manifest
  (file number, bytes, relative path) without verifying or extracting
  anything. If `-Output` is also given, additionally shows the fully
  resolved destination path each file would be extracted to. No file
  I/O occurs beyond reading the archive header/manifest. Exit code 0.

- **`-List`**
  Prints a per-file status table in addition to the summary. Valid in
  both verify and extract modes.

- **`-Force`**
  Suppresses the overwrite prompt during extraction.

- **`-Verbose`**
  Prints internal diagnostics: resolved paths, directory creation,
  per-file extraction progress.

- **`-Help`**
  Shows help and exits.

## Verification Checks

In verify mode, `uncat.ps1` MUST confirm:

1. Archive header and trailer are present and well-formed.
2. Trailer `Total Files` count matches the manifest entry count.
3. File block count matches the manifest entry count.
4. Each file block's END marker file number matches its START.
5. Each file block's END marker path matches its START.
6. Each file block's header `Size` matches the actual content byte count.
7. Each file block's trailer `Size` matches the actual content byte count.
8. Header and trailer `Size` values agree with each other.

On failure, up to 10 errors are reported before halting. Exit code is 1.

On success:

```
Verified 14 file(s). All checks passed.
  C:\me\workspace\Homelab\Handbook.md
```

## Extraction Behavior

If any target files already exist, `uncat.ps1` MUST display a
consolidated list of all conflicts and prompt once before proceeding:

```
The following files already exist in C:\restore:
  docs/setup.md
  README.md

Overwrite? [Y/N]:
```

`-Force` suppresses the prompt. On successful extraction:

```
Extracted 14 file(s) to:
  C:\restore
```

## WhatIf Mode

`-WhatIf` is a dry run: it parses only the archive header/manifest (no
file blocks are parsed, no directories are created, no files are written
or read for extraction) and reports what would happen.

In verify mode (`-Output` omitted):

```
WhatIf: no verification or extraction will be performed.
Archive to be read:
  C:\me\workspace\Homelab\Handbook.md

Manifest:

| #    |    Bytes | Relative Path
| ---- | -------- | -------------
|    1 |     4821 | "docs/setup.md"
|    2 |     1203 | "README.md"
```

In extract mode (`-Output` given), each manifest row additionally shows
the fully resolved destination path:

```
WhatIf: no verification or extraction will be performed.
Archive to be read:
  C:\me\workspace\Homelab\Handbook.md

Files would be extracted to:
  C:\restore

| #    |    Bytes | Relative Path            | Destination
| ---- | -------- | ------------------------ | -----------
|    1 |     4821 | "docs/setup.md"          | C:\restore\docs\setup.md
|    2 |     1203 | "README.md"              | C:\restore\README.md
```

Exit code is 0 in both cases.

## Pipeline Usage

`concat.ps1` emits the resolved output path via `Write-Output` on
success, enabling direct piping to `uncat.ps1`:

```powershell
# Concatenate then immediately verify:
.\concat.ps1 | .\uncat.ps1

# Concatenate, verify, and print per-file status:
.\concat.ps1 | .\uncat.ps1 -List

# Concatenate then extract to a restore directory:
.\concat.ps1 | .\uncat.ps1 -Output C:\restore
```

## Self-Test

The recommended self-test is to run `concat.ps1` on its own source files
and pipe the result directly to `uncat.ps1`:

```powershell
Set-Location C:\me\concat
.\concat.ps1 "concat.ps1" "uncat.ps1" "README.md" -Output self-test.md -List | .\uncat.ps1 -List
```

Expected output:

```
Wrote 3 file(s) to:
  C:\me\concat\self-test.md

| #    |    Bytes | Relative Path
| ---- | -------- | -------------
|    1 |    12638 | "concat.ps1"
|    2 |     8192 | "uncat.ps1"
|    3 |     6144 | "README.md"

| #    |    Bytes | Status | Relative Path
| ---- | -------- | ------ | -------------
|    1 |    12638 | OK     | "concat.ps1"
|    2 |     8192 | OK     | "uncat.ps1"
|    3 |     6144 | OK     | "README.md"

Verified 3 file(s). All checks passed.
  C:\me\concat\self-test.md
```
