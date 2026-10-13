<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0
<#
.SYNOPSIS
    Git merge driver for D365FO metadata XML files.

.DESCRIPTION
    Resolves non-overlapping changes to explicitly configured unordered XML
    sibling collections before asking git merge-file to handle the remaining
    changes. Collection items are treated as complete subtrees and identified
    by their direct-child Name element. XML outside a successfully merged
    collection is left for Git to merge normally.

.PARAMETER Base
    Ancestor (base) version of the file. Supplied as %O by git.

.PARAMETER Ours
    Current-branch version. Supplied as %A by git; merged output is written here.

.PARAMETER Theirs
    Other-branch version of the file. Supplied as %B by git.

.PARAMETER MarkerSize
    Conflict-marker width supplied as %L by git. Defaults to 7.

.PARAMETER FilePath
    Repository-relative path supplied as %P by git, for diagnostics.

.PARAMETER RulesPath
    Optional UTF-8 text file containing one absolute XPath per line. Defaults
    to Default-UnorderedElements.rules beside this script.

.EXAMPLE
    git config merge.d365fo-xml.driver 'pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365MetadataXml.ps1 -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Base,

    [Parameter(Mandatory)]
    [string]$Ours,

    [Parameter(Mandatory)]
    [string]$Theirs,

    [int]$MarkerSize = 7,

    [string]$FilePath = '',

    [string]$RulesPath = (Join-Path $PSScriptRoot 'Default-UnorderedElements.rules')
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Read-XmlFile {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = [System.Text.UTF32Encoding]::new($true, $true)
        $offset = 4
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = [System.Text.UTF32Encoding]::new($false, $true)
        $offset = 4
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true)
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true)
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true)
        $offset = 2
    }
    else {
        $encoding = [System.Text.UTF8Encoding]::new($false)
    }

    return [pscustomobject]@{
        Path = $Path
        Text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        Encoding = $encoding
        HasPreamble = ($offset -gt 0)
    }
}

function Get-TextOffset {
    param(
        [string]$Text,
        [int[]]$LineStarts,
        [int]$Line,
        [int]$Column
    )

    if ($Line -lt 1 -or $Line -gt $LineStarts.Length) {
        throw "Invalid XML source location at line $Line, column $Column."
    }
    return $LineStarts[$Line - 1] + $Column - 1
}

function Find-XmlTagEnd {
    param([string]$Text, [int]$Start)

    $quote = [char]0
    for ($index = $Start; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
        }
        elseif ($character -eq [char]39 -or $character -eq [char]34) {
            $quote = $character
        }
        elseif ($character -eq '>') {
            return $index + 1
        }
    }
    throw 'Could not find the end of an XML tag.'
}

function Get-XmlSpans {
    param([pscustomobject]$Source)

    $document = [System.Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    $document.LoadXml($Source.Text)
    $elements = @($document.SelectNodes('//*'))

    $lineStarts = [System.Collections.Generic.List[int]]::new()
    $lineStarts.Add(0)
    for ($index = 0; $index -lt $Source.Text.Length; $index++) {
        if ($Source.Text[$index] -eq "`r") {
            if ($index + 1 -lt $Source.Text.Length -and $Source.Text[$index + 1] -eq "`n") { $index++ }
            $lineStarts.Add($index + 1)
        }
        elseif ($Source.Text[$index] -eq "`n") {
            $lineStarts.Add($index + 1)
        }
    }

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.IgnoreWhitespace = $false
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Source.Text), $settings)
    $lineInfo = [System.Xml.IXmlLineInfo]$reader
    $spans = [System.Collections.Generic.Dictionary[System.Xml.XmlNode, object]]::new()
    $stack = [System.Collections.Generic.List[object]]::new()
    $elementIndex = 0

    try {
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                $start = Get-TextOffset $Source.Text $lineStarts.ToArray() $lineInfo.LineNumber ($lineInfo.LinePosition - 1)
                $span = [pscustomobject]@{
                    Node = $elements[$elementIndex]
                    Start = $start
                    OpenEnd = (Find-XmlTagEnd $Source.Text $start)
                    EndTagStart = $null
                    End = $null
                }
                $elementIndex++
                if ($reader.IsEmptyElement) {
                    $span.End = $span.OpenEnd
                }
                else {
                    $stack.Add($span)
                }
                $spans.Add($span.Node, $span)
            }
            elseif ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                $span = $stack[$stack.Count - 1]
                $span.EndTagStart = Get-TextOffset $Source.Text $lineStarts.ToArray() $lineInfo.LineNumber ($lineInfo.LinePosition - 2)
                $span.End = Find-XmlTagEnd $Source.Text $span.EndTagStart
                $stack.RemoveAt($stack.Count - 1)
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($elementIndex -ne $elements.Count -or $stack.Count -ne 0) {
        throw "Could not map XML source locations in '$($Source.Path)'."
    }
    return [pscustomobject]@{ Document = $document; Spans = $spans }
}

