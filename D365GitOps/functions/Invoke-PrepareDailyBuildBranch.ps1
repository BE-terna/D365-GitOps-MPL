function Invoke-PrepareDailyBuildBranch {
    [CmdletBinding()]
    param(
        [string]$OrganizationUri = $env:SYSTEM_COLLECTIONURI,
        [string]$Project = $env:SYSTEM_TEAMPROJECTID,
        [string]$RepositoryName = $env:BUILD_REPOSITORY_NAME,
        [string]$DailyBuildBranch = 'daily-build',
        [ValidateSet('merge', 'squash')]
        [string]$MergeStrategy = 'merge',
        [int]$DefaultPriority = 100,
        [string]$Pat = $env:DEVOPS_PAT,
        [switch]$SkipUnchangedPush
    )

    & "$PSScriptRoot/DailyBuild/Prepare-DailyBuildBranch.ps1" @PSBoundParameters
}
