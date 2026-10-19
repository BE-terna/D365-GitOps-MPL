<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0
<#
.SYNOPSIS
    Git merge driver for D365 Finance and Operations metadata XML files.

.DESCRIPTION
    D365FO metadata (AxTable, AxSecurityPrivilege, AxMenuExtension, ...) is stored as XML
    where sibling-element order is sometimes significant (e.g. table field order in an
    index) and sometimes not (e.g. table field order in AxTable/Fields, or index order).
    Git's default 3-way merge is line based and does not know this, so two developers
    adding two different, unrelated siblings to the same collection (e.g. one adds an
    index, the other adds a different index) get a merge conflict even though there is
    no real semantic conflict.

    This driver first runs a normal line-based 3-way merge (via `git merge-file`, the
    same algorithm git itself uses). Any resulting conflict hunk is then inspected: if it
    falls entirely inside a collection listed in the rules file (see -RulesFile) the
    driver re-merges just that collection's children as an unordered (or grouped, see the
    rules file format) set, keyed by an identity child element (default "Name"). Hunks
    that cannot be resolved this way are left with standard git conflict markers and the
    script exits 1, same as an ordinary unresolved merge.

    Register the merge driver in git config once per clone (or in a pipeline step):
        git config merge.d365fo-xml.name   "D365FO metadata XML merger"
        git config merge.d365fo-xml.driver "pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365FO-MetadataXml.ps1 -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"

    Alternatively, install the D365GitOps module and run:
        Register-D365FOMetadataXmlMergeDriver

.PARAMETER Base
    Ancestor (base) version of the file. Supplied as %O by git.

.PARAMETER Ours
    Current-branch version. Supplied as %A by git. The merged result is written back to
    this path.

.PARAMETER Theirs
    Other-branch version. Supplied as %B by git.

.PARAMETER MarkerSize
    Width of conflict-marker lines. Supplied as %L by git. Default: 7.

.PARAMETER FilePath
    Repository-relative path of the file. Supplied as %P by git. Used only for
    diagnostic messages.

.PARAMETER RulesFile
    Path to a rules file describing which collections are order-independent (see
    Default-UnorderedXPaths.rules.txt for the format and examples). Resolution order
    when not supplied:
        1. The D365FO_XML_MERGE_RULES environment variable, if set.
        2. Default-UnorderedXPaths.rules.txt shipped alongside this script.

.EXAMPLE
    pwsh -File Merge-D365FO-MetadataXml.ps1 -Base base.xml -Ours ours.xml -Theirs theirs.xml
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

    [string]$RulesFile
)

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Rules ───────────────────────────────────────────────────────────────────

function Get-RulesFilePath {
    param([string]$RulesFile)

    if ($RulesFile) { return $RulesFile }
    if ($env:D365FO_XML_MERGE_RULES) { return $env:D365FO_XML_MERGE_RULES }
    return (Join-Path $PSScriptRoot 'Default-UnorderedXPaths.rules.txt')
}

function Read-MergeRules {
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param([string]$Path)

    $rules = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "XML merge rules file not found: $Path (order-independent merging disabled)"
        return $rules
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $tokens = $trimmed -split '\s+'
        $xpath  = $tokens[0]

        $anySuffix = $false
        if ($xpath.StartsWith('//')) {
            $anySuffix = $true
            $xpath = $xpath.Substring(2)
        }
        elseif ($xpath.StartsWith('/')) {
            $xpath = $xpath.Substring(1)
        }
        $segments = @($xpath -split '/' | Where-Object { $_ })
        if ($segments.Count -eq 0) { continue }

        $groupPath = $null
        $idPath    = 'Name'
        for ($i = 1; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -match '^group=(.+)$') { $groupPath = $Matches[1] }
            elseif ($tokens[$i] -match '^id=(.+)$') { $idPath = $Matches[1] }
        }

        $rules.Add([pscustomobject]@{
            ContainerSegments = $segments[0..($segments.Count - 2)]
            ItemTag           = $segments[-1]
            AnySuffix         = $anySuffix
            GroupPath         = $groupPath
            IdPath            = $idPath
        })
    }

    return , $rules
}

