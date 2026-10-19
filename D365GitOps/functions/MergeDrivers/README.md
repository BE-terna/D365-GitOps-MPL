<!--
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
-->
# MergeDrivers

Git merge drivers for D365 Finance & Operations artifacts.

## Contents

| File | Description |
|------|-------------|
| `Merge-D365LabelFile.ps1` | 3-way merge driver with alphabetical sorting and conflict-marker output for AxLabel translation files (`*.label.txt`) |
| `Merge-D365XmlFile.ps1` | 3-way merge driver for XML files whose repeated sibling elements are order-independent (D365FO metadata, but not limited to it) |
| `D365FO.xmlmergerules` | Default rules for `Merge-D365XmlFile.ps1` (D365FO tables, classes, forms, security, descriptors, projects) |
| `Sample-Base*.xml` | Sample privilege versions (base, two changes, expected results) used by the tests |
| `Merge-D365MetadataXml.ps1` | 3-way merge driver for D365FO metadata XML (AxTable, AxSecurityPrivilege, AxMenuExtension, AxFormExtension, ...) that auto-resolves conflicts caused purely by sibling order |
| `Default-UnorderedElements.rules` | Default list of XPaths whose sibling order does not matter, used by `Merge-D365MetadataXml.ps1` |

## AxLabel merge driver

### Modes

### Merge-driver mode (automatic via git)

git invokes this script automatically during a merge when the file matches the
`.gitattributes` rule in the target repository:

```gitattributes
**/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label
```

The driver must be registered first — use `Register-D365LabelFileMergeDriver` from the
[DeveloperSetup](../DeveloperSetup) folder.

### Standalone / pipeline mode

Scans for all `*.label.txt` files under `**/AxLabelFile/LabelResources/` and
sorts them alphabetically in-place.  Useful as a pipeline step to normalise files
before committing:

```powershell
pwsh -File D365GitOps/functions/MergeDrivers/Merge-D365LabelFile.ps1 -RepoRoot $env:BUILD_SOURCESDIRECTORY
```

## Label file format

```
LabelId=value
 ;optional comment line (must start with " ;", belongs to the line above)
```

## Notes

- Conflict markers follow standard git format; the file is left unmerged (exit 1)
  so git marks it for manual resolution.

## XML merge driver (order-independent elements)

D365FO stores metadata as XML. Element order usually matters (e.g. fields of an index),
but many collections are order-independent (fields of a table, entry points of a
privilege, methods of a class). When two branches add different elements to the same
collection, git's line-based merge reports a conflict although both changes can be kept.

`Merge-D365XmlFile.ps1` resolves such conflicts:

1. git's regular line-based merge (`git merge-file`) runs first; a clean result is kept as is.
2. On conflicts, elements selected by the rules are merged as a set: additions from both
   sides are kept (ours first, then theirs), deletions and one-sided changes are applied.
   An element changed on both sides stays with the line-based merge, so overlapping edits
   are still reported. Only the affected collections are rewritten; formatting, attribute
   layout, CDATA, line endings and BOM of everything else stay byte-for-byte.
3. Remaining conflicts get standard conflict markers (exit 1).

It is pure PowerShell 7 + git, so it runs the same on developer machines and on any
Windows or Linux build agent.

### Setup

```gitattributes
# .gitattributes
*.xml     merge=d365fo-xml
*.rnrproj merge=d365fo-xml
```

Register the driver with `Register-D365XmlFileMergeDriver` (see [DeveloperSetup](../DeveloperSetup)).
`Merge-DailyBuildBranch` registers it automatically before merging pull requests.

### Rules

One rule per line, `#` starts a comment line:

```text
<xpath> [key=<xpath>]
```

- `<xpath>` (XPath 1.0) selects the order-independent elements. Element names are matched by
  local name, so namespaced files need no prefixes.
- `key=` (optional) is evaluated on each selected element; its string value identifies the
  element in base/ours/theirs (case-insensitive). Then the same key added on both sides with
  different content, or deleted on one side and changed on the other, is a conflict.
- Without `key=` the whole element is the identity (immutable values, e.g. module references).

```text
/AxTable/Fields/AxTableField key=Name
/AxSecurityPrivilege/EntryPoints/AxSecurityEntryPointReference key=Name
/AxModelInfo/ModuleReferences/string
/Project/ItemGroup/Content key=@Include
```

The rules file is looked up in this order (first match wins):

1. `-RulesPath` parameter (e.g. baked into the git driver command)
2. `$env:D365GITOPS_XML_MERGE_RULES` (e.g. in a pipeline)
3. `<repository root>/.xmlmergerules` (committed with the code)
4. [`D365FO.xmlmergerules`](D365FO.xmlmergerules) shipped with the module

Create a customizable copy of the defaults:

```powershell
Merge-D365XmlFile -ExportDefaultRules ./.xmlmergerules
```

### Tests

```powershell
Invoke-Pester ./test/Merge-D365XmlFile.Tests.ps1   # Pester 5
```

This rule-based, general-purpose XML driver is registered with
`Register-D365XmlFileMergeDriver`.

## D365FO metadata XML merge driver

Registered as `d365fo-xml` — see [Register-D365MetadataXmlMergeDriver](../DeveloperSetup/Register-D365MetadataXmlMergeDriver.ps1).

This is an alternative implementation to `Merge-D365XmlFile.ps1`; both
registration functions write to the same `d365fo-xml` Git setting, so choose
one implementation when configuring a repository or machine.

### Why

D365FO metadata XML files sometimes contain lists where sibling order is
meaningless (e.g. table fields, security entry points) or only meaningful
relative to a `<Parent>` grouping (e.g. menu/form extension elements). git's
default 3-way merge is line-based and does not know this, so two branches
adding different, unrelated siblings next to each other raise a false
conflict.

### How it works

1. Locates "unordered" container elements, either:
   - listed by absolute XPath in a rules file (one path per line, `#` comments
     allowed), pointing at the repeated element, e.g.
     `/AxTable/Fields/AxTableField`; or
   - auto-detected: any set of 2+ same-named siblings that each have a direct
     `<Parent>` child (always enabled, no configuration needed) — order only
     matters between siblings that share the same `<Parent>` value.
2. For each such container that differs between Ours and Theirs, merges the
   children by identity (their own `<Name>`, plus `<Parent>` when present):
   additions/deletions from either side are combined automatically; a real
   conflict is only raised when both sides changed the *same* item to
   different content.
3. Everything else in the file is merged with `git merge-file`, so unrelated
   changes and formatting elsewhere are handled exactly as git would normally
   do, and are left byte-for-byte untouched.

Default rules ship in `Default-UnorderedElements.rules`. Pass `-RulesPath` (or
set `D365FO_XMLMERGE_RULES`) to point at a repository-specific rules file with
additional XPaths.

### Prerequisites

- **Consumer repository** must contain a `.gitattributes` file with rules such as:

  ```gitattributes
  **/AxTable/*.xml               merge=d365fo-xml
  **/AxSecurityPrivilege/*.xml   merge=d365fo-xml
  **/AxMenuExtension/*.xml       merge=d365fo-xml
  **/AxFormExtension/*.xml       merge=d365fo-xml
  ```

- Register the driver first — use `Register-D365MetadataXmlMergeDriver` from the
  [DeveloperSetup](../DeveloperSetup) folder. This must be done by every developer
  clone and by CI/CD automation (e.g. when merging all open pull requests), since
  the merge driver is a local git config setting, not something committed to the repo.
