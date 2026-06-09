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
    is automatically merged using Merge-D365LabelFile.ps1.

    The driver path is resolved relative to this file's location so it works whether
    the module is installed from the PowerShell Gallery or used directly from source.

    This file is an advanced script. When importing the D365GitOps module, it is exposed as
    Register-D365LabelFileMergeDriver.

.PARAMETER Global
    When specified, the merge driver is registered in the user's global git config
    (~/.gitconfig) instead of the repository-local .git/config.

.EXAMPLE
    # Via the D365GitOps module (recommended):
    Import-Module D365GitOps
    Register-D365LabelFileMergeDriver
#>
[CmdletBinding(DefaultParameterSetName = "CustomCommand")]
param(
    [switch]$Global
    ,
    [parameter(ParameterSetName = "CustomCommand", Position = 0)]
    [string]$MergeLabelCommandName = 'Merge-D365LabelFile'
    ,
    [parameter(ParameterSetName = "CustomScriptPath")]
    [string]$MergeLabelScriptPath = '../MergeDrivers/Merge-D365LabelFile.ps1'

)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$mergeLabelCommand = Get-Command $MergeLabelCommandName -ErrorAction Ignore
if ($mergeLabelCommand) {
    $mergeLabelScript = "-Command $($mergeLabelCommand.Name)"
}
else {
    if ([System.IO.Path]::IsPathRooted($MergeLabelScriptPath)) {
        $resolvedScriptPath = $MergeLabelScriptPath
    }
    else {
        $resolvedScriptPath = Join-Path $PSScriptRoot $MergeLabelScriptPath
    }
    if (-not (Test-Path -LiteralPath $resolvedScriptPath)) {
        throw "Merge-D365LabelFile.ps1 not found at expected path: $resolvedScriptPath"
    }
    $mergeLabelScript = "-File `"$resolvedScriptPath`""
}

$driver = "pwsh $mergeLabelScript -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"
Write-Verbose "Resolved merge driver command: $driver"
$scope = if ($Global) { '--global' } else { '--local' }

& git config $scope merge.d365fo-label.name   'AxLabel file merger'
& git config $scope merge.d365fo-label.driver $driver

Write-Information "Merge driver 'd365fo-label' registered ($( if ($Global) { 'global' } else { 'local' }))."
Write-Information "  Name:   AxLabel file merger"
Write-Information "  Driver: $driver"
Write-Information ''
Write-Information 'Ensure your repository contains a .gitattributes file with:'
Write-Information '  **/AxLabelFile/LabelResources/*/*.label.txt merge=d365fo-label'
