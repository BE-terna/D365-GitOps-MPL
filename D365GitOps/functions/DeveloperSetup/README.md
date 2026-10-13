<!--
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
-->
# DeveloperSetup

Scripts for configuring a developer workstation to use D365GitOps tooling.

## Contents

| File | Description |
|------|-------------|
| `Register-D365LabelFileMergeDriver.ps1` | Defines the `Register-D365LabelFileMergeDriver` function that registers the `d365fo-label` git merge driver |
| `Register-D365XmlFileMergeDriver.ps1` | Defines the `Register-D365XmlFileMergeDriver` function that registers the `d365fo-xml` git merge driver |

## Usage

### Via the D365GitOps module (recommended)

```powershell
Install-PSResource D365GitOps
Import-Module D365GitOps

# Register for the current repository only
Register-D365LabelFileMergeDriver

# Register globally for all repositories on this machine
Register-D365LabelFileMergeDriver -Global
```

### Dot-source directly (no module install required)

```powershell
. ./D365GitOps/functions/DeveloperSetup/Register-D365LabelFileMergeDriver.ps1
Register-D365LabelFileMergeDriver
```

## What it does

Writes the following entries to git config (`--local` or `--global`):

```
merge.d365fo-label.name   = AxLabel file merger
merge.d365fo-label.driver = pwsh -File "<path>/Merge-D365LabelFile.ps1" -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P
```

The driver path is resolved to `Merge-D365LabelFile.ps1` relative to this file's
installed location, so it works identically whether installed from the PowerShell
Gallery or used directly from source.

## Prerequisites

- **Consumer repository** must contain a `.gitattributes` file with:

  ```gitattributes
  **/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label
  ```

- Run once per clone (local) or once per machine (global).

## XML merge driver (`d365fo-xml`)

```powershell
Import-Module D365GitOps

# Register for the current repository only
Register-D365XmlFileMergeDriver

# Register globally, optionally with a shared rules file
Register-D365XmlFileMergeDriver -Global -RulesPath C:/GitOps/.xmlmergerules
```

Writes `merge.d365fo-xml.name` and `merge.d365fo-xml.driver`
(`pwsh -NoProfile -File "<path>/Merge-D365XmlFile.ps1" -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P`).
The consumer repository assigns files to it in `.gitattributes`, e.g. `*.xml merge=d365fo-xml`.
See [MergeDrivers](../MergeDrivers/README.md) for the rules file.
