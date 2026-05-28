<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0
<#
.SYNOPSIS
    Git merge driver and standalone sorter for AxLabel translation files.

.DESCRIPTION
    Merge-driver mode  (invoked automatically by git during a merge):
        Performs a 3-way merge of label files, producing an alphabetically sorted
        result.  Per-label comments (a line starting with " ;" immediately before
        the label definition) are kept with their label.  Unresolvable conflicts are
        written as standard git conflict markers and the script exits 1 so git marks
        the file as conflicted.

    Standalone / pipeline mode  (no -Base/-Ours/-Theirs supplied):
        Scans the repository for every file matching
            **/AxLabelFile/LabelResources/*/*.label.txt
        and sorts each file's entries alphabetically in-place.

    Label file format
    -----------------
        LabelId=value
         ;optional comment      ← belongs to the label line before it

    Register the merge driver in git config once per clone (or in a pipeline step):
        git config merge.d365fo-label.name   "AxLabel file merger"
        git config merge.d365fo-label.driver "pwsh -File scripts/MergeDriver/Merge-LabelFile.ps1 -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"

    Alternatively, install the D365GitOps module and run:
        Register-D365MergeDriver

.PARAMETER Base
    [Merge-driver] Ancestor (base) version of the file. Supplied as %O by git.

.PARAMETER Ours
    [Merge-driver] Current-branch version. Supplied as %A by git.
    The merged result is written back to this path.

.PARAMETER Theirs
    [Merge-driver] Other-branch version. Supplied as %B by git.

.PARAMETER MarkerSize
    [Merge-driver] Width of conflict-marker lines. Supplied as %L by git. Default: 7.

.PARAMETER FilePath
    [Merge-driver] Repository-relative path of the file. Supplied as %P by git.
    Used only for diagnostic messages.

.PARAMETER RepoRoot
    [Standalone] Root directory to search for label files.
    Defaults to the current working directory.

.EXAMPLE
    # Run from a pipeline to sort every label file in the repository:
    pwsh -File scripts/MergeDriver/Merge-LabelFile.ps1 -RepoRoot $(Build.SourcesDirectory)
#>

[CmdletBinding(DefaultParameterSetName = 'Standalone')]
param(
    # ── Merge-driver mode ────────────────────────────────────────────────────
    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]$Base,          # %O  ancestor version

    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]$Ours,          # %A  current-branch version; result written here

    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]$Theirs,        # %B  other-branch version

    [Parameter(ParameterSetName = 'MergeDriver')]
    [int]$MarkerSize = 7,   # %L  conflict-marker width

    [Parameter(ParameterSetName = 'MergeDriver')]
    [string]$FilePath = '', # %P  repo-relative path (informational only)

    # ── Standalone / pipeline mode ────────────────────────────────────────────
    [Parameter(ParameterSetName = 'Standalone')]
    [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Parsing ─────────────────────────────────────────────────────────────────

function Read-LabelEntries {
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param([string]$Path)

    $entries   = [System.Collections.Generic.List[pscustomobject]]::new()
    $lastEntry = $null

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^ ;') {
            # Comment line – belongs to the previous label definition
            if ($null -ne $lastEntry) {
                $lastEntry.Comment = $line
            }
        }
        elseif ($line -match '^([^=]+)=(.*)$') {
            $entry = [pscustomobject]@{
                Comment = $null
                LabelId = $Matches[1]
                Value   = $Matches[2]
            }
            $entries.Add($entry)
            $lastEntry = $entry
        }
        else {
            # Blank or unrecognised line – reset context
            $lastEntry = $null
        }
    }

    return $entries
}

function Get-EntryMap {
    [OutputType([hashtable])]
    param([System.Collections.Generic.List[pscustomobject]]$Entries)

    $map = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Entries) { $map[$e.LabelId] = $e }
    return $map
}

# ─── Serialising ─────────────────────────────────────────────────────────────

function Format-LabelFile {
    [OutputType([string])]
    param($Entries)

    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($e in $Entries) {
        if ($e.PSObject.Properties['IsConflict'] -and $e.IsConflict) {
            foreach ($cl in $e.ConflictLines) { $lines.Add($cl) }
            if (![string]::IsNullOrEmpty($e.Comment)) { $lines.Add($e.Comment) }
        }
        else {
            $lines.Add("$($e.LabelId)=$($e.Value)")
            if (![string]::IsNullOrEmpty($e.Comment)) { $lines.Add($e.Comment) }
        }
    }

    # Join with LF; end with a single trailing newline
    return ($lines -join "`n") + "`n"
}

function Save-LabelFile {
    param(
        [string]$Path,
        $Entries
    )

    $text = Format-LabelFile -Entries $Entries
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

# ─── Sorting ─────────────────────────────────────────────────────────────────

function Sort-LabelEntries {
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param([System.Collections.Generic.List[pscustomobject]]$Entries)

    $sorted = [System.Collections.Generic.List[pscustomobject]]::new()
    $sorted.AddRange([pscustomobject[]]($Entries | Sort-Object -Property LabelId))
    return $sorted
}

# ─── Three-way merge ─────────────────────────────────────────────────────────

# Builds a conflict-marker entry (no actual label value; ConflictLines contains
# the full block to be written verbatim).  Either $OursEntry or $TheirsEntry
# may be $null to represent a deletion on that side.
function New-ConflictEntry {
    param(
        [string]$Id,
        [string]$BaseComment,          # may be $null
        [pscustomobject]$OursEntry,    # $null  → ours deleted the label
        [pscustomobject]$TheirsEntry,  # $null  → theirs deleted the label
        [string]$Lt,
        [string]$Sep,
        [string]$Gt
    )

    $cl = [System.Collections.Generic.List[string]]::new()
    $cl.Add("$Lt ours")
    if ($null -ne $OursEntry) {
        $cl.Add("$Id=$($OursEntry.Value)")
        if (![string]::IsNullOrEmpty($OursEntry.Comment)) { $cl.Add($OursEntry.Comment) }
    }
    $cl.Add($Sep)
    if ($null -ne $TheirsEntry) {
        $cl.Add("$Id=$($TheirsEntry.Value)")
        if (![string]::IsNullOrEmpty($TheirsEntry.Comment)) { $cl.Add($TheirsEntry.Comment) }
    }
    $cl.Add("$Gt theirs")

    return [pscustomobject]@{
        Comment       = $BaseComment
        LabelId       = $Id
        Value         = ''
        IsConflict    = $true
        ConflictLines = $cl
    }
}

function Invoke-LabelMerge {
    param(
        [System.Collections.Generic.List[pscustomobject]]$BaseList,
        [System.Collections.Generic.List[pscustomobject]]$OursList,
        [System.Collections.Generic.List[pscustomobject]]$TheirsList,
        [int]$MarkerSize
    )

    $bMap = Get-EntryMap $BaseList
    $oMap = Get-EntryMap $OursList
    $tMap = Get-EntryMap $TheirsList

    # Union of all label IDs (order here doesn't matter; we sort at the end)
    $allIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $BaseList)   { [void]$allIds.Add($e.LabelId) }
    foreach ($e in $OursList)   { [void]$allIds.Add($e.LabelId) }
    foreach ($e in $TheirsList) { [void]$allIds.Add($e.LabelId) }

    $merged      = [System.Collections.Generic.List[pscustomobject]]::new()
    $conflictIds = [System.Collections.Generic.List[string]]::new()

    $lt  = '<' * $MarkerSize
    $sep = '=' * $MarkerSize
    $gt  = '>' * $MarkerSize

    foreach ($id in $allIds) {
        $inB = $bMap.ContainsKey($id)
        $inO = $oMap.ContainsKey($id)
        $inT = $tMap.ContainsKey($id)

        # ── Not in base: newly added ──────────────────────────────────────────
        if (-not $inB) {
            if ($inO -and -not $inT) { $merged.Add($oMap[$id]); continue }
            if (-not $inO -and $inT) { $merged.Add($tMap[$id]); continue }
            # Added by both
            if ($oMap[$id].Value -eq $tMap[$id].Value) {
                $merged.Add($oMap[$id])
            }
            else {
                $conflictIds.Add($id)
                $merged.Add((New-ConflictEntry $id $null $oMap[$id] $tMap[$id] $lt $sep $gt))
            }
            continue
        }

        # ── In base: check for deletions ─────────────────────────────────────
        if (-not $inO -and -not $inT) {
            # Deleted by both → drop
            continue
        }

        if (-not $inO) {
            # Deleted by ours; theirs is present
            if ($tMap[$id].Value -eq $bMap[$id].Value) {
                # theirs unchanged → accept our deletion
            }
            else {
                # theirs modified it → conflict
                $conflictIds.Add($id)
                $merged.Add((New-ConflictEntry $id $bMap[$id].Comment $null $tMap[$id] $lt $sep $gt))
            }
            continue
        }

        if (-not $inT) {
            # Deleted by theirs; ours is present
            if ($oMap[$id].Value -eq $bMap[$id].Value) {
                # ours unchanged → accept their deletion
            }
            else {
                # ours modified it → conflict
                $conflictIds.Add($id)
                $merged.Add((New-ConflictEntry $id $bMap[$id].Comment $oMap[$id] $null $lt $sep $gt))
            }
            continue
        }

        # ── Present in all three: standard 3-way merge ───────────────────────
        $oChanged = $oMap[$id].Value -ne $bMap[$id].Value
        $tChanged = $tMap[$id].Value -ne $bMap[$id].Value

        if (-not $oChanged -and -not $tChanged) {
            $merged.Add($bMap[$id])
        }
        elseif ($oChanged -and -not $tChanged) {
            $merged.Add($oMap[$id])
        }
        elseif (-not $oChanged -and $tChanged) {
            $merged.Add($tMap[$id])
        }
        elseif ($oMap[$id].Value -eq $tMap[$id].Value) {
            # Both changed to the same value
            $merged.Add($oMap[$id])
        }
        else {
            # True conflict: both changed to different values
            $conflictIds.Add($id)
            $merged.Add((New-ConflictEntry $id $bMap[$id].Comment $oMap[$id] $tMap[$id] $lt $sep $gt))
        }
    }

    return @{
        Entries     = Sort-LabelEntries -Entries $merged
        ConflictIds = $conflictIds
    }
}

# ─── Entry point ─────────────────────────────────────────────────────────────

if ($PSCmdlet.ParameterSetName -eq 'MergeDriver') {

    $displayPath = if ($FilePath) { $FilePath } else { $Ours }
    Write-Host "Merging label file: $displayPath"

    $result = Invoke-LabelMerge `
        -BaseList   (Read-LabelEntries -Path $Base) `
        -OursList   (Read-LabelEntries -Path $Ours) `
        -TheirsList (Read-LabelEntries -Path $Theirs) `
        -MarkerSize $MarkerSize

    Save-LabelFile -Path $Ours -Entries $result.Entries

    if ($result.ConflictIds.Count -gt 0) {
        Write-Warning "Merge conflicts in '$displayPath' for label(s): $($result.ConflictIds -join ', ')"
        exit 1
    }

    exit 0
}

# ── Standalone / pipeline mode ────────────────────────────────────────────────

$labelFiles = @(Get-ChildItem -Path $RepoRoot -Filter '*.label.txt' -Recurse -File |
    Where-Object { $_.FullName -replace '\\', '/' -match '/AxLabelFile/LabelResources/[^/]+/' })

if ($labelFiles.Count -eq 0) {
    Write-Host 'No label files found matching **/AxLabelFile/LabelResources/*/*.label.txt'
    exit 0
}

$changedCount = 0

foreach ($file in $labelFiles) {
    $entries = Read-LabelEntries -Path $file.FullName
    $sorted  = Sort-LabelEntries -Entries $entries
    $before  = Format-LabelFile  -Entries $entries
    $after   = Format-LabelFile  -Entries $sorted

    if ($before -ne $after) {
        Save-LabelFile -Path $file.FullName -Entries $sorted
        Write-Host "Sorted: $($file.FullName)"
        $changedCount++
    }
    else {
        Write-Host "OK:     $($file.FullName)"
    }
}

Write-Host ''
Write-Host "Done. $changedCount file(s) updated."
