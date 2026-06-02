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

Before publishing, configure the environment variables used by the publish workflow (`MARKETPLACE_PUBLISHER_ID` and `MARKETPLACE_EXTENSION_ID`).
`D365GitOps/functions/DailyBuild/Prepare-DailyBuildBranch.ps1` is the source of truth; the publish workflow copies it into the extension task folder during packaging.
The task GUID in `azure-devops-extension/tasks/PrepareDailyBuildBranch/task.json` must remain unique if this task is forked or republished under another extension.

## Azure DevOps pipeline example

A prettified pipeline with parameterized usage is available at:

- `.azuredevops/MergeDailyBuildBranch.yml`

## GitHub Actions for release + publish

- `.github/workflows/create-release.yml`
  - Creates a GitHub release automatically when a semver tag (`vX.Y.Z`) is pushed.
- `.github/workflows/publish-marketplace.yml`
  - Supports manual publish (`workflow_dispatch` with explicit semver input).
  - Supports manual environment selection (`marketplace` or `marketplace-preview`).
  - Downloads `vss-extension.schema.json` next to the manifest and validates `azure-devops-extension/vss-extension.json` before packaging.
  - Publishes automatically when a GitHub release is published.

## OIDC setup for Azure DevOps Marketplace publishing

1. Create (or reuse) an Entra ID application/service principal.
2. In GitHub repository **Settings → Environments** configure:
   - `marketplace` (default publish target)
   - `marketplace-preview`
3. Add the following environment variables in each environment:
   - `MARKETPLACE_PUBLISHER_ID`
   - `MARKETPLACE_EXTENSION_ID`
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
4. In Entra ID app, add a **Federated credential**:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject for branch-based runs (example): `repo:BE-terna/D365-GitOps-MPL:ref:refs/heads/main`
   - Subject for release-based runs (recommended): `repo:BE-terna/D365-GitOps-MPL:environment:marketplace` (if environments are used)
   - If preview publishes use a separate federated credential, add: `repo:BE-terna/D365-GitOps-MPL:environment:marketplace-preview`
5. Grant the app permissions/access required to publish under your Azure DevOps Marketplace publisher.
6. Push a semver tag (`v1.2.3`) to auto-create a release, or manually create a GitHub release.
7. Publishing workflow logs in with OIDC (`azure/login`) and requests an Azure DevOps access token for resource id `499b84ac-1321-427f-aa17-267ca6975798`.
