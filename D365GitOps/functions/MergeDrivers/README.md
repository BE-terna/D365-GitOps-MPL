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
| `Merge-D365MetadataXml.ps1` | 3-way merge driver that resolves safe changes to configured unordered D365FO XML sibling collections |
| `Default-UnorderedElements.rules` | Distributed XPath rules for metadata collections whose sibling order does not matter |

## D365FO metadata XML merge driver

Register the driver for the current clone with
`Register-D365MetadataXmlMergeDriver`. Then add matching metadata types to
`.gitattributes`, for example:

```gitattributes
**/AxTable/*.xml merge=d365fo-xml
**/AxSecurityPrivilege/*.xml merge=d365fo-xml
```

The bundled rules cover table fields, table indexes, and security privilege
entry-point references. Rules are absolute XPath expressions, one per line,
selecting unordered sibling elements. Blank lines and lines beginning with `#`
are ignored. A custom rules file can be provided when registering the driver:

```powershell
Register-D365MetadataXmlMergeDriver -RulesPath ./config/UnorderedElements.rules
```

Each configured collection is merged as a set of complete element subtrees.
Siblings should have unique direct-child `<Name>` values. Additions, deletions,
and one-sided edits are merged; conflicting changes to the same item are left
for Git to report. Collections that are ambiguous, contain non-item child
elements, or cannot be safely matched are not normalized and are handled by
Git's normal XML text merge. XML formatting outside successfully merged
collections is preserved.

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
