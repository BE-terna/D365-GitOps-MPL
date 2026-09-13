<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0
<#
.SYNOPSIS
    Git merge driver for D365 Finance & Operations metadata XML files (AxTable,
    AxSecurityPrivilege, AxMenuExtension, AxFormExtension, ...).

.DESCRIPTION
    D365FO stores metadata as XML where, for some elements, sibling order is
    meaningless (e.g. table fields, security entry points) but git's default
    line-based 3-way merge still raises a conflict whenever two branches add
    different siblings next to each other. This driver removes those false
    conflicts while still surfacing genuine content conflicts.

    Algorithm
    ---------
    1. Parse Base/Ours/Theirs and locate "unordered" container elements:
         - explicitly configured via a rules file (one absolute XPath per line,
           pointing at the repeated element, e.g. /AxTable/Fields/AxTableField)
         - automatically detected: any set of >= 2 same-named sibling elements
           that each have a direct <Parent> child (e.g. menu/form extension
           elements) - order only matters between siblings sharing the same
           <Parent> value, so different-parent siblings never conflict.
    2. For each such container whose children differ between Ours and Theirs,
       perform a set-merge keyed by the child's own <Name> (and <Parent> when
       present): additions/deletions from either side are combined; a true
       conflict is only raised when both sides changed the *same* key to
       different content. The result replaces that container identically in
       the Base/Ours/Theirs working copies, so the region is no longer a
       source of disagreement.
    3. The (mostly untouched) working copies are then merged with
       `git merge-file`, which handles every other, ordinary line-based change
       exactly as it would without this driver, preserving original
       formatting everywhere outside the resolved containers.
    4. If any conflict markers remain (genuine content conflicts, or
       unordered-region conflicts we could not auto-resolve), the file is
       left conflicted and the script exits 1, matching git's own convention.

    Register the merge driver in git config once per clone (or in a pipeline step):
        git config merge.d365fo-xml.name   "D365FO metadata XML merger"
        git config merge.d365fo-xml.driver "pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365MetadataXml.ps1 -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"

    Alternatively, install the D365GitOps module and run:
        Register-D365MetadataXmlMergeDriver

.PARAMETER Base
    Ancestor (base) version of the file. Supplied as %O by git.

.PARAMETER Ours
    Current-branch version. Supplied as %A by git. The merged result is
    written back to this path.

.PARAMETER Theirs
    Other-branch version. Supplied as %B by git.

.PARAMETER MarkerSize
    Width of conflict-marker lines. Supplied as %L by git. Default: 7.

.PARAMETER FilePath
    Repository-relative path of the file. Supplied as %P by git.
    Used only for diagnostic messages.

.PARAMETER RulesPath
    Path to a rules file listing additional/override absolute XPaths (one per
    line, '#' comments allowed) of repeated elements whose sibling order does
    not matter. Defaults to the bundled Default-UnorderedElements.rules file.
    Can also be set via the D365FO_XMLMERGE_RULES environment variable.

