# D365GitOps PowerShell Module

GitOps utilities for Dynamics 365 Finance and Operations.

## Operations

| Script | Description |
|--------|-------------|
| `MergeDriver/Merge-LabelFile.ps1` | Git merge driver and standalone sorter for AxLabel translation files |
| `DeveloperSetup/Register-D365MergeDriver.ps1` | Registers the `d365fo-label` git merge driver in the local or global git config |
| `DailyBuild/Prepare-DailyBuildBranch.ps1` | Builds and updates a daily-build branch by merging active pull requests to main |

## Installation

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/D365GitOps):

```powershell
Install-PSResource D365GitOps
```

## Usage

### Merge driver (AxLabel files)

The merge driver performs a 3-way merge of AxLabel translation files, producing an alphabetically sorted result with conflict markers for unresolvable conflicts.

**Step 1 — Add a `.gitattributes` rule to your D365 FO repository:**

```gitattributes
# Assign the custom merge driver to AxLabel translation files.
# The driver must be registered in git config before use; see Register-D365MergeDriver.
**/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label
```

**Step 2 — Register the driver once per clone:**

```powershell
Import-Module D365GitOps
Register-D365MergeDriver          # registers in local .git/config
Register-D365MergeDriver -Global  # registers in ~/.gitconfig
```

Or run the standalone script directly:

```powershell
pwsh -File D365GitOps/functions/DeveloperSetup/Register-D365MergeDriver.ps1
```

**Standalone / pipeline mode** (sort all label files without merging):

```powershell
pwsh -File D365GitOps/functions/MergeDriver/Merge-LabelFile.ps1 -RepoRoot $(Build.SourcesDirectory)
```

### Daily build branch

Merges all active (non-draft, non-ignored) pull requests targeting `main` into a consolidated branch:

```powershell
pwsh -File D365GitOps/functions/DailyBuild/Prepare-DailyBuildBranch.ps1 `
  -OrganizationUri https://dev.azure.com/my-org `
  -Project my-project `
  -RepositoryName my-repo
```

Or use the **Prepare Daily Build Branch** task from the [Azure DevOps Marketplace extension](https://marketplace.visualstudio.com/items?itemName=BE-terna.d365-gitops).

## License

[Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/)
