<!--
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
-->
# MergeDriver

Git merge driver and standalone sorter for AxLabel translation files (`*.label.txt`).

## Contents

| File | Description |
|------|-------------|
| `Merge-LabelFile.ps1` | 3-way merge driver with alphabetical sorting and conflict-marker output |

## Modes

### Merge-driver mode (automatic via git)

git invokes this script automatically during a merge when the file matches the
`.gitattributes` rule in the target repository:

```gitattributes
**/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label
```

The driver must be registered first — use `Register-D365MergeDriver` from the
[DeveloperSetup](../DeveloperSetup) folder.

### Standalone / pipeline mode

Scans for all `*.label.txt` files under `**/AxLabelFile/LabelResources/` and
sorts them alphabetically in-place.  Useful as a pipeline step to normalise files
before committing:

```powershell
pwsh -File D365GitOps/functions/MergeDriver/Merge-LabelFile.ps1 -RepoRoot $env:BUILD_SOURCESDIRECTORY
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
