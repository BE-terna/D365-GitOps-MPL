<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0
<#
.SYNOPSIS
    Git merge driver for XML files whose repeated sibling elements are order-independent
    (for example D365FO metadata).

.DESCRIPTION
    Merge-driver mode (invoked automatically by git during a merge):
        1. Runs git's line-based 3-way merge (git merge-file). A clean result is kept as is.
        2. If that merge conflicts, sibling elements selected by the rules file are merged as
           an unordered collection: elements added on both sides are all kept (ours first,
           then theirs), deletions and one-sided changes are applied, and an element changed
           on both sides is left to the line-based merge. The line-based merge then runs again
           on the prepared versions. Only the text of the affected collections is rewritten;
           all other content (formatting, attribute layout, CDATA, line endings, BOM) is kept
           byte-for-byte.
        3. Remaining conflicts are written as standard git conflict markers and the script
           exits 1 so git marks the file as conflicted.

    The driver is not limited to D365FO: the rules decide which elements are order-independent.

    Rules file - one rule per line, lines starting with '#' are comments:
        <xpath> [key=<xpath>]
    <xpath> selects the order-independent elements. Element names are matched by local name,
    so rules work for namespaced documents without prefixes. The optional key is evaluated on
    each selected element and identifies it across base/ours/theirs (case-insensitive). Without a
    key the whole element is its identity. See D365FO.xmlmergerules for details and defaults.

    Rules file lookup (first match wins):
        -RulesPath, $env:D365GITOPS_XML_MERGE_RULES, <repository root>/.xmlmergerules,
        D365FO.xmlmergerules next to this script (defaults shipped with the module).

    Export mode (-ExportDefaultRules):
        Writes the shipped default rules to a file, e.g. to customize and commit them as
        <repository root>/.xmlmergerules.

    Register the merge driver once per clone (or in a pipeline step):
        git config merge.d365fo-xml.name   "XML merger for order-independent elements"
        git config merge.d365fo-xml.driver "pwsh -NoProfile -File D365GitOps/functions/MergeDrivers/Merge-D365XmlFile.ps1 -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"
    and assign files to it in .gitattributes:
        *.xml merge=d365fo-xml

    Alternatively, install the D365GitOps module and run:
        Register-D365XmlFileMergeDriver

.EXAMPLE
    # Create a repository rules file from the shipped D365FO defaults:
    Merge-D365XmlFile -ExportDefaultRules ./.xmlmergerules

.EXAMPLE
    # Merge three versions the way git does; the result is written to ours.xml:
    pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365XmlFile.ps1 -Base base.xml -Ours ours.xml -Theirs theirs.xml
#>
[CmdletBinding(DefaultParameterSetName = 'MergeDriver')]
param(
    # [Merge-driver] Ancestor (base) version of the file. Supplied as %O by git.
    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]
    $Base
    ,
    # [Merge-driver] Current-branch version. Supplied as %A by git; the merged result is written here.
    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]
    $Ours
    ,
    # [Merge-driver] Other-branch version. Supplied as %B by git.
    [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
    [string]
    $Theirs
    ,
    # [Merge-driver] Width of conflict-marker lines. Supplied as %L by git.
    [Parameter(ParameterSetName = 'MergeDriver')]
    [int]
    $MarkerSize = 7
    ,
    # [Merge-driver] Repository-relative path of the file. Supplied as %P by git; used in messages only.
    [Parameter(ParameterSetName = 'MergeDriver')]
    [string]
    $FilePath = ''
    ,
    # [Merge-driver] Rules file; takes precedence over $env:D365GITOPS_XML_MERGE_RULES and <repository root>/.xmlmergerules.
    [Parameter(ParameterSetName = 'MergeDriver')]
    [string]
    $RulesPath = ''
    ,
    # [Export] Path of the file that receives the default rules shipped with this script.
    [Parameter(Mandatory, ParameterSetName = 'ExportDefaultRules')]
    [string]
    $ExportDefaultRules
    ,
    # [Export] Overwrites an existing file.
    [Parameter(ParameterSetName = 'ExportDefaultRules')]
    [switch]
    $Force
)

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$defaultRulesPath = Join-Path $PSScriptRoot 'D365FO.xmlmergerules'

if ($PSCmdlet.ParameterSetName -eq 'ExportDefaultRules') {
    if ((Test-Path -LiteralPath $ExportDefaultRules) -and -not $Force) {
        throw "File '$ExportDefaultRules' already exists. Use -Force to overwrite it."
    }
    Copy-Item -LiteralPath $defaultRulesPath -Destination $ExportDefaultRules -Force
    return Get-Item -LiteralPath $ExportDefaultRules
}