.EXAMPLE
    # Try the driver against the bundled samples (two concurrent, unrelated
    # additions under the same <EntryPoints> container merge cleanly):
    pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365MetadataXml.ps1 `
        -Base Sample-Base.xml -Ours Sample-Base-C001.xml -Theirs Sample-Base-C002.xml -FilePath Sample-Base.xml
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Base,          # %O  ancestor version

    [Parameter(Mandatory)]
    [string]$Ours,          # %A  current-branch version; result written here

    [Parameter(Mandatory)]
    [string]$Theirs,        # %B  other-branch version

    [int]$MarkerSize = 7,   # %L  conflict-marker width

    [string]$FilePath = '', # %P  repo-relative path (informational only)

    [string]$RulesPath = (Join-Path $PSScriptRoot 'Default-UnorderedElements.rules')
)

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── XML text-position parsing (no re-serialisation, exact formatting kept) ─

# Builds a tree of element nodes with exact character offsets into $Text, so
# that untouched regions can be copied verbatim instead of round-tripped
# through an XML writer (which would collapse D365's multi-line attribute
# layout).
function Build-XmlElementTree {
    [OutputType([pscustomobject])]
    param([string]$Text)

    $lineStarts = [System.Collections.Generic.List[int]]::new()
    [void]$lineStarts.Add(0)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") { [void]$lineStarts.Add($i + 1) }
    }

    function ConvertTo-Offset([int]$line, [int]$col) {
        return $lineStarts[$line - 1] + ($col - 1)
    }

    function Find-LessThan([int]$fromOffset) {
        $i = $fromOffset
        while ($i -ge 0 -and $Text[$i] -ne '<') { $i-- }
        return $i
    }

    # Scans forward from a '<' offset for the matching (quote-aware) '>'.
    function Find-TagEnd([int]$ltOffset) {
        $inQuote = [char]0
        for ($i = $ltOffset + 1; $i -lt $Text.Length; $i++) {
            $c = $Text[$i]
            if ($inQuote -ne [char]0) {
                if ($c -eq $inQuote) { $inQuote = [char]0 }
                continue
            }
            if ($c -eq '"' -or $c -eq "'") { $inQuote = $c; continue }
            if ($c -eq '>') {
                $selfClosing = ($i -gt 0 -and $Text[$i - 1] -eq '/')
                return [pscustomobject]@{ End = $i; SelfClosing = $selfClosing }
            }
        }
        throw "Malformed XML: no closing '>' found for tag starting at offset $ltOffset"
    }

    $sr = [System.IO.StringReader]::new($Text)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $reader = [System.Xml.XmlReader]::Create($sr, $settings)
    $li = [System.Xml.IXmlLineInfo]$reader

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $root = $null

    while ($reader.Read()) {
        if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            $nameOffset = ConvertTo-Offset $li.LineNumber $li.LinePosition
            $lt = Find-LessThan $nameOffset
            $tagEnd = Find-TagEnd $lt

            $node = [pscustomobject]@{
                Name          = $reader.Name
                Start         = $lt
                OpenTagEnd    = $tagEnd.End
                CloseTagStart = $null
                End           = $null
                IsSelfClosing = $tagEnd.SelfClosing
                Children      = [System.Collections.Generic.List[object]]::new()
            }

            $isRoot = ($stack.Count -eq 0)
            if (-not $isRoot) { $stack.Peek().Children.Add($node) }

            if ($tagEnd.SelfClosing) {
                $node.End = $tagEnd.End
                if ($isRoot) { $root = $node }
            }
            else {
                $stack.Push($node)
                if ($isRoot) { $root = $node }
            }
        }
        elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
            $nameOffset = ConvertTo-Offset $li.LineNumber $li.LinePosition
            $lt = Find-LessThan $nameOffset
            $tagEnd = Find-TagEnd $lt
            $node = $stack.Pop()
            $node.CloseTagStart = $lt
            $node.End = $tagEnd.End
        }
    }
    $reader.Close()

    return $root
}

# Walks down a tree by an absolute list of element names, requiring each
# intermediate segment to be the unique child with that name (avoids
# ambiguity). Returns $null if the path does not resolve.
function Find-ElementByPath {
    [OutputType([pscustomobject])]
    param(
        [pscustomobject]$Root,
        [string[]]$Path
    )

    if (-not $Root -or $Root.Name -ne $Path[0]) { return $null }
    $current = $Root
    for ($i = 1; $i -lt $Path.Count; $i++) {
        $matching = @($current.Children | Where-Object { $_.Name -eq $Path[$i] })
        if ($matching.Count -ne 1) { return $null }
        $current = $matching[0]
    }
    return $current
}

# Recursively finds containers whose repeated children all carry a direct
# <Parent> element (menu/form-extension style ordering rules).
function Find-AutoGroupedContainers {
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param(
        [pscustomobject]$Node,
        [string[]]$PathSoFar,
        [string]$Text
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    $groups = $Node.Children | Group-Object -Property Name
    foreach ($g in $groups) {
        if ($g.Count -lt 2) { continue }
        $allHaveParent = $true
        foreach ($child in $g.Group) {
            $frag = $Text.Substring($child.Start, $child.End - $child.Start + 1)
            if ($frag -notmatch '<Parent>') { $allHaveParent = $false; break }
        }
        if ($allHaveParent) {
            $results.Add([pscustomobject]@{ ContainerPath = $PathSoFar; ChildName = $g.Name })
        }
    }

    foreach ($child in $Node.Children) {
        $siblingCount = @($Node.Children | Where-Object { $_.Name -eq $child.Name }).Count
        if ($siblingCount -eq 1) {
            $nested = Find-AutoGroupedContainers -Node $child -PathSoFar ($PathSoFar + $child.Name) -Text $Text
            if ($nested) { $results.AddRange($nested) }
        }
    }

    return , $results
}

# ─── Rules loading ───────────────────────────────────────────────────────────

function Get-UnorderedRules {
    [OutputType([System.Collections.Generic.List[string[]]])]
    param([string]$Path)

    $rules = [System.Collections.Generic.List[string[]]]::new()
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $rules }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith('#')) { continue }
        $segments = @($trimmed.Trim('/') -split '/' | Where-Object { $_ -ne '' })
        if ($segments.Count -lt 2) { continue }
        $rules.Add($segments)
    }
    return , $rules
}

# ─── Fragment identity & set-merge (mirrors Merge-D365LabelFile's approach) ──

function New-FragmentRecord {
    [OutputType([pscustomobject])]
    param([pscustomobject]$Node, [string]$Text)

    $frag = $Text.Substring($Node.Start, $Node.End - $Node.Start + 1)
    $name = if ($frag -match '<Name>([\s\S]*?)</Name>') { $Matches[1] } else { $null }
    $parent = if ($frag -match '<Parent>([\s\S]*?)</Parent>') { $Matches[1] } else { $null }

    $key = if ($null -ne $parent) { "$parent|$name" } else { $name }
    if ([string]::IsNullOrEmpty($key)) { $key = $frag }  # fallback: content-identity

    return [pscustomobject]@{ Key = $key; Text = $frag }
}

function Get-FragmentMap {
    [OutputType([hashtable])]
    param([object[]]$Records)

    $map = [hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($r in $Records) { $map[$r.Key] = $r }
    return $map
}

function New-XmlConflictFragment {
    param(
        [string]$OursText,
        [string]$TheirsText,
        [string]$Lt, [string]$Sep, [string]$Gt
    )
    return "$Lt ours`n$OursText`n$Sep`n$TheirsText`n$Gt theirs"
}

# Set-merges a container's children by identity key. Returns
# @{ Items = [pscustomobject[]] (each has .Text); HasConflict = bool }
function Merge-FragmentSet {
    param(
        [object[]]$BaseFrags,
        [object[]]$OursFrags,
        [object[]]$TheirsFrags,
        [int]$MarkerSize
    )

    $bMap = Get-FragmentMap $BaseFrags
    $oMap = Get-FragmentMap $OursFrags
    $tMap = Get-FragmentMap $TheirsFrags

    $orderedKeys = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $OursFrags)   { if ($seen.Add($r.Key)) { [void]$orderedKeys.Add($r.Key) } }
    foreach ($r in $TheirsFrags) { if ($seen.Add($r.Key)) { [void]$orderedKeys.Add($r.Key) } }
    foreach ($r in $BaseFrags)   { if ($seen.Add($r.Key)) { [void]$orderedKeys.Add($r.Key) } }

    $lt  = '<' * $MarkerSize
    $sep = '=' * $MarkerSize
    $gt  = '>' * $MarkerSize

    $items       = [System.Collections.Generic.List[pscustomobject]]::new()
    $hasConflict = $false

    foreach ($key in $orderedKeys) {
        $inB = $bMap.ContainsKey($key)
        $inO = $oMap.ContainsKey($key)
        $inT = $tMap.ContainsKey($key)

        if (-not $inB) {
            if ($inO -and -not $inT) { $items.Add([pscustomobject]@{ Text = $oMap[$key].Text }); continue }
            if (-not $inO -and $inT) { $items.Add([pscustomobject]@{ Text = $tMap[$key].Text }); continue }
            if ($oMap[$key].Text -eq $tMap[$key].Text) {
                $items.Add([pscustomobject]@{ Text = $oMap[$key].Text })
            }
            else {
                $hasConflict = $true
                $items.Add([pscustomobject]@{ Text = (New-XmlConflictFragment $oMap[$key].Text $tMap[$key].Text $lt $sep $gt) })
            }
            continue
        }

        if (-not $inO -and -not $inT) { continue }  # deleted by both

        if (-not $inO) {
            if ($tMap[$key].Text -eq $bMap[$key].Text) { continue }  # ours deleted, theirs unchanged
            $hasConflict = $true
            $items.Add([pscustomobject]@{ Text = (New-XmlConflictFragment '' $tMap[$key].Text $lt $sep $gt) })
            continue
        }

        if (-not $inT) {
            if ($oMap[$key].Text -eq $bMap[$key].Text) { continue }  # theirs deleted, ours unchanged
            $hasConflict = $true
            $items.Add([pscustomobject]@{ Text = (New-XmlConflictFragment $oMap[$key].Text '' $lt $sep $gt) })
            continue
        }

        $oChanged = $oMap[$key].Text -ne $bMap[$key].Text
        $tChanged = $tMap[$key].Text -ne $bMap[$key].Text

        if (-not $oChanged -and -not $tChanged) { $items.Add([pscustomobject]@{ Text = $bMap[$key].Text }) }
        elseif ($oChanged -and -not $tChanged)  { $items.Add([pscustomobject]@{ Text = $oMap[$key].Text }) }
        elseif (-not $oChanged -and $tChanged)  { $items.Add([pscustomobject]@{ Text = $tMap[$key].Text }) }
        elseif ($oMap[$key].Text -eq $tMap[$key].Text) { $items.Add([pscustomobject]@{ Text = $oMap[$key].Text }) }
        else {
            $hasConflict = $true
            $items.Add([pscustomobject]@{ Text = (New-XmlConflictFragment $oMap[$key].Text $tMap[$key].Text $lt $sep $gt) })
        }
    }

    return [pscustomobject]@{ Items = $items; HasConflict = $hasConflict }
}

# ─── Container patch computation ────────────────────────────────────────────

# Computes a (Start,End,Replacement) patch for one container instance, or
# $null if there is nothing to resolve (Ours/Theirs children already match).
function Get-ContainerPatch {
    param(
        [pscustomobject]$Candidate,   # @{ ContainerPath; ChildName }
        [pscustomobject]$BaseRoot, [string]$BaseText,
        [pscustomobject]$OursRoot, [string]$OursText,
        [pscustomobject]$TheirsRoot, [string]$TheirsText,
        [int]$MarkerSize
    )

    $oursContainer = Find-ElementByPath -Root $OursRoot -Path $Candidate.ContainerPath
    if (-not $oursContainer -or $oursContainer.IsSelfClosing) { return $null }

    $baseContainer   = Find-ElementByPath -Root $BaseRoot -Path $Candidate.ContainerPath
    $theirsContainer = Find-ElementByPath -Root $TheirsRoot -Path $Candidate.ContainerPath

    $oursChildren   = @($oursContainer.Children | Where-Object { $_.Name -eq $Candidate.ChildName })
    $theirsChildren = if ($theirsContainer) { @($theirsContainer.Children | Where-Object { $_.Name -eq $Candidate.ChildName }) } else { @() }
    $baseChildren   = if ($baseContainer)   { @($baseContainer.Children   | Where-Object { $_.Name -eq $Candidate.ChildName }) } else { @() }

    if ($oursChildren.Count -eq 0) { return $null }

    $oursFragRaw   = ($oursChildren   | ForEach-Object { $OursText.Substring($_.Start, $_.End - $_.Start + 1) }) -join "`u{0}"
    $theirsFragRaw = ($theirsChildren | ForEach-Object { $TheirsText.Substring($_.Start, $_.End - $_.Start + 1) }) -join "`u{0}"
    if ($oursFragRaw -eq $theirsFragRaw) { return $null }  # nothing to reconcile

    $baseFrags   = @($baseChildren   | ForEach-Object { New-FragmentRecord -Node $_ -Text $BaseText })
    $oursFrags   = @($oursChildren   | ForEach-Object { New-FragmentRecord -Node $_ -Text $OursText })
    $theirsFrags = @($theirsChildren | ForEach-Object { New-FragmentRecord -Node $_ -Text $TheirsText })

    $merge = Merge-FragmentSet -BaseFrags $baseFrags -OursFrags $oursFrags -TheirsFrags $theirsFrags -MarkerSize $MarkerSize

    $openTagText = $OursText.Substring($oursContainer.Start, $oursContainer.OpenTagEnd - $oursContainer.Start + 1)
    $closeTagText = $OursText.Substring($oursContainer.CloseTagStart, $oursContainer.End - $oursContainer.CloseTagStart + 1)

    if ($oursChildren.Count -gt 0) {
        $firstStart = $oursChildren[0].Start
        $childIndent = $OursText.Substring($oursContainer.OpenTagEnd + 1, $firstStart - ($oursContainer.OpenTagEnd + 1))
        $lastEnd = $oursChildren[-1].End
        $closeIndent = $OursText.Substring($lastEnd + 1, $oursContainer.CloseTagStart - ($lastEnd + 1))
    }
    else {
        $childIndent = "`n"
        $closeIndent = "`n"
    }

    $body = ($merge.Items | ForEach-Object { $childIndent + $_.Text }) -join ''
    $replacement = $openTagText + $body + $closeIndent + $closeTagText

    return [pscustomobject]@{
        ContainerPath = $Candidate.ContainerPath
        ChildName     = $Candidate.ChildName
        Replacement   = $replacement
        HasConflict   = $merge.HasConflict
    }
}

