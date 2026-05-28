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
    is automatically merged using Merge-LabelFile.ps1 from this module.

.PARAMETER Global
    When specified, the merge driver is registered in the user's global git config
    (~/.gitconfig) instead of the repository-local .git/config.

.EXAMPLE
    Register-D365MergeDriver

.EXAMPLE
    Register-D365MergeDriver -Global
#>
function Register-D365MergeDriver {
    [CmdletBinding()]
    param(
        [switch]$Global
    )

    $scriptPath = Join-Path $PSScriptRoot 'MergeDriver/Merge-LabelFile.ps1'

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
}

Export-ModuleMember -Function Register-D365MergeDriver