function Find-MatchingRule {
    param(
        [System.Collections.Generic.List[pscustomobject]]$Rules,
        [string[]]$AncestorPath,
        [string]$ItemTag
    )

    foreach ($rule in $Rules) {
        if ($rule.ItemTag -ne $ItemTag) { continue }

        if ($rule.AnySuffix) {
            $need = $rule.ContainerSegments
            if ($need.Count -eq 0) { return $rule }
            if ($AncestorPath.Count -lt $need.Count) { continue }
            $tail = $AncestorPath[($AncestorPath.Count - $need.Count)..($AncestorPath.Count - 1)]
            if (@(Compare-Object $tail $need -SyncWindow 0).Count -eq 0) { return $rule }
        }
        else {
            if (@(Compare-Object $AncestorPath $rule.ContainerSegments -SyncWindow 0).Count -eq 0) { return $rule }
        }
    }
    return $null
}

# ─── Ancestor-path tracking ──────────────────────────────────────────────────

# Determines the element-name stack (document order) for a (possibly truncated /
# not-well-formed) prefix of an XML document, by reading as far as XmlReader can go.
function Get-AncestorPath {
    [OutputType([string[]])]
    param([string]$Text)

    $stack  = [System.Collections.Generic.List[string]]::new()
    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text))
        while ($true) {
            try {
                if (-not $reader.Read()) { break }
            }
            catch {
                break
            }
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                if (-not $reader.IsEmptyElement) { $stack.Add($reader.LocalName) }
            }
            elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
            }
        }
    }
    catch {
        # Truncated / not-well-formed input is expected - use whatever was read so far.
    }
    finally {
        if ($reader) { $reader.Dispose() }
    }
    return , $stack.ToArray()
}

# ─── Conflict-hunk parsing (git merge-file --diff3 output) ──────────────────

function Find-ConflictHunks {
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param([string[]]$Lines)

    $hunks = [System.Collections.Generic.List[pscustomobject]]::new()
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -notmatch '^<{7} ') { $i++; continue }

        $start = $i
        $j = $i + 1
        $oursLines = [System.Collections.Generic.List[string]]::new()
        while ($j -lt $Lines.Count -and $Lines[$j] -notmatch '^\|{7} ') { $oursLines.Add($Lines[$j]); $j++ }
        if ($j -ge $Lines.Count) { $i++; continue }  # malformed, skip marker line only
        $j++  # skip ||||||| line

        $baseLines = [System.Collections.Generic.List[string]]::new()
        while ($j -lt $Lines.Count -and $Lines[$j] -notmatch '^={7}$') { $baseLines.Add($Lines[$j]); $j++ }
        if ($j -ge $Lines.Count) { $i++; continue }
        $j++  # skip ======= line

        $theirsLines = [System.Collections.Generic.List[string]]::new()
        while ($j -lt $Lines.Count -and $Lines[$j] -notmatch '^>{7} ') { $theirsLines.Add($Lines[$j]); $j++ }
        if ($j -ge $Lines.Count) { $i++; continue }

        $hunks.Add([pscustomobject]@{
            Start  = $start
            End    = $j + 1  # exclusive
            Ours   = $oursLines
            Base   = $baseLines
            Theirs = $theirsLines
        })
        $i = $j + 1
    }
    return , $hunks
}

# ─── Element helpers ─────────────────────────────────────────────────────────

# Parses a hunk block (list of lines) as the children of a synthetic root. Returns
# $null if the block is not well-formed XML (e.g. the diff cut across tag boundaries).
# $RootNsDecl carries the document root's xmlns declarations so prefixes used by
# inherited-namespace elements (e.g. "i:type") resolve without being re-declared.
function ConvertTo-ElementList {
    [OutputType([System.Collections.Generic.List[System.Xml.XmlElement]])]
    param([string[]]$Lines, [string]$RootNsDecl = '')

    $text = ($Lines -join "`n").Trim()
    $doc  = [System.Xml.XmlDocument]::new()
    $doc.PreserveWhitespace = $true
    try {
        $doc.LoadXml("<Root $RootNsDecl>$text</Root>")
    }
    catch {
        return $null
    }

    $result = [System.Collections.Generic.List[System.Xml.XmlElement]]::new()
    foreach ($node in $doc.DocumentElement.ChildNodes) {
        if ($node.NodeType -eq [System.Xml.XmlNodeType]::Element) { $result.Add($node) }
    }
    return , $result
}

# Resolves a "/"-separated, namespace-agnostic relative path (e.g. "MenuElement/Name")
# to the text of the target descendant, walking direct children only at each step.
function Get-RelativeChildText {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Path
    )

    $current = $Element
    foreach ($segment in ($Path -split '/')) {
        $next = $null
        foreach ($child in $current.ChildNodes) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq $segment) {
                $next = $child
                break
            }
        }
        if (-not $next) { return $null }
        $current = $next
    }
    return $current.InnerText.Trim()
}