function Set-PatchesIntoText {
    param(
        [string]$Text,
        [pscustomobject]$Root,
        [System.Collections.Generic.List[pscustomobject]]$Patches
    )

    $ops = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($p in $Patches) {
        $container = Find-ElementByPath -Root $Root -Path $p.ContainerPath
        if (-not $container -or $container.IsSelfClosing) { continue }
        $ops.Add([pscustomobject]@{ Start = $container.Start; End = $container.End; Text = $p.Replacement })
    }

    # Apply from the last offset to the first so earlier offsets stay valid.
    $sorted = $ops | Sort-Object -Property Start -Descending
    foreach ($op in $sorted) {
        $Text = $Text.Substring(0, $op.Start) + $op.Text + $Text.Substring($op.End + 1)
    }
    return $Text
}

# ─── Entry point ─────────────────────────────────────────────────────────────

$displayPath = if ($FilePath) { $FilePath } else { $Ours }
Write-Host "Merging D365FO metadata XML file: $displayPath"

if (-not $RulesPath -and $env:D365FO_XMLMERGE_RULES) { $RulesPath = $env:D365FO_XMLMERGE_RULES }
$rules = Get-UnorderedRules -Path $RulesPath

$baseText   = Get-Content -LiteralPath $Base   -Raw -Encoding UTF8
$oursText   = Get-Content -LiteralPath $Ours   -Raw -Encoding UTF8
$theirsText = Get-Content -LiteralPath $Theirs -Raw -Encoding UTF8