function Add-FingerprintPart {
    param([System.Collections.Generic.List[string]]$Parts, [string]$Value)
    $Parts.Add("$($Value.Length):$Value")
}

function Add-NodeFingerprint {
    param(
        [System.Xml.XmlNode]$Node,
        [System.Collections.Generic.List[string]]$Parts
    )

    if ($Node.NodeType -eq [System.Xml.XmlNodeType]::Element) {
        Add-FingerprintPart $Parts "E$($Node.NamespaceURI):$($Node.LocalName)"
        $attributes = @($Node.Attributes | Sort-Object NamespaceURI, LocalName)
        foreach ($attribute in $attributes) {
            Add-FingerprintPart $Parts "A$($attribute.NamespaceURI):$($attribute.LocalName)=$($attribute.Value)"
        }
        $hasElements = $false
        foreach ($child in $Node.ChildNodes) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) { $hasElements = $true; break }
        }
        foreach ($child in $Node.ChildNodes) {
            if ($hasElements -and ($child.NodeType -eq [System.Xml.XmlNodeType]::Whitespace -or $child.NodeType -eq [System.Xml.XmlNodeType]::SignificantWhitespace)) { continue }
            Add-NodeFingerprint $child $Parts
        }
        Add-FingerprintPart $Parts '/E'
    }
    elseif ($Node.NodeType -eq [System.Xml.XmlNodeType]::Text -or
        $Node.NodeType -eq [System.Xml.XmlNodeType]::CDATA -or
        $Node.NodeType -eq [System.Xml.XmlNodeType]::Whitespace -or
        $Node.NodeType -eq [System.Xml.XmlNodeType]::SignificantWhitespace) {
        Add-FingerprintPart $Parts "T$($Node.Value)"
    }
    elseif ($Node.NodeType -eq [System.Xml.XmlNodeType]::Comment -or
        $Node.NodeType -eq [System.Xml.XmlNodeType]::ProcessingInstruction) {
        Add-FingerprintPart $Parts "X$($Node.NodeType):$($Node.Value)"
    }
}

function Get-NodeFingerprint {
    param([System.Xml.XmlNode]$Node)
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-NodeFingerprint $Node $parts
    return ($parts -join '')
}

function Get-NodeIdentity {
    param([System.Xml.XmlNode]$Node)

    $name = $Node.SelectSingleNode('./Name')
    if ($null -ne $name) { return "N:$($name.InnerText)" }
    return "F:$(Get-NodeFingerprint $Node)"
}

function Get-CollectionMap {
    param([System.Xml.XmlNode[]]$Nodes)

    $map = [System.Collections.Generic.Dictionary[string, System.Xml.XmlNode]]::new([System.StringComparer]::Ordinal)
    $orderedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $Nodes) {
        $key = Get-NodeIdentity $node
        if ($map.ContainsKey($key)) { throw "Duplicate unordered sibling identity '$key'." }
        $map.Add($key, $node)
        $orderedKeys.Add($key)
    }
    return [pscustomobject]@{ Map = $map; Keys = $orderedKeys }
}