function Get-CanonicalXml {
    param([System.Xml.XmlElement]$Element)
    return ($Element.OuterXml -replace '>\s+<', '><').Trim()
}

function Get-ElementIdentity {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$IdPath
    )

    $id = Get-RelativeChildText -Element $Element -Path $IdPath
    if ($id) { return $id }
    return '~' + (Get-CanonicalXml -Element $Element)
}

# Formats an element for output: its own (preserved) internal formatting, prefixed
# with the indentation appropriate for its nesting depth.
function Format-ElementForOutput {
    [OutputType([string[]])]
    param(
        [System.Xml.XmlElement]$Element,
        [int]$IndentLevel
    )

    $indent = "`t" * $IndentLevel
    $text   = $Element.OuterXml
    $lines  = $text -split "`n"
    $lines[0] = $indent + $lines[0]
    return $lines
}

# ─── Order-independent / grouped sibling merge ───────────────────────────────

# 3-way-merges a set of identities (added/removed/modified), independent of order.
# Returns @{ Ids = <ordered identity list, "merge input order">; Items = <hashtable id -> item> }
# where item is @{ Status='Kept'|'Conflict'; Element; OursElement; TheirsElement }
function Merge-IdentitySet {
    param(
        [hashtable]$BaseMap,   # id -> element
        [hashtable]$OursMap,
        [hashtable]$TheirsMap,
        [string[]]$BaseOrder,  # ids in base document order (deduped)
        [string[]]$OursOrder,
        [string[]]$TheirsOrder
    )

    $allIds = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in $BaseOrder + $OursOrder + $TheirsOrder) {
        if ($seen.Add($id)) { $allIds.Add($id) }
    }

    $items       = @{}
    $hasConflict = $false

    foreach ($id in $allIds) {
        $inB = $BaseMap.ContainsKey($id)
        $inO = $OursMap.ContainsKey($id)
        $inT = $TheirsMap.ContainsKey($id)

        if (-not $inB) {
            if ($inO -and -not $inT) { $items[$id] = @{ Status = 'Kept'; Element = $OursMap[$id] }; continue }
            if (-not $inO -and $inT) { $items[$id] = @{ Status = 'Kept'; Element = $TheirsMap[$id] }; continue }
            if (-not $inO -and -not $inT) { continue }  # shouldn't happen
            if ((Get-CanonicalXml $OursMap[$id]) -eq (Get-CanonicalXml $TheirsMap[$id])) {
                $items[$id] = @{ Status = 'Kept'; Element = $OursMap[$id] }
            }
            else {
                $items[$id] = @{ Status = 'Conflict'; OursElement = $OursMap[$id]; TheirsElement = $TheirsMap[$id] }
                $hasConflict = $true
            }
            continue
        }

        if (-not $inO -and -not $inT) { continue }  # deleted by both

        if (-not $inO) {
            if ((Get-CanonicalXml $TheirsMap[$id]) -eq (Get-CanonicalXml $BaseMap[$id])) { continue }  # accept our deletion
            $items[$id] = @{ Status = 'Conflict'; OursElement = $null; TheirsElement = $TheirsMap[$id] }
            $hasConflict = $true
            continue
        }

        if (-not $inT) {
            if ((Get-CanonicalXml $OursMap[$id]) -eq (Get-CanonicalXml $BaseMap[$id])) { continue }  # accept their deletion
            $items[$id] = @{ Status = 'Conflict'; OursElement = $OursMap[$id]; TheirsElement = $null }
            $hasConflict = $true
            continue
        }

        $oChanged = (Get-CanonicalXml $OursMap[$id])   -ne (Get-CanonicalXml $BaseMap[$id])
        $tChanged = (Get-CanonicalXml $TheirsMap[$id]) -ne (Get-CanonicalXml $BaseMap[$id])

        if (-not $oChanged -and -not $tChanged) { $items[$id] = @{ Status = 'Kept'; Element = $BaseMap[$id] } }
        elseif ($oChanged -and -not $tChanged)  { $items[$id] = @{ Status = 'Kept'; Element = $OursMap[$id] } }
        elseif (-not $oChanged -and $tChanged)  { $items[$id] = @{ Status = 'Kept'; Element = $TheirsMap[$id] } }
        elseif ((Get-CanonicalXml $OursMap[$id]) -eq (Get-CanonicalXml $TheirsMap[$id])) {
            $items[$id] = @{ Status = 'Kept'; Element = $OursMap[$id] }
        }
        else {
            $items[$id] = @{ Status = 'Conflict'; OursElement = $OursMap[$id]; TheirsElement = $TheirsMap[$id] }
            $hasConflict = $true
        }
    }

    # Final order: no alphabetical re-sorting - use base survivors in base order,
    # then new items in the order they were added on each side (ours, then theirs).
    $finalOrder = [System.Collections.Generic.List[string]]::new()
    $placed     = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in ($BaseOrder + $OursOrder + $TheirsOrder)) {
        if ($items.ContainsKey($id) -and $placed.Add($id)) { $finalOrder.Add($id) }
    }

    return @{ Ids = $finalOrder; Items = $items; HasConflict = $hasConflict }
}