$baseRoot   = Build-XmlElementTree -Text $baseText
$oursRoot   = Build-XmlElementTree -Text $oursText
$theirsRoot = Build-XmlElementTree -Text $theirsText

# Candidate unordered containers: explicit rules + auto-detected <Parent> groups.
$candidates = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($segments in $rules) {
    $candidates.Add([pscustomobject]@{
        ContainerPath = $segments[0..($segments.Count - 2)]
        ChildName     = $segments[-1]
    })
}
if ($oursRoot) {
    $candidates.AddRange((Find-AutoGroupedContainers -Node $oursRoot -PathSoFar @($oursRoot.Name) -Text $oursText))
}

$patches = [System.Collections.Generic.List[pscustomobject]]::new()
$appliedContainerKeys = [System.Collections.Generic.HashSet[string]]::new()
$embeddedConflict = $false

foreach ($c in $candidates) {
    $containerKey = $c.ContainerPath -join '/'
    if (-not $appliedContainerKeys.Add($containerKey)) { continue }  # avoid duplicate work

    $patch = Get-ContainerPatch -Candidate $c `
        -BaseRoot $baseRoot -BaseText $baseText `
        -OursRoot $oursRoot -OursText $oursText `
        -TheirsRoot $theirsRoot -TheirsText $theirsText `
        -MarkerSize $MarkerSize

    if ($null -ne $patch) {
        $patches.Add($patch)
        if ($patch.HasConflict) { $embeddedConflict = $true }
        Write-Host "  Auto-merged unordered container: /$containerKey/$($c.ChildName)$(if ($patch.HasConflict) { ' (partial: content conflict remains)' })"
    }
}

