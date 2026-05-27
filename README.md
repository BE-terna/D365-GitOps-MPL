<!--
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
-->
# D365-GitOps-MPL

## Azure DevOps Marketplace extension

This repository now contains an Azure DevOps extension scaffold for `Prepare-DailyBuildBranch.ps1` under:

- `azure-devops-extension/vss-extension.json`
- `azure-devops-extension/tasks/PrepareDailyBuildBranch/task.json`
- `azure-devops-extension/tasks/PrepareDailyBuildBranch/Prepare-DailyBuildBranch.ps1`

Before publishing, set `publisher` in `azure-devops-extension/vss-extension.json` to your real Marketplace publisher id (or provide it through workflow input).

## Azure DevOps pipeline example

A prettified pipeline with parameterized usage is available at:

- `.azuredevops/MergeDailyBuildBranch.yml`

## GitHub Actions for release + publish

- `.github/workflows/create-release.yml`
  - Creates a GitHub release automatically when a semver tag (`vX.Y.Z`) is pushed.
- `.github/workflows/publish-marketplace.yml`
  - Supports manual publish (`workflow_dispatch` with explicit semver input).
  - Publishes automatically when a GitHub release is published.

## OIDC setup for Azure DevOps Marketplace publishing

1. Create (or reuse) an Entra ID application/service principal.
2. In GitHub repository **Settings → Secrets and variables → Actions → Variables**, add:
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
3. In Entra ID app, add a **Federated credential**:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject for branch-based runs (example): `repo:BE-terna/D365-GitOps-MPL:ref:refs/heads/main`
   - Subject for release-based runs (recommended): `repo:BE-terna/D365-GitOps-MPL:environment:production` (if environments are used)
4. Grant the app permissions/access required to publish under your Azure DevOps Marketplace publisher.
5. Push a semver tag (`v1.2.3`) to auto-create a release, or manually create a GitHub release.
6. Publishing workflow logs in with OIDC (`azure/login`) and requests an Azure DevOps access token for resource id `499b84ac-1321-427f-aa17-267ca6975798`.
