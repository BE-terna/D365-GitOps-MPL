<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

# Load function definitions from their dedicated source files.
. "$PSScriptRoot/DeveloperSetup/Register-D365MergeDriver.ps1"

<#
.SYNOPSIS
    Builds and updates a daily-build branch by merging active pull requests to main.

.DESCRIPTION
    Delegates to DailyBuild/Prepare-DailyBuildBranch.ps1 with the same parameters.
    See that script for full documentation.

.PARAMETER OrganizationUri
    Azure DevOps organization URL. Defaults to $env:SYSTEM_COLLECTIONURI.

.PARAMETER Project
    Azure DevOps project name or ID. Defaults to $env:SYSTEM_TEAMPROJECTID.

.PARAMETER RepositoryName
    Repository to process. Defaults to $env:BUILD_REPOSITORY_NAME.

.PARAMETER DailyBuildBranch
    Target branch name that receives merged pull requests. Default: 'daily-build'.

.PARAMETER MergeStrategy
    'merge' (default) or 'squash'.

.PARAMETER DefaultPriority
    Fallback priority when no priority:x label exists. Default: 100.

.PARAMETER Pat
    Azure DevOps personal access token. Defaults to $env:DEVOPS_PAT.

.PARAMETER SkipUnchangedPush
    Skip force-push if the target branch content is unchanged.

.EXAMPLE
    Invoke-PrepareDailyBuildBranch -OrganizationUri https://dev.azure.com/my-org -Project my-project -RepositoryName my-repo

.EXAMPLE
    Import-Module D365GitOps
    Invoke-PrepareDailyBuildBranch -MergeStrategy squash -SkipUnchangedPush
#>
function Invoke-PrepareDailyBuildBranch {
    [CmdletBinding()]
    param(
        [string]$OrganizationUri  = $env:SYSTEM_COLLECTIONURI,
        [string]$Project          = $env:SYSTEM_TEAMPROJECTID,
        [string]$RepositoryName   = $env:BUILD_REPOSITORY_NAME,
        [string]$DailyBuildBranch = 'daily-build',
        [ValidateSet('merge', 'squash')]
        [string]$MergeStrategy    = 'merge',
        [int]$DefaultPriority     = 100,
        [string]$Pat              = $env:DEVOPS_PAT,
        [switch]$SkipUnchangedPush
    )

    & "$PSScriptRoot/DailyBuild/Prepare-DailyBuildBranch.ps1" @PSBoundParameters
}

Export-ModuleMember -Function Register-D365MergeDriver, Invoke-PrepareDailyBuildBranch
