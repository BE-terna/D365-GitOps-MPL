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

- Output is always UTF-8 without BOM with LF line endings.
- Conflict markers follow standard git format; the file is left unmerged (exit 1)
  so git marks it for manual resolution.

## D365FO metadata XML merge driver

Registered as `d365fo-xml` — see [Register-D365MetadataXmlMergeDriver](../DeveloperSetup/Register-D365MetadataXmlMergeDriver.ps1).

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