$tagStopChars = [char[]]@('"', "'", '>')
$nameStopChars = [char[]]@(' ', "`t", "`r", "`n", '/', '>')
$disableFormatting = [System.Xml.Linq.SaveOptions]::DisableFormatting
$namespacedElements = [System.Xml.XPath.XPathExpression]::Compile("//*[namespace-uri() != '']")
$sideNames = 'Base', 'Ours', 'Theirs'

# ─── Files and rules ─────────────────────────────────────────────────────────

function Read-XmlTextFile {
    <#
    .SYNOPSIS
        Reads a file as strict UTF-8 and remembers whether it starts with a BOM.
    #>
    param(
        [string]
        $Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    # Throws for non UTF-8 content (e.g. UTF-16), which keeps git's line-based result.
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom }
}

function Resolve-RulesFile {
    <#
    .SYNOPSIS
        Returns the rules file: parameter, environment variable, repository file or shipped defaults.
    #>
    $candidate = if (-not [string]::IsNullOrWhiteSpace($RulesPath)) {
        $RulesPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:D365GITOPS_XML_MERGE_RULES)) {
        $env:D365GITOPS_XML_MERGE_RULES
    }

    if ($candidate) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Rules file '$candidate' not found."
        }
        return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }

    $repositoryRoot = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $repositoryRoot) {
        $repositoryRules = Join-Path $repositoryRoot '.xmlmergerules'
        if (Test-Path -LiteralPath $repositoryRules -PathType Leaf) {
            return (Resolve-Path -LiteralPath $repositoryRules).ProviderPath
        }
    }
    return $defaultRulesPath
}

function Read-XmlMergeRule {
    <#
    .SYNOPSIS
        Parses a rules file into rule objects (Index, Path, Key) with compiled XPath expressions.
    #>
    param(
        [string]
        $Path
    )

    $rules = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }
        $null = $trimmed -match '^(?<path>.+?)(?:\s+key\s*=\s*(?<key>.+))?$'
        $pathText = $Matches['path']
        $keyText = $Matches['key']
        try {
            $pathExpression = [System.Xml.XPath.XPathExpression]::Compile($pathText)
            $keyExpression = if ($keyText) { [System.Xml.XPath.XPathExpression]::Compile("string($keyText)") } else { $null }
        }
        catch {
            throw "Invalid rule in '$Path' line ${lineNumber}: $($_.Exception.Message)"
        }
        $rules.Add([pscustomobject]@{
                Index   = $rules.Count
                Path    = $pathExpression
                Key     = $keyExpression
                # Fast path for the common key=ChildElementName.
                KeyName = if ($keyText -match '^[\p{L}_][\p{L}\p{N}_.-]*$') { $keyText } else { $null }
            })
    }
    return , $rules
}

function New-XmlReaderSettings {
    <#
    .SYNOPSIS
        XML reader settings without DTD processing and external resolution (no XXE).
    #>
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $settings.IgnoreWhitespace = $true
    return $settings
}

function Test-WellFormedXml {
    <#
    .SYNOPSIS
        Returns $true when the bytes are well-formed UTF-8 XML.
    #>
    param(
        [byte[]]
        $Bytes
    )

    try {
        $offset = if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { 3 } else { 0 }
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $offset, $Bytes.Length - $offset)
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($text), (New-XmlReaderSettings))
        try {
            while ($reader.Read()) { }
        }
        finally {
            $reader.Dispose()
        }
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-GitMergeFile {
    <#
    .SYNOPSIS
        Line-based 3-way merge via git merge-file; Conflicts is the git exit code (conflict count).
    #>
    param(
        [string]
        $OursPath
        ,
        [string]
        $BasePath
        ,
        [string]
        $TheirsPath
        ,
        [string]
        $ResultPath
    )

    Copy-Item -LiteralPath $OursPath -Destination $ResultPath -Force
    $null = & git merge-file "--marker-size=$MarkerSize" -L ours -L base -L theirs $ResultPath $BasePath $TheirsPath
    return [pscustomobject]@{
        Conflicts = $LASTEXITCODE
        Bytes     = [System.IO.File]::ReadAllBytes($ResultPath)
    }
}

# ─── XML model ───────────────────────────────────────────────────────────────