function Get-CollectionMerge {
    param(
        [pscustomobject]$BaseCollection,
        [pscustomobject]$OursCollection,
        [pscustomobject]$TheirsCollection
    )

    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $BaseCollection.Keys) { [void]$keys.Add($key) }
    foreach ($key in $OursCollection.Keys) { [void]$keys.Add($key) }
    foreach ($key in $TheirsCollection.Keys) { [void]$keys.Add($key) }

    $selected = [System.Collections.Generic.Dictionary[string, System.Xml.XmlNode]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $keys) {
        $inBase = $BaseCollection.Map.ContainsKey($key)
        $inOurs = $OursCollection.Map.ContainsKey($key)
        $inTheirs = $TheirsCollection.Map.ContainsKey($key)
        if (-not $inBase) {
            if ($inOurs -and $inTheirs) {
                if ((Get-NodeFingerprint $OursCollection.Map[$key]) -ne (Get-NodeFingerprint $TheirsCollection.Map[$key])) { return $null }
                $selected.Add($key, $OursCollection.Map[$key])
            }
            elseif ($inOurs) { $selected.Add($key, $OursCollection.Map[$key]) }
            elseif ($inTheirs) { $selected.Add($key, $TheirsCollection.Map[$key]) }
            continue
        }

        $baseFingerprint = Get-NodeFingerprint $BaseCollection.Map[$key]
        $oursChanged = $inOurs -and ((Get-NodeFingerprint $OursCollection.Map[$key]) -ne $baseFingerprint)
        $theirsChanged = $inTheirs -and ((Get-NodeFingerprint $TheirsCollection.Map[$key]) -ne $baseFingerprint)
        if (-not $inOurs -and -not $inTheirs) { continue }
        if (-not $inOurs) {
            if ($theirsChanged) { return $null }
            continue
        }
        if (-not $inTheirs) {
            if ($oursChanged) { return $null }
            continue
        }
        if ($oursChanged -and $theirsChanged) {
            if ((Get-NodeFingerprint $OursCollection.Map[$key]) -ne (Get-NodeFingerprint $TheirsCollection.Map[$key])) { return $null }
            $selected.Add($key, $OursCollection.Map[$key])
        }
        elseif ($oursChanged) { $selected.Add($key, $OursCollection.Map[$key]) }
        else { $selected.Add($key, $TheirsCollection.Map[$key]) }
    }

    $ordered = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    $added = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $OursCollection.Keys) {
        if ($selected.ContainsKey($key)) {
            $ordered.Add($selected[$key])
            [void]$added.Add($key)
        }
    }
    foreach ($key in $TheirsCollection.Keys) {
        if ($selected.ContainsKey($key) -and $added.Add($key)) { $ordered.Add($selected[$key]) }
    }
    return ,$ordered
}

function Get-LineIndent {
    param([string]$Text, [int]$Offset)
    $searchOffset = [Math]::Max(0, $Offset - 1)
    $lineStart = [Math]::Max($Text.LastIndexOf("`n", $searchOffset), $Text.LastIndexOf("`r", $searchOffset)) + 1
    $indent = $Text.Substring($lineStart, $Offset - $lineStart)
    if ($indent -match '^\s*$') { return $indent }
    return ''
}