$baseWorking   = Set-PatchesIntoText -Text $baseText   -Root $baseRoot   -Patches $patches
$oursWorking   = Set-PatchesIntoText -Text $oursText   -Root $oursRoot   -Patches $patches
$theirsWorking = Set-PatchesIntoText -Text $theirsText -Root $theirsRoot -Patches $patches

$tempDir = [System.IO.Path]::GetTempPath()
$suffix = [guid]::NewGuid().ToString('N')
$baseTemp   = Join-Path $tempDir "d365xmlmerge-$suffix-base.xml"
$oursTemp   = Join-Path $tempDir "d365xmlmerge-$suffix-ours.xml"
$theirsTemp = Join-Path $tempDir "d365xmlmerge-$suffix-theirs.xml"

try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($baseTemp, $baseWorking, $utf8NoBom)
    [System.IO.File]::WriteAllText($oursTemp, $oursWorking, $utf8NoBom)
    [System.IO.File]::WriteAllText($theirsTemp, $theirsWorking, $utf8NoBom)

    $gitStdErr = $($mergedText = & git merge-file -L ours -L base -L theirs "--marker-size=$MarkerSize" -p $oursTemp $baseTemp $theirsTemp) 2>&1 |
        Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    $gitExitCode = $LASTEXITCODE
    $mergedText = ($mergedText -join "`n")
    if ($mergedText.Length -gt 0 -and -not $mergedText.EndsWith("`n") -and $oursWorking.EndsWith("`n")) {
        $mergedText += "`n"
    }
}
finally {
    Remove-Item -LiteralPath $baseTemp, $oursTemp, $theirsTemp -ErrorAction SilentlyContinue
}

if ($gitExitCode -gt 1) {
    throw "git merge-file failed for '$displayPath' (exit code $gitExitCode): $($gitStdErr -join '; ')"
}

[System.IO.File]::WriteAllText($Ours, $mergedText, [System.Text.UTF8Encoding]::new($false))

$markerRegex = '(?m)^<{' + $MarkerSize + '}( |$)'
$stillConflicted = ($gitExitCode -eq 1) -or $embeddedConflict -or ($mergedText -match $markerRegex)

if ($stillConflicted) {
    Write-Warning "Merge conflicts remain in '$displayPath'."
    exit 1
}

Write-Host "Merged cleanly: $displayPath"
exit 0