function ConvertTo-XmlModel {
    <#
    .SYNOPSIS
        Parses XML text into an XDocument with line info and namespace-free element names (for
        the XPath rules); element text spans are computed on demand by Get-ElementSpan.
    #>
    param(
        [string]
        $Text
    )

    $model = [pscustomobject]@{
        Text       = $Text
        Document   = $null
        LineBreaks = $null
        Spans      = [System.Collections.Generic.Dictionary[System.Xml.Linq.XElement, object]]::new()
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        # Empty base of an add/add conflict.
        return $model
    }

    # Same line breaks as XmlReader line info; matches are computed natively and indexed on demand.
    $model.LineBreaks = [regex]::Matches($Text, '\r\n?|\n')

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text), (New-XmlReaderSettings))
    try {
        $model.Document = [System.Xml.Linq.XDocument]::Load($reader, [System.Xml.Linq.LoadOptions]::SetLineInfo)
    }
    finally {
        $reader.Dispose()
    }

    # Rules match local names: drop namespaces from element names in the in-memory copy.
    if ($Text.Contains('xmlns')) {
        $namespaced = [System.Collections.Generic.List[System.Xml.Linq.XElement]]::new()
        $iterator = [System.Xml.XPath.Extensions]::CreateNavigator($model.Document).Select($namespacedElements)
        while ($iterator.MoveNext()) {
            $namespaced.Add($iterator.Current.UnderlyingObject)
        }
        foreach ($element in $namespaced) {
            $element.Name = $element.Name.LocalName
            $declaration = $element.Attribute('xmlns')
            if ($null -ne $declaration) {
                $declaration.Remove()
            }
        }
    }
    return $model
}

function Get-NodeOffset {
    <#
    .SYNOPSIS
        Text offset of a node's line info position.
    #>
    param(
        $Model
        ,
        [System.Xml.IXmlLineInfo]
        $LineInfo
    )

    if ($LineInfo.LineNumber -le 1) {
        return $LineInfo.LinePosition - 1
    }
    $lineBreak = $Model.LineBreaks[$LineInfo.LineNumber - 2]
    return $lineBreak.Index + $lineBreak.Length + $LineInfo.LinePosition - 1
}

function Get-NodeStart {
    <#
    .SYNOPSIS
        Text offset of a node; line info points behind '<', '<!--', '<![CDATA[' or '<?'.
    #>
    param(
        $Model
        ,
        [System.Xml.Linq.XNode]
        $Node
    )

    $offset = Get-NodeOffset -Model $Model -LineInfo $Node
    if ($Node -is [System.Xml.Linq.XElement]) {
        return $offset - 1
    }
    if ($Node -is [System.Xml.Linq.XCData]) {
        return $offset - 9
    }
    if ($Node -is [System.Xml.Linq.XComment]) {
        return $offset - 4
    }
    if ($Node -is [System.Xml.Linq.XProcessingInstruction]) {
        return $offset - 2
    }
    return $offset
}

function Get-ElementSpan {
    <#
    .SYNOPSIS
        Text span of an element: Start, StartTagEnd, ContentEnd, End, IsEmpty, QualifiedName.
    #>
    param(
        $Model
        ,
        [System.Xml.Linq.XElement]
        $Element
    )

    $span = $null
    if ($Model.Spans.TryGetValue($Element, [ref]$span)) {
        return $span
    }

    $text = $Model.Text
    $start = Get-NodeStart -Model $Model -Node $Element
    # End of the start tag: first '>' outside quoted attribute values.
    $index = $start + 1
    while ($true) {
        $stop = $text.IndexOfAny($tagStopChars, $index)
        if ($stop -lt 0) {
            throw "Unterminated start tag at offset $start."
        }
        if ($text[$stop] -eq [char]'>') {
            break
        }
        $index = $text.IndexOf($text[$stop], $stop + 1) + 1
        if ($index -le 0) {
            throw "Unterminated attribute value at offset $stop."
        }
    }
    $startTagEnd = $stop + 1
    $isEmpty = $text[$stop - 1] -eq [char]'/'
    if ($isEmpty) {
        $contentEnd = $end = $startTagEnd
    }
    else {
        # The end tag closes right before the next node, or before the parent's end tag.
        $next = $Element.NextNode
        $limit = if ($null -ne $next) {
            Get-NodeStart -Model $Model -Node $next
        }
        elseif ($null -ne $Element.Parent) {
            (Get-ElementSpan -Model $Model -Element $Element.Parent).ContentEnd
        }
        else {
            $text.Length
        }
        $end = $text.LastIndexOf([char]'>', $limit - 1) + 1
        $contentEnd = $text.LastIndexOf('</', $end - 1, [System.StringComparison]::Ordinal)
    }
    $nameEnd = $text.IndexOfAny($nameStopChars, $start + 1)
    $span = [pscustomobject]@{
        Start         = $start
        StartTagEnd   = $startTagEnd
        ContentEnd    = $contentEnd
        End           = $end
        IsEmpty       = $isEmpty
        QualifiedName = $text.Substring($start + 1, $nameEnd - $start - 1)
    }
    $Model.Spans.Add($Element, $span)
    return $span
}