function Get-DedupedOrder {
    [OutputType([string[]])]
    param([System.Collections.Generic.List[System.Xml.XmlElement]]$Elements, [string]$IdPath)

    $order = [System.Collections.Generic.List[string]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($el in $Elements) {
        $id = Get-ElementIdentity -Element $el -IdPath $IdPath
        if ($seen.Add($id)) { $order.Add($id) }
    }
    return , $order.ToArray()
}

function Get-ElementMap {
    [OutputType([hashtable])]
    param([System.Collections.Generic.List[System.Xml.XmlElement]]$Elements, [string]$IdPath)

    $map = @{}
    foreach ($el in $Elements) { $map[(Get-ElementIdentity -Element $el -IdPath $IdPath)] = $el }
    return $map
}

# Resolves one conflict hunk that is entirely inside a rule-matched collection.
# Returns @{ Lines = <string[]>; HasConflict = <bool> } or $null if not resolvable.
function Resolve-CollectionHunk {
    param(
        [pscustomobject]$Hunk,
        [System.Collections.Generic.List[pscustomobject]]$Rules,
        [string[]]$AncestorPath,
        [int]$MarkerSize,
        [string]$RootNsDecl = ''
    )

    $baseEls   = ConvertTo-ElementList -Lines $Hunk.Base   -RootNsDecl $RootNsDecl
    $oursEls   = ConvertTo-ElementList -Lines $Hunk.Ours   -RootNsDecl $RootNsDecl
    $theirsEls = ConvertTo-ElementList -Lines $Hunk.Theirs -RootNsDecl $RootNsDecl
    if ($null -eq $baseEls -or $null -eq $oursEls -or $null -eq $theirsEls) { return $null }

    $allEls = @($baseEls) + @($oursEls) + @($theirsEls)
    if ($allEls.Count -eq 0) { return $null }

    $itemTag = $allEls[0].LocalName
    foreach ($el in $allEls) { if ($el.LocalName -ne $itemTag) { return $null } }

    $rule = Find-MatchingRule -Rules $Rules -AncestorPath $AncestorPath -ItemTag $itemTag
    if (-not $rule) { return $null }

    $idPath    = $rule.IdPath
    $baseMap   = Get-ElementMap -Elements $baseEls   -IdPath $idPath
    $oursMap   = Get-ElementMap -Elements $oursEls   -IdPath $idPath
    $theirsMap = Get-ElementMap -Elements $theirsEls -IdPath $idPath
    $baseOrder   = Get-DedupedOrder -Elements $baseEls   -IdPath $idPath
    $oursOrder   = Get-DedupedOrder -Elements $oursEls   -IdPath $idPath
    $theirsOrder = Get-DedupedOrder -Elements $theirsEls -IdPath $idPath

    $merge = Merge-IdentitySet -BaseMap $baseMap -OursMap $oursMap -TheirsMap $theirsMap `
        -BaseOrder $baseOrder -OursOrder $oursOrder -TheirsOrder $theirsOrder

    $indentLevel = $AncestorPath.Count
    $lt  = '<' * $MarkerSize
    $sep = '=' * $MarkerSize
    $gt  = '>' * $MarkerSize
    $out = [System.Collections.Generic.List[string]]::new()

    if (-not $rule.GroupPath) {
        foreach ($id in $merge.Ids) {
            $item = $merge.Items[$id]
            if ($item.Status -eq 'Kept') {
                $out.AddRange([string[]](Format-ElementForOutput -Element $item.Element -IndentLevel $indentLevel))
            }
            else {
                $out.Add("$lt ours")
                if ($item.OursElement)   { $out.AddRange([string[]](Format-ElementForOutput -Element $item.OursElement   -IndentLevel $indentLevel)) }
                $out.Add($sep)
                if ($item.TheirsElement) { $out.AddRange([string[]](Format-ElementForOutput -Element $item.TheirsElement -IndentLevel $indentLevel)) }
                $out.Add("$gt theirs")
            }
        }
        return @{ Lines = $out.ToArray(); HasConflict = $merge.HasConflict }
    }

    # ── Grouped case: order matters within a group, not between groups ──────
    $groupPath = $rule.GroupPath
    function Get-GroupOf($id) {
        $item = $merge.Items[$id]
        $el = if ($item.Status -eq 'Kept') { $item.Element } else { ($item.OursElement, $item.TheirsElement | Where-Object { $_ } | Select-Object -First 1) }
        return Get-RelativeChildText -Element $el -Path $groupPath
    }

    $groupOfBase   = @{}; foreach ($id in $baseOrder)   { if ($baseMap.ContainsKey($id))   { $groupOfBase[$id]   = Get-RelativeChildText -Element $baseMap[$id]   -Path $groupPath } }
    $groupOfOurs   = @{}; foreach ($id in $oursOrder)   { if ($oursMap.ContainsKey($id))   { $groupOfOurs[$id]   = Get-RelativeChildText -Element $oursMap[$id]   -Path $groupPath } }
    $groupOfTheirs = @{}; foreach ($id in $theirsOrder) { if ($theirsMap.ContainsKey($id)) { $groupOfTheirs[$id] = Get-RelativeChildText -Element $theirsMap[$id] -Path $groupPath } }

    $groupOrder = [System.Collections.Generic.List[string]]::new()
    $seenGroups = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in ($baseOrder + $oursOrder + $theirsOrder)) {
        if (-not $merge.Items.ContainsKey($id)) { continue }
        $g = Get-GroupOf $id
        if ($seenGroups.Add($g)) { $groupOrder.Add($g) }
    }

    foreach ($g in $groupOrder) {
        $idsInGroup = @($merge.Ids | Where-Object { (Get-GroupOf $_) -eq $g })

        $baseSub   = @($baseOrder   | Where-Object { $groupOfBase.ContainsKey($_)   -and $groupOfBase[$_]   -eq $g -and $idsInGroup -contains $_ })
        $oursSub   = @($oursOrder   | Where-Object { $groupOfOurs.ContainsKey($_)   -and $groupOfOurs[$_]   -eq $g -and $idsInGroup -contains $_ })
        $theirsSub = @($theirsOrder | Where-Object { $groupOfTheirs.ContainsKey($_) -and $groupOfTheirs[$_] -eq $g -and $idsInGroup -contains $_ })

        $sameArr = { param($a, $b) ($a -join "`u{1}") -eq ($b -join "`u{1}") }

        $orderedIds = $null
        if (& $sameArr $oursSub $theirsSub)      { $orderedIds = $oursSub }
        elseif (& $sameArr $oursSub $baseSub)     { $orderedIds = $theirsSub }
        elseif (& $sameArr $theirsSub $baseSub)   { $orderedIds = $oursSub }

        if ($null -ne $orderedIds) {
            # No ordering conflict for this group - place items, keeping any not
            # present in the chosen sub-order (e.g. added-by-both-differently ids
            # resolved via Merge-IdentitySet) at the end in merge-input order.
            $remaining = @($idsInGroup | Where-Object { $orderedIds -notcontains $_ })
            foreach ($id in (@($orderedIds) + $remaining)) {
                $item = $merge.Items[$id]
                if ($item.Status -eq 'Kept') {
                    $out.AddRange([string[]](Format-ElementForOutput -Element $item.Element -IndentLevel $indentLevel))
                }
                else {
                    $out.Add("$lt ours")
                    if ($item.OursElement)   { $out.AddRange([string[]](Format-ElementForOutput -Element $item.OursElement   -IndentLevel $indentLevel)) }
                    $out.Add($sep)
                    if ($item.TheirsElement) { $out.AddRange([string[]](Format-ElementForOutput -Element $item.TheirsElement -IndentLevel $indentLevel)) }
                    $out.Add("$gt theirs")
                    $merge.HasConflict = $true
                }
            }
        }
        else {
            # Both sides reordered this group differently and disagree with base -
            # surface the whole group as a single conflict block.
            $out.Add("$lt ours")
            foreach ($id in $oursSub)   { if ($oursMap.ContainsKey($id))   { $out.AddRange([string[]](Format-ElementForOutput -Element $oursMap[$id]   -IndentLevel $indentLevel)) } }
            $out.Add($sep)
            foreach ($id in $theirsSub) { if ($theirsMap.ContainsKey($id)) { $out.AddRange([string[]](Format-ElementForOutput -Element $theirsMap[$id] -IndentLevel $indentLevel)) } }
            $out.Add("$gt theirs")
            $merge.HasConflict = $true
        }
    }

    return @{ Lines = $out.ToArray(); HasConflict = $merge.HasConflict }
}

# ─── Entry point ─────────────────────────────────────────────────────────────

$displayPath = if ($FilePath) { $FilePath } else { $Ours }
Write-Host "Merging D365FO metadata XML: $displayPath"

$gitCmd = Get-Command git -ErrorAction Ignore
if (-not $gitCmd) { throw "git executable not found on PATH; it is required to run the base 3-way text merge." }

$mergeOutput = & git merge-file --diff3 "--marker-size=$MarkerSize" -L ours -L base -L theirs -p $Ours $Base $Theirs 2>$null
$gitExitCode = $LASTEXITCODE

if ($gitExitCode -lt 0) {
    throw "git merge-file failed for '$displayPath' (exit code $gitExitCode)."
}

$originalOursText = Get-Content -LiteralPath $Ours -Raw
$newline = if ($originalOursText -match "`r`n") { "`r`n" } else { "`n" }

$lines = @($mergeOutput -split "`n" | ForEach-Object { $_.TrimEnd("`r") })

if ($gitExitCode -eq 0) {
    [System.IO.File]::WriteAllText($Ours, (($lines -join $newline) + $newline), [System.Text.UTF8Encoding]::new($false))
    exit 0
}

$rulesPath = Get-RulesFilePath -RulesFile $RulesFile
$rules     = Read-MergeRules -Path $rulesPath
$hunks     = Find-ConflictHunks -Lines $lines

# Namespace declarations from the document root, so hunk fragments parsed in a
# synthetic wrapper element still resolve prefixes (e.g. "i:type") correctly.
$rootNsDecl = ''
try {
    $baseDoc = [System.Xml.XmlDocument]::new()
    $baseDoc.Load($Base)
    $nsAttrs = @($baseDoc.DocumentElement.Attributes | Where-Object { $_.Name -eq 'xmlns' -or $_.Name.StartsWith('xmlns:') })
    $rootNsDecl = ($nsAttrs | ForEach-Object { "$($_.Name)=`"$($_.Value)`"" }) -join ' '
}
catch {
    # Base may not be parseable XML in edge cases - fall back to no extra declarations.
}

$output       = [System.Collections.Generic.List[string]]::new()
$cursor       = 0
$hasConflict  = $false
$unresolvedIds = [System.Collections.Generic.List[int]]::new()

for ($h = 0; $h -lt $hunks.Count; $h++) {
    $hunk = $hunks[$h]
    for ($k = $cursor; $k -lt $hunk.Start; $k++) { $output.Add($lines[$k]) }

    $precedingText = $output -join "`n"
    $ancestorPath  = Get-AncestorPath -Text $precedingText

    $resolved = $null
    if ($rules.Count -gt 0) {
        $resolved = Resolve-CollectionHunk -Hunk $hunk -Rules $rules -AncestorPath $ancestorPath -MarkerSize $MarkerSize -RootNsDecl $rootNsDecl
    }

    if ($null -ne $resolved) {
        $output.AddRange([string[]]$resolved.Lines)
        if ($resolved.HasConflict) { $hasConflict = $true; $unresolvedIds.Add($h) }
    }
    else {
        for ($k = $hunk.Start; $k -lt $hunk.End; $k++) { $output.Add($lines[$k]) }
        $hasConflict = $true
        $unresolvedIds.Add($h)
    }

    $cursor = $hunk.End
}
for ($k = $cursor; $k -lt $lines.Count; $k++) { $output.Add($lines[$k]) }

[System.IO.File]::WriteAllText($Ours, (($output -join $newline) + $newline), [System.Text.UTF8Encoding]::new($false))

if ($hasConflict) {
    Write-Warning "Merge conflicts remain in '$displayPath' ($($unresolvedIds.Count) of $($hunks.Count) hunk(s))."
    exit 1
}

Write-Host "Resolved $($hunks.Count) conflicting hunk(s) in '$displayPath' using order-independent collection rules."
exit 0
