<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

<#
.SYNOPSIS
    Registers the d365fo-xml git merge driver for the current repository (or globally).

.DESCRIPTION
    Configures the git merge driver that handles 3-way merges of D365FO metadata
    XML files, auto-resolving conflicts caused purely by sibling-order differences
    (e.g. two branches adding different table fields, security entry points, or
    menu/form extension elements). After registration any file matched by a
    .gitattributes rule such as
        **/AxTable/*.xml               merge=d365fo-xml
        **/AxSecurityPrivilege/*.xml   merge=d365fo-xml
        **/AxMenuExtension/*.xml       merge=d365fo-xml
        **/AxFormExtension/*.xml       merge=d365fo-xml
    is automatically merged using Merge-D365MetadataXml.ps1.

    The driver path is resolved relative to this file's location so it works whether
    the module is installed from the PowerShell Gallery or used directly from source.

    This file is an advanced script. When importing the D365GitOps module, it is exposed as
    Register-D365MetadataXmlMergeDriver.

.PARAMETER Global
    When specified, the merge driver is registered in the user's global git config
    (~/.gitconfig) instead of the repository-local .git/config.

.PARAMETER RulesPath
    Optional path to a repository-specific rules file (absolute XPaths, one per
    line) baked into the registered driver command. Defaults to the bundled
    Default-UnorderedElements.rules file.

.EXAMPLE
    # Via the D365GitOps module (recommended):
    Import-Module D365GitOps
    Register-D365MetadataXmlMergeDriver
#>
[CmdletBinding(DefaultParameterSetName = "CustomCommand")]
param(
    [switch]$Global
    ,
    [parameter(ParameterSetName = "CustomCommand", Position = 0)]
    [string]$MergeXmlCommandName = 'Merge-D365MetadataXml'
    ,
    [parameter(ParameterSetName = "CustomScriptPath")]
    [string]$MergeXmlScriptPath = '../MergeDrivers/Merge-D365MetadataXml.ps1'
    ,
    [string]$RulesPath
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$mergeXmlCommand = Get-Command $MergeXmlCommandName -ErrorAction Ignore
if ($mergeXmlCommand) {
    $mergeXmlScript = "-Command $($mergeXmlCommand.Name)"
}
else {
    if ([System.IO.Path]::IsPathRooted($MergeXmlScriptPath)) {
        $resolvedScriptPath = $MergeXmlScriptPath
    }
    else {
        $resolvedScriptPath = Join-Path $PSScriptRoot $MergeXmlScriptPath
    }
    if (-not (Test-Path -LiteralPath $resolvedScriptPath)) {
        throw "Merge-D365MetadataXml.ps1 not found at expected path: $resolvedScriptPath"
    }
    $mergeXmlScript = "-File `"$resolvedScriptPath`""
}

$driver = "pwsh $mergeXmlScript -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P"
if ($RulesPath) {
    $driver += " -RulesPath `"$RulesPath`""
}
Write-Verbose "Resolved merge driver command: $driver"
$scope = if ($Global) { '--global' } else { '--local' }

& git config $scope merge.d365fo-xml.name   'D365FO metadata XML merger'
& git config $scope merge.d365fo-xml.driver $driver

Write-Information "Merge driver 'd365fo-xml' registered ($( if ($Global) { 'global' } else { 'local' }))."
Write-Information "  Name:   D365FO metadata XML merger"
Write-Information "  Driver: $driver"
Write-Information ''
Write-Information 'Ensure your repository contains a .gitattributes file with rules such as:'
Write-Information '  **/AxTable/*.xml               merge=d365fo-xml'
Write-Information '  **/AxSecurityPrivilege/*.xml   merge=d365fo-xml'
Write-Information '  **/AxMenuExtension/*.xml       merge=d365fo-xml'
Write-Information '  **/AxFormExtension/*.xml       merge=d365fo-xml'