function Get-LineEnding {
    param([string]$Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    if ($Text.Contains("`r")) { return "`r" }
    return "`n"
}

function Get-CollectionPatch {
    param(
        [pscustomobject[]]$Sources,
        [pscustomobject[]]$Parsed,
        [string]$ItemXPath
    )

    $separator = $ItemXPath.LastIndexOf('/')
    if ($separator -lt 1) { throw "Rule must be an absolute XPath to an element beneath a collection: $ItemXPath" }
    $parentXPath = $ItemXPath.Substring(0, $separator)
    $itemName = $ItemXPath.Substring($separator + 1)
    if ($itemName -notmatch '^[A-Za-z_][A-Za-z0-9_.:-]*$') {
        throw "Rule item must be a simple element name: $ItemXPath"
    }

    $parents = [System.Xml.XmlNode[]]::new(3)
    $children = [object[]]::new(3)
    $missingParents = 0
    for ($sourceIndex = 0; $sourceIndex -lt 3; $sourceIndex++) {
        $foundParents = @($Parsed[$sourceIndex].Document.SelectNodes($parentXPath))
        if ($foundParents.Count -eq 0) {
            $missingParents++
            continue
        }
        if ($foundParents.Count -ne 1) {
            Write-Verbose "XPath '$parentXPath' matched $($foundParents.Count) collections in '$($Parsed[$sourceIndex].Document.DocumentElement.Name)'."
            return $null
        }
        $parents[$sourceIndex] = $foundParents[0]
        $childList = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
        foreach ($child in $parents[$sourceIndex].SelectNodes('./*')) {
            $childList.Add($child)
            if ($child.LocalName -ne $itemName) {
                Write-Verbose "Collection '$parentXPath' contains unexpected child '$($child.LocalName)' (expected '$itemName')."
                return $null
            }
        }
        $children[$sourceIndex] = $childList
        foreach ($childNode in $parents[$sourceIndex].ChildNodes) {
            if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element -or
                $childNode.NodeType -eq [System.Xml.XmlNodeType]::Whitespace -or
                $childNode.NodeType -eq [System.Xml.XmlNodeType]::SignificantWhitespace) { continue }
            if (($childNode.NodeType -eq [System.Xml.XmlNodeType]::Text) -and [string]::IsNullOrWhiteSpace($childNode.Value)) { continue }
            Write-Verbose "Collection '$parentXPath' contains non-element content that cannot be preserved safely."
            return $null
        }
    }
    if ($missingParents -eq 3) { return [pscustomobject]@{ NoMatch = $true } }
    if ($missingParents -gt 0) { return $null }

    $attributes = { param($node) (@($node.Attributes | Sort-Object NamespaceURI, LocalName | ForEach-Object { "$($_.NamespaceURI):$($_.LocalName)=$($_.Value)" }) -join '|') }
    if ($parents[0].LocalName -ne $parents[1].LocalName -or $parents[0].LocalName -ne $parents[2].LocalName -or
        (& $attributes $parents[0]) -ne (& $attributes $parents[1]) -or
        (& $attributes $parents[0]) -ne (& $attributes $parents[2])) {
        Write-Verbose "Collection '$parentXPath' differs in name or attributes across merge inputs."
        return $null
    }

    try {
        $baseCollection = Get-CollectionMap $children[0].ToArray()
        $oursCollection = Get-CollectionMap $children[1].ToArray()
        $theirsCollection = Get-CollectionMap $children[2].ToArray()
    }
    catch {
        Write-Verbose "Collection '$parentXPath' has duplicate sibling identities: $($_.Exception.Message)"
        return $null
    }
    $mergedNodes = Get-CollectionMerge $baseCollection $oursCollection $theirsCollection
    if ($null -eq $mergedNodes) {
        Write-Verbose "Collection '$parentXPath' contains conflicting changes to the same sibling."
        return $null
    }

    $parentIndent = $null
    $childIndent = $null
    $newline = Get-LineEnding $Sources[0].Text
    for ($sourceIndex = 1; $sourceIndex -ge 0; $sourceIndex--) {
        $parentSpan = $Parsed[$sourceIndex].Spans[$parents[$sourceIndex]]
        $parentIndent = Get-LineIndent $Sources[$sourceIndex].Text $parentSpan.Start
        if ($children[$sourceIndex].Count -gt 0) {
            $itemSpan = $Parsed[$sourceIndex].Spans[$children[$sourceIndex][0]]
            $childIndent = Get-LineIndent $Sources[$sourceIndex].Text $itemSpan.Start
            if ($childIndent -eq $parentIndent) { $childIndent = $parentIndent + "`t" }
            break
        }
    }
    if ($null -eq $childIndent) { $childIndent = $parentIndent + "`t" }

    $baseParentSpan = $Parsed[0].Spans[$parents[0]]
    $baseOpen = $Sources[0].Text.Substring($baseParentSpan.Start, $baseParentSpan.OpenEnd - $baseParentSpan.Start)
    if ($baseOpen -match '/\s*>$') {
        $openTag = [System.Text.RegularExpressions.Regex]::Replace($baseOpen, '/\s*>$', '>')
        $qualifiedParentName = if ([string]::IsNullOrEmpty($parents[0].Prefix)) { $parents[0].LocalName } else { "$($parents[0].Prefix):$($parents[0].LocalName)" }
        $closeTag = "</$qualifiedParentName>"
    }
    else {
        $openTag = $baseOpen
        $closeTag = $Sources[0].Text.Substring($baseParentSpan.EndTagStart, $baseParentSpan.End - $baseParentSpan.EndTagStart)
    }

    $itemText = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $mergedNodes) {
        $sourceIndex = if ($oursCollection.Map.Values -contains $node) { 1 } else { 2 }
        $span = $Parsed[$sourceIndex].Spans[$node]
        $itemText.Add($Sources[$sourceIndex].Text.Substring($span.Start, $span.End - $span.Start))
    }
    if ($itemText.Count -eq 0) {
        $inner = $newline + $parentIndent
    }
    else {
        $inner = $newline + $childIndent + ($itemText -join ($newline + $childIndent)) + $newline + $parentIndent
    }
    $replacement = $openTag + $inner + $closeTag

    $patches = [System.Collections.Generic.List[object]]::new()
    for ($sourceIndex = 0; $sourceIndex -lt 3; $sourceIndex++) {
        $span = $Parsed[$sourceIndex].Spans[$parents[$sourceIndex]]
        $patches.Add([pscustomobject]@{ Start = $span.Start; End = $span.End; Text = $replacement })
    }
    return [pscustomobject]@{ Patches = $patches; NoMatch = $false }
}

