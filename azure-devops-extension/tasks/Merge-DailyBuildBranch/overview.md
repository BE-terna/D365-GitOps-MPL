# Merge Daily Build Branch Task

Use this Azure DevOps custom task to create or update a `daily-build` branch by merging active pull requests targeting `main`.

This task uses same script as in PowerShell module 
[![PowerShell Gallery - D365GitOps](https://img.shields.io/badge/PowerShell%20Gallery-D365%20GitOps-blue.svg)](https://www.powershellgallery.com/packages/D365GitOps)
[![GitHub](https://img.shields.io/badge/GitHub-D365%20GitOps-blue?logo=GitHub)](https://github.com/BE-terna/D365-GitOps-MPL)

## How To Use In YAML Pipelines

1. Install this extension in your Azure DevOps organization.
2. Add the task to a YAML pipeline.
3. Ensure the pipeline has permission to read PRs and push to the target branch.

### YAML Example

```yaml
schedules:
  - cron: '0 3 * * *'
    displayName: 'Daily 3:00 build'
    branches:
      include:
        - main
    always: true

pool:
  vmImage: windows-latest

steps:
  - checkout: self
    persistCredentials: true

  - task: MergeDailyBuildBranch@1
    displayName: Merge active PRs into daily-build
    inputs:
      dailyBuildBranch: daily-build
      mergeStrategy: merge
      defaultPriority: '100'
      skipUnchangedPush: true
```

## Inputs

- `dailyBuildBranch`: Name of the branch to update (default: `daily-build`)
- `mergeStrategy`: `merge` or `squash` (default: `merge`)
- `defaultPriority`: Fallback priority if no `priority:x` label is present (default: `100`)
- `skipUnchangedPush`: Skip force-push when branch content is unchanged (default: `false`)