function Get-CollectionMember {
    <#
    .SYNOPSIS
        Identity keys of the elements selected by the rules (unique per parent) and their
        parents in document order.
    #>
    param(
        $Model
        ,
        $Rules
    )

    $memberKeys = [System.Collections.Generic.Dictionary[System.Xml.Linq.XElement, string]]::new()
    $parents = [System.Collections.Generic.List[System.Xml.Linq.XElement]]::new()
    $result = [pscustomobject]@{ Keys = $memberKeys; Parents = $parents }
    if ($null -eq $Model.Document) {
        return $result
    }

    $baseKeys = [System.Collections.Generic.Dictionary[System.Xml.Linq.XElement, string]]::new()
    $parentSet = [System.Collections.Generic.HashSet[System.Xml.Linq.XElement]]::new()
    $navigator = [System.Xml.XPath.Extensions]::CreateNavigator($Model.Document)
    foreach ($rule in $Rules) {
        $iterator = $navigator.Select($rule.Path)
        while ($iterator.MoveNext()) {
            $element = $iterator.Current.UnderlyingObject -as [System.Xml.Linq.XElement]
            if ($null -eq $element -or $null -eq $element.Parent -or $baseKeys.ContainsKey($element)) {
                continue
            }
            $keyValue = if ($null -ne $rule.KeyName) {
                $keyElement = $element.Element($rule.KeyName)
                if ($null -ne $keyElement) { $keyElement.Value }
            }
            elseif ($null -ne $rule.Key) {
                [string]([System.Xml.XPath.Extensions]::CreateNavigator($element).Evaluate($rule.Key))
            }
            $baseKey = if ($keyValue) {
                "k$($rule.Index):$($keyValue.ToUpperInvariant())"
            }
            else {
                "s$($rule.Index):$($element.ToString($disableFormatting))"
            }
            $baseKeys.Add($element, $baseKey)
            if ($parentSet.Add($element.Parent)) {
                $parents.Add($element.Parent)
            }
        }
    }

    foreach ($parent in $parents) {
        $occurrences = [System.Collections.Generic.Dictionary[string, int]]::new()
        foreach ($child in $parent.Elements()) {
            $baseKey = $null
            if ($baseKeys.TryGetValue($child, [ref]$baseKey)) {
                $count = 0
                $null = $occurrences.TryGetValue($baseKey, [ref]$count)
                $occurrences[$baseKey] = ++$count
                $memberKeys.Add($child, "$baseKey#$count")
            }
        }
    }
    $parents.Sort([System.Comparison[System.Xml.Linq.XElement]] { param($x, $y) [System.Xml.Linq.XNode]::CompareDocumentOrder($x, $y) })
    return $result
}

function Get-NodeStep {
    <#
    .SYNOPSIS
        Identity of one element below its parent: member key, else position and local name.
    #>
    param(
        $MemberKeys
        ,
        [System.Xml.Linq.XElement]
        $Element
    )

    $key = $null
    if ($MemberKeys.TryGetValue($Element, [ref]$key)) {
        return "k$key"
    }
    return "p$(@($Element.ElementsBeforeSelf($Element.Name)).Count + 1)|$($Element.Name.LocalName)"
}

function Get-IdentityStep {
    <#
    .SYNOPSIS
        Identity steps of an element from the document element down.
    #>
    param(
        $MemberKeys
        ,
        [System.Xml.Linq.XElement]
        $Element
    )

    $steps = [System.Collections.Generic.List[string]]::new()
    for ($current = $Element; $null -ne $current; $current = $current.Parent) {
        $steps.Insert(0, (Get-NodeStep -MemberKeys $MemberKeys -Element $current))
    }
    return , $steps
}

