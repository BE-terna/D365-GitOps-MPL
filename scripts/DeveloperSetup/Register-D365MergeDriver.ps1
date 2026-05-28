<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

<#
.SYNOPSIS
    Registers the d365fo-label git merge driver for the current repository (or globally).

.DESCRIPTION
    Configures the git merge driver that handles 3-way merges of AxLabel translation
    files.  After registration any file matched by the .gitattributes rule
        **/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label
    is automatically merged using Merge-LabelFile.ps1.

    The driver path is resolved from this script's own location so it works whether
    the module was installed from the PowerShell Gallery or cloned from source.

.PARAMETER Global
    When specified, the merge driver is registered in the user's global git config
    (~/.gitconfig) instead of the repository-local .git/config.

.EXAMPLE
    # Register locally for the current repository (run from within a git clone):
    pwsh -File scripts/DeveloperSetup/Register-D365MergeDriver.ps1

.EXAMPLE
    # Register globally for all repositories on this machine:
    pwsh -File scripts/DeveloperSetup/Register-D365MergeDriver.ps1 -Global

.EXAMPLE
    # Via the D365GitOps module:
    Import-Module D365GitOps
    Register-D365MergeDriver
#>

[CmdletBinding()]
param(
    [switch]$Global
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'MergeDriver/Merge-LabelFile.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Merge-LabelFile.ps1 not found at expected path: $scriptPath"
}

$driver = "pwsh -File `"$scriptPath`" -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"
$scope  = if ($Global) { '--global' } else { '--local' }

& git config $scope merge.d365fo-label.name   'AxLabel file merger'
& git config $scope merge.d365fo-label.driver $driver

Write-Host "Merge driver 'd365fo-label' registered ($( if ($Global) { 'global' } else { 'local' }))."
Write-Host "  Name:   AxLabel file merger"
Write-Host "  Driver: $driver"
Write-Host ''
Write-Host 'Ensure your repository contains a .gitattributes file with:'
Write-Host '  **/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label'