function Set-SourceWithPatches {
    param([string]$Text, [object[]]$Patches)
    $orderedPatches = @($Patches | Sort-Object Start -Descending)
    $previousStart = $Text.Length
    foreach ($patch in $orderedPatches) {
        if ($patch.End -gt $previousStart) { throw 'Configured unordered collection rules overlap.' }
        $Text = $Text.Substring(0, $patch.Start) + $patch.Text + $Text.Substring($patch.End)
        $previousStart = $patch.Start
    }
    return $Text
}

$temporaryFiles = [System.Collections.Generic.List[string]]::new()
try {
    if (-not (Test-Path -LiteralPath $RulesPath -PathType Leaf)) { throw "Rules file not found: $RulesPath" }
    $sources = @((Read-XmlFile $Base), (Read-XmlFile $Ours), (Read-XmlFile $Theirs))
    foreach ($source in $sources[1..2]) {
        if ($source.Encoding.WebName -ne $sources[0].Encoding.WebName -or $source.HasPreamble -ne $sources[0].HasPreamble) {
            throw 'Base, ours, and theirs must use the same XML text encoding and byte-order mark.'
        }
    }
    $parsed = @((Get-XmlSpans $sources[0]), (Get-XmlSpans $sources[1]), (Get-XmlSpans $sources[2]))
    $patchesBySource = @([System.Collections.Generic.List[object]]::new(), [System.Collections.Generic.List[object]]::new(), [System.Collections.Generic.List[object]]::new())
    $rules = Get-Content -LiteralPath $RulesPath -Encoding UTF8
    foreach ($rule in $rules) {
        $xpath = $rule.Trim()
        if ([string]::IsNullOrWhiteSpace($xpath) -or $xpath.StartsWith('#')) { continue }
        $collectionPatches = Get-CollectionPatch $sources $parsed $xpath
        if ($null -ne $collectionPatches -and $collectionPatches.NoMatch) { continue }
        if ($null -eq $collectionPatches) {
            [Console]::Error.WriteLine("Skipping unsafe or conflicting unordered collection '$xpath' in '$FilePath'.")
            continue
        }
        for ($sourceIndex = 0; $sourceIndex -lt 3; $sourceIndex++) {
            $patchesBySource[$sourceIndex].Add($collectionPatches.Patches[$sourceIndex])
        }
    }

    $mergedTexts = [string[]]::new(3)
    for ($sourceIndex = 0; $sourceIndex -lt 3; $sourceIndex++) {
        $mergedTexts[$sourceIndex] = Set-SourceWithPatches $sources[$sourceIndex].Text $patchesBySource[$sourceIndex].ToArray()
    }

    $tempBase = [System.IO.Path]::GetTempFileName()
    $temporaryFiles.Add($tempBase)
    $tempOurs = [System.IO.Path]::GetTempFileName()
    $temporaryFiles.Add($tempOurs)
    $tempTheirs = [System.IO.Path]::GetTempFileName()
    $temporaryFiles.Add($tempTheirs)
    for ($sourceIndex = 0; $sourceIndex -lt 3; $sourceIndex++) {
        $temporaryPath = @($tempBase, $tempOurs, $tempTheirs)[$sourceIndex]
        [System.IO.File]::WriteAllText($temporaryPath, $mergedTexts[$sourceIndex], $sources[$sourceIndex].Encoding)
    }

    & git merge-file --diff3 "--marker-size=$MarkerSize" $tempOurs $tempBase $tempTheirs
    $mergeExitCode = $LASTEXITCODE
    if ($mergeExitCode -gt 1) { throw "git merge-file failed with exit code $mergeExitCode." }
    [System.IO.File]::Copy($tempOurs, $Ours, $true)
    exit $mergeExitCode
}
catch {
    [Console]::Error.WriteLine("D365FO XML merge failed for '$FilePath': $($_.Exception.Message)")
    exit 2
}
finally {
    foreach ($temporaryFile in $temporaryFiles) {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
    }
}