function Find-ByIdentityStep {
    <#
    .SYNOPSIS
        Element matching the identity steps taken from another version, or $null.
    #>
    param(
        $Model
        ,
        $MemberKeys
        ,
        $Steps
    )

    if ($null -eq $Model.Document -or (Get-NodeStep -MemberKeys $MemberKeys -Element $Model.Document.Root) -cne $Steps[0]) {
        return $null
    }
    $current = $Model.Document.Root
    for ($i = 1; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $next = $null
        if ($step[0] -eq [char]'p') {
            $separator = $step.IndexOf('|')
            $candidate = @($current.Elements($step.Substring($separator + 1)))[[int]$step.Substring(1, $separator - 1) - 1]
            if ($null -ne $candidate -and -not $MemberKeys.ContainsKey($candidate)) {
                $next = $candidate
            }
        }
        else {
            foreach ($child in $current.Elements()) {
                $key = $null
                if ($MemberKeys.TryGetValue($child, [ref]$key) -and "k$key" -ceq $step) {
                    $next = $child
                    break
                }
            }
        }
        if ($null -eq $next) {
            return $null
        }
        $current = $next
    }
    return $current
}

# ─── Unordered collection merge ──────────────────────────────────────────────

function Get-CollectionUnit {
    <#
    .SYNOPSIS
        Splits the content of a collection parent into units (leading whitespace/comments +
        member element) and the trailing text; $null when the parent holds anything else.
    #>
    param(
        $Model
        ,
        $MemberKeys
        ,
        [System.Xml.Linq.XElement]
        $Parent
    )

    $span = Get-ElementSpan -Model $Model -Element $Parent
    $text = $Model.Text
    $lineBreaks = $Model.LineBreaks
    $nodes = @($Parent.Nodes())
    # Start offset of every child node; the parent's end tag closes the last one.
    $starts = [int[]]::new($nodes.Count + 1)
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        if ($node -is [System.Xml.Linq.XText]) {
            return $null
        }
        $lineInfo = [System.Xml.IXmlLineInfo]$node
        $offset = $lineInfo.LinePosition - 1
        if ($lineInfo.LineNumber -gt 1) {
            $lineBreak = $lineBreaks[$lineInfo.LineNumber - 2]
            $offset += $lineBreak.Index + $lineBreak.Length
        }
        $starts[$i] = if ($node -is [System.Xml.Linq.XComment]) { $offset - 4 } elseif ($node -is [System.Xml.Linq.XProcessingInstruction]) { $offset - 2 } else { $offset - 1 }
    }
    $starts[$nodes.Count] = $span.ContentEnd

    $units = [System.Collections.Generic.List[object]]::new()
    $cursor = $span.StartTagEnd
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        if ($node -isnot [System.Xml.Linq.XElement]) {
            # Comments and processing instructions travel with the next member.
            continue
        }
        $key = $null
        if (-not $MemberKeys.TryGetValue($node, [ref]$key)) {
            return $null
        }
        $end = $text.LastIndexOf([char]'>', $starts[$i + 1] - 1) + 1
        $lead = $text.Substring($cursor, $starts[$i] - $cursor)
        $leadSignature = if ([string]::IsNullOrWhiteSpace($lead)) { '' } else { $lead -replace '\s+', '' }
        $units.Add([pscustomobject]@{
                Key       = $key
                Signature = "$leadSignature`0$($node.ToString($disableFormatting))"
                Text      = $text.Substring($cursor, $end - $cursor)
            })
        $cursor = $end
    }
    $trail = if (-not $span.IsEmpty) { $text.Substring($cursor, $span.ContentEnd - $cursor) } else { $null }
    return [pscustomobject]@{ Span = $span; Units = $units; Trail = $trail }
}

function ConvertTo-UnitMap {
    <#
    .SYNOPSIS
        Units by key.
    #>
    param(
        $Units
    )

    $map = [System.Collections.Generic.Dictionary[string, object]]::new()
    foreach ($unit in $Units) {
        $map[$unit.Key] = $unit
    }
    return $map
}

