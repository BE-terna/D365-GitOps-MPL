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

    The driver path is resolved relative to this file's location so it works whether
    the module is installed from the PowerShell Gallery or used directly from source.

    This file is a function-definition source.  It is dot-sourced by D365GitOps.psm1
    and can also be dot-sourced directly:

        . ./scripts/DeveloperSetup/Register-D365MergeDriver.ps1
        Register-D365MergeDriver

.PARAMETER Global
    When specified, the merge driver is registered in the user's global git config
    (~/.gitconfig) instead of the repository-local .git/config.

.EXAMPLE
    # Via the D365GitOps module (recommended):
    Import-Module D365GitOps
    Register-D365MergeDriver

.EXAMPLE
    # Dot-source and call directly:
    . ./scripts/DeveloperSetup/Register-D365MergeDriver.ps1
    Register-D365MergeDriver -Global
#>
function Register-D365MergeDriver {
    [CmdletBinding()]
    param(
        [switch]$Global
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $mergeLabelScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'MergeDriver/Merge-LabelFile.ps1'

    if (-not (Test-Path -LiteralPath $mergeLabelScript)) {
        throw "Merge-LabelFile.ps1 not found at expected path: $mergeLabelScript"
    }

    $driver = "pwsh -File `"$mergeLabelScript`" -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"
    $scope  = if ($Global) { '--global' } else { '--local' }

    & git config $scope merge.d365fo-label.name   'AxLabel file merger'
    & git config $scope merge.d365fo-label.driver $driver

    Write-Host "Merge driver 'd365fo-label' registered ($( if ($Global) { 'global' } else { 'local' }))."
    Write-Host "  Name:   AxLabel file merger"
    Write-Host "  Driver: $driver"
    Write-Host ''
    Write-Host 'Ensure your repository contains a .gitattributes file with:'
    Write-Host '  **/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label'
}
