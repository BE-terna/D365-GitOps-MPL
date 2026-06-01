# DailyBuild

Script that builds and maintains a consolidated daily-build branch by merging
all active, non-draft pull requests targeting `main`.

## Contents

| File | Description |
|------|-------------|
| `Prepare-DailyBuildBranch.ps1` | Fetches active PRs, sorts them by priority label, merges each into the daily-build branch and reports status back to Azure DevOps |

## Usage

### Via the D365GitOps module

```powershell
Import-Module D365GitOps
Invoke-PrepareDailyBuildBranch `
    -OrganizationUri https://dev.azure.com/my-org `
    -Project         my-project `
    -RepositoryName  my-repo
```

### Run the script directly

```powershell
pwsh -File scripts/DailyBuild/Prepare-DailyBuildBranch.ps1 `
    -OrganizationUri https://dev.azure.com/my-org `
    -Project         my-project `
    -RepositoryName  my-repo
```

### Azure DevOps pipeline task

Use the **Prepare Daily Build Branch** task from the
[D365 GitOps marketplace extension](https://marketplace.visualstudio.com/items?itemName=BE-terna.d365-gitops).
The extension embeds this script directly, so no separate module installation is required in a pipeline.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OrganizationUri` | `$env:SYSTEM_COLLECTIONURI` | Azure DevOps organization URL |
| `Project` | `$env:SYSTEM_TEAMPROJECTID` | Project name or ID |
| `RepositoryName` | `$env:BUILD_REPOSITORY_NAME` | Repository to process |
| `DailyBuildBranch` | `daily-build` | Target branch that receives merged PRs |
| `MergeStrategy` | `merge` | `merge` or `squash` |
| `DefaultPriority` | `100` | Fallback priority when no `priority:x` label exists |
| `Pat` | `$env:DEVOPS_PAT` | Azure DevOps personal access token |
| `SkipUnchangedPush` | `$false` | Skip force-push when branch content is unchanged |

## PR selection and ordering

- Only active, non-draft PRs targeting `main` are included.
- PRs labelled `AutoMergeIgnore` are skipped.
- PRs are ordered by `priority:<n>` label (lower number = higher priority), then by PR ID.
- If a PR's source branch has new commits since its last iteration, it is skipped to
  avoid merging an untested state.

## Status reporting

After the run, each PR receives an Azure DevOps status:
- `succeeded` — merged into the daily-build branch
- `failed` — skipped due to merge conflict or stale iteration