function Merge-CollectionUnit {
    <#
    .SYNOPSIS
        3-way merge of unordered units. An entry has a Resolved unit for all versions, or each
        version keeps its own unit (Base/Ours/Theirs) for the line-based merge. Order: ours, then
        theirs additions, then theirs-only changes (stable when applied again).
    #>
    param(
        $BaseUnits
        ,
        $OursUnits
        ,
        $TheirsUnits
    )

    $baseMap = ConvertTo-UnitMap -Units $BaseUnits
    $oursMap = ConvertTo-UnitMap -Units $OursUnits
    $theirsMap = ConvertTo-UnitMap -Units $TheirsUnits
    $plan = [System.Collections.Generic.List[object]]::new()
    $theirsAdded = [System.Collections.Generic.List[object]]::new()
    $theirsChanged = [System.Collections.Generic.List[object]]::new()

    foreach ($o in $OursUnits) {
        $b = $null
        $t = $null
        $null = $baseMap.TryGetValue($o.Key, [ref]$b)
        $null = $theirsMap.TryGetValue($o.Key, [ref]$t)
        if ($null -ne $t) {
            if ($o.Signature -ceq $t.Signature -or ($null -ne $b -and $t.Signature -ceq $b.Signature)) {
                $plan.Add(@{ Resolved = $o })
            }
            elseif ($null -ne $b -and $o.Signature -ceq $b.Signature) {
                $plan.Add(@{ Resolved = $t })
            }
            else {
                # Changed (or added) differently on both sides: left to the line-based merge.
                $plan.Add(@{ Resolved = $null; Base = $b; Ours = $o; Theirs = $t })
            }
        }
        elseif ($null -eq $b) {
            $plan.Add(@{ Resolved = $o })
        }
        elseif ($o.Signature -cne $b.Signature) {
            # Changed by ours, deleted by theirs: the line-based merge reports the conflict.
            $plan.Add(@{ Resolved = $null; Base = $b; Ours = $o })
        }
    }

    foreach ($t in $TheirsUnits) {
        if ($oursMap.ContainsKey($t.Key)) {
            continue
        }
        $b = $null
        $null = $baseMap.TryGetValue($t.Key, [ref]$b)
        if ($null -eq $b) {
            $theirsAdded.Add(@{ Resolved = $t })
        }
        elseif ($t.Signature -cne $b.Signature) {
            # Deleted by ours, changed by theirs: the line-based merge reports the conflict.
            $theirsChanged.Add(@{ Resolved = $null; Base = $b; Theirs = $t })
        }
    }

    $plan.AddRange($theirsAdded)
    $plan.AddRange($theirsChanged)
    return , $plan
}

function Select-Trail {
    <#
    .SYNOPSIS
        Text between the last member and the closing tag, merged 3-way (ours wins on conflict).
    #>
    param(
        $Base
        ,
        $Ours
        ,
        $Theirs
    )

    if ($null -ne $Ours -and $null -ne $Theirs) {
        if ($null -ne $Base -and $Ours -ceq $Base) {
            return $Theirs
        }
        return $Ours
    }
    foreach ($candidate in $Ours, $Theirs, $Base) {
        if ($null -ne $candidate) {
            return $candidate
        }
    }
    return ''
}

function New-CollectionEdit {
    <#
    .SYNOPSIS
        Text edit that replaces the collection content of one version with the merge plan.
    #>
    param(
        $Model
        ,
        $Collection
        ,
        $Plan
        ,
        [string]
        $Side
        ,
        [string]
        $Trail
    )

    $content = [System.Text.StringBuilder]::new()
    $count = 0
    foreach ($entry in $Plan) {
        $unit = if ($null -ne $entry.Resolved) { $entry.Resolved } else { $entry.$Side }
        if ($null -ne $unit) {
            $null = $content.Append($unit.Text)
            $count++
        }
    }

    $span = $Collection.Span
    if ($count -eq 0) {
        if ($Collection.Units.Count -eq 0) {
            return $null
        }
        $startTag = $Model.Text.Substring($span.Start, $span.StartTagEnd - $span.Start)
        return [pscustomobject]@{ Start = $span.Start; End = $span.End; Text = ($startTag -replace '\s*>$', '') + ' />' }
    }

    $null = $content.Append($Trail)
    if ($span.IsEmpty) {
        $tag = $Model.Text.Substring($span.Start, $span.End - $span.Start)
        return [pscustomobject]@{
            Start = $span.Start
            End   = $span.End
            Text  = ($tag -replace '\s*/>$', '>') + $content.ToString() + "</$($span.QualifiedName)>"
        }
    }
    $newContent = $content.ToString()
    if ($Model.Text.Substring($span.StartTagEnd, $span.ContentEnd - $span.StartTagEnd) -ceq $newContent) {
        return $null
    }
    return [pscustomobject]@{ Start = $span.StartTagEnd; End = $span.ContentEnd; Text = $newContent }
}

function Test-EditOverlap {
    <#
    .SYNOPSIS
        $true when the edit overlaps an edit already planned for the same version.
    #>
    param(
        $Edits
        ,
        $Edit
    )

    foreach ($existing in $Edits) {
        if ($Edit.Start -eq $existing.Start -or ($Edit.Start -lt $existing.End -and $existing.Start -lt $Edit.End)) {
            return $true
        }
    }
    return $false
}

function Set-TextEdit {
    <#
    .SYNOPSIS
        Applies non-overlapping edits to a text.
    #>
    param(
        [string]
        $Text
        ,
        $Edits
    )

    $result = [System.Text.StringBuilder]::new()
    $cursor = 0
    foreach ($edit in ($Edits | Sort-Object -Property Start)) {
        $null = $result.Append($Text, $cursor, $edit.Start - $cursor).Append($edit.Text)
        $cursor = $edit.End
    }
    $null = $result.Append($Text, $cursor, $Text.Length - $cursor)
    return $result.ToString()
}

function Invoke-CollectionPass {
    <#
    .SYNOPSIS
        Rewrites every unordered collection found in ours or theirs to the merged member list in
        all three versions. Collections overlapping an earlier rewrite (nested ones) are deferred
        to the next pass. Returns Changed and Deferred flags.
    #>
    param(
        $Sides
        ,
        $Rules
    )

    $states = @{}
    foreach ($side in $Sides) {
        $model = ConvertTo-XmlModel -Text $side.Text
        $members = Get-CollectionMember -Model $model -Rules $Rules
        $states[$side.Name] = [pscustomobject]@{
            Side       = $side
            Model      = $model
            MemberKeys = $members.Keys
            Parents    = $members.Parents
            Edits      = [System.Collections.Generic.List[object]]::new()
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($name in 'Ours', 'Theirs') {
        foreach ($parent in $states[$name].Parents) {
            $candidates.Add([pscustomobject]@{ Name = $name; Parent = $parent })
        }
    }

    $outcome = [pscustomobject]@{ Changed = $false; Deferred = $false }
    $processed = [System.Collections.Generic.HashSet[System.Xml.Linq.XElement]]::new()
    foreach ($candidate in $candidates) {
        $steps = Get-IdentityStep -MemberKeys $states[$candidate.Name].MemberKeys -Element $candidate.Parent
        $collections = @{}
        $skip = $false
        foreach ($name in $sideNames) {
            $state = $states[$name]
            $parent = if ($name -eq $candidate.Name) {
                $candidate.Parent
            }
            else {
                Find-ByIdentityStep -Model $state.Model -MemberKeys $state.MemberKeys -Steps $steps
            }
            if ($null -eq $parent) {
                # Ours and theirs must both contain the parent; a missing base parent means "added".
                if ($name -ne 'Base') {
                    $skip = $true
                    break
                }
                $collections[$name] = $null
                continue
            }
            if ($name -eq 'Ours' -and -not $processed.Add($parent)) {
                $skip = $true
                break
            }
            $collections[$name] = Get-CollectionUnit -Model $state.Model -MemberKeys $state.MemberKeys -Parent $parent
            if ($null -eq $collections[$name]) {
                $skip = $true
                break
            }
        }
        if ($skip) {
            continue
        }

        $baseUnits = $null
        $baseTrail = $null
        if ($null -ne $collections['Base']) {
            $baseUnits = $collections['Base'].Units
            $baseTrail = $collections['Base'].Trail
        }
        $plan = Merge-CollectionUnit -BaseUnits $baseUnits -OursUnits $collections['Ours'].Units -TheirsUnits $collections['Theirs'].Units
        $trail = Select-Trail -Base $baseTrail -Ours $collections['Ours'].Trail -Theirs $collections['Theirs'].Trail

        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $sideNames) {
            if ($null -eq $collections[$name]) {
                continue
            }
            $state = $states[$name]
            $edit = New-CollectionEdit -Model $state.Model -Collection $collections[$name] -Plan $plan -Side $name -Trail $trail
            if ($null -eq $edit) {
                continue
            }
            if (Test-EditOverlap -Edits $state.Edits -Edit $edit) {
                $outcome.Deferred = $true
                $skip = $true
                break
            }
            $pending.Add([pscustomobject]@{ Edits = $state.Edits; Edit = $edit })
        }
        if ($skip) {
            continue
        }
        foreach ($item in $pending) {
            $item.Edits.Add($item.Edit)
        }

        if ($pending.Count -gt 0) {
            $names = @($candidate.Parent.AncestorsAndSelf() | ForEach-Object { $_.Name.LocalName })
            [array]::Reverse($names)
            $lineBased = @($plan | Where-Object { $null -eq $_.Resolved }).Count
            Write-Verbose "/$($names -join '/'): $($plan.Count) element(s), $lineBased left to the line-based merge."
        }
    }

    foreach ($name in $sideNames) {
        $state = $states[$name]
        if ($state.Edits.Count -gt 0) {
            $state.Side.Text = Set-TextEdit -Text $state.Model.Text -Edits $state.Edits
            $outcome.Changed = $true
        }
    }
    return $outcome
}

function Invoke-StructuralMerge {
    <#
    .SYNOPSIS
        Pre-merges the unordered collections of all three versions, then merges line-based again.
        Returns the git merge-file result, or $null when nothing could be improved.
    #>
    param(
        [string]
        $WorkDirectory
    )

    try {
        $rulesFile = Resolve-RulesFile
        Write-Verbose "XML merge rules: $rulesFile"
        $rules = Read-XmlMergeRule -Path $rulesFile
        if ($rules.Count -eq 0) {
            return $null
        }

        $paths = @{ Base = $Base; Ours = $Ours; Theirs = $Theirs }
        $sides = foreach ($name in $sideNames) {
            $file = Read-XmlTextFile -Path $paths[$name]
            [pscustomobject]@{
                Name   = $name
                Text   = $file.Text
                HasBom = $file.HasBom
                Path   = (Join-Path $WorkDirectory "$name.xml")
            }
        }

        $changed = $false
        for ($pass = 1; ; $pass++) {
            $outcome = Invoke-CollectionPass -Sides $sides -Rules $rules
            $changed = $changed -or $outcome.Changed
            if (-not $outcome.Deferred) {
                break
            }
            if ($pass -ge 16) {
                throw 'Unordered collections did not converge.'
            }
        }
        if (-not $changed) {
            return $null
        }

        foreach ($side in $sides) {
            [System.IO.File]::WriteAllText($side.Path, $side.Text, [System.Text.UTF8Encoding]::new($side.HasBom))
        }
        $merged = Invoke-GitMergeFile -OursPath $sides[1].Path -BasePath $sides[0].Path -TheirsPath $sides[2].Path -ResultPath (Join-Path $WorkDirectory 'structural.xml')
        if ($merged.Conflicts -lt 0 -or $merged.Conflicts -gt 127) {
            return $null
        }
        if ($merged.Conflicts -eq 0 -and -not (Test-WellFormedXml -Bytes $merged.Bytes)) {
            Write-Warning "Order-independent XML merge of '$displayPath' produced invalid XML; keeping the line-based result."
            return $null
        }
        return $merged
    }
    catch {
        Write-Warning "Order-independent XML merge skipped for '$displayPath': $($_.Exception.Message)"
        return $null
    }
}

# ─── Entry point ─────────────────────────────────────────────────────────────

$displayPath = if ($FilePath) { $FilePath } else { $Ours }
$Base = (Resolve-Path -LiteralPath $Base).ProviderPath
$Ours = (Resolve-Path -LiteralPath $Ours).ProviderPath
$Theirs = (Resolve-Path -LiteralPath $Theirs).ProviderPath

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('d365gitops-xmlmerge-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDirectory
$exitCode = 1
try {
    $result = Invoke-GitMergeFile -OursPath $Ours -BasePath $Base -TheirsPath $Theirs -ResultPath (Join-Path $workDirectory 'plain.xml')
    if ($result.Conflicts -lt 0 -or $result.Conflicts -gt 127) {
        Write-Warning "git merge-file failed for '$displayPath' (exit code $($result.Conflicts)); file left unmerged."
    }
    else {
        if ($result.Conflicts -gt 0) {
            $structural = Invoke-StructuralMerge -WorkDirectory $workDirectory
            if ($null -ne $structural -and $structural.Conflicts -le $result.Conflicts) {
                $result = $structural
                if ($result.Conflicts -eq 0) {
                    Write-Host "Merged order-independent XML elements: $displayPath"
                }
            }
        }
        [System.IO.File]::WriteAllBytes($Ours, $result.Bytes)
        $exitCode = [int]($result.Conflicts -gt 0)
        if ($exitCode -ne 0) {
            Write-Warning "Merge conflicts in '$displayPath' ($($result.Conflicts) conflict region(s))."
        }
    }
}
finally {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction Ignore
}

if ($MyInvocation.MyCommand.CommandType -eq [System.Management.Automation.CommandTypes]::ExternalScript) {
    exit $exitCode
}

return $exitCode
