<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

<#
.SYNOPSIS
    Registers the d365fo-xml git merge driver for the current repository (or globally).

.DESCRIPTION
    Configures the git merge driver that merges XML files whose repeated sibling elements are
    order-independent (Merge-D365XmlFile). After registration, every file assigned to the driver
    in .gitattributes, for example
        *.xml merge=d365fo-xml
    is merged by Merge-D365XmlFile.

    The driver path is resolved relative to this file's location so it works whether
    the module is installed from the PowerShell Gallery or used directly from source.

    This file is an advanced script. When importing the D365GitOps module, it is exposed as
    Register-D365XmlFileMergeDriver.

.EXAMPLE
    # Via the D365GitOps module (recommended):
    Import-Module D365GitOps
    Register-D365XmlFileMergeDriver

.EXAMPLE
    # Register for all repositories on this machine with a shared rules file:
    Register-D365XmlFileMergeDriver -Global -RulesPath C:/GitOps/.xmlmergerules
#>
[CmdletBinding(DefaultParameterSetName = 'CustomCommand')]
param(
    # Registers the driver in the global git config (~/.gitconfig) instead of the repository-local .git/config.
    [Parameter()]
    [switch]
    $Global
    ,
    # Command invoked by the driver when it is available in the current session (D365GitOps module).
    [Parameter(ParameterSetName = 'CustomCommand', Position = 0)]
    [string]
    $MergeXmlCommandName = 'Merge-D365XmlFile'
    ,
    # Merge script used when the command is not available; absolute or relative to this file.
    [Parameter(ParameterSetName = 'CustomScriptPath')]
    [string]
    $MergeXmlScriptPath = '../MergeDrivers/Merge-D365XmlFile.ps1'
    ,
    # Rules file passed to every merge; overrides $env:D365GITOPS_XML_MERGE_RULES and <repository root>/.xmlmergerules.
    # A relative path is resolved against the repository root at merge time.
    [Parameter()]
    [string]
    $RulesPath
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$driverArguments = '-Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P'
if ($RulesPath) {
    $driverArguments += " -RulesPath '$($RulesPath.Replace('\', '/'))'"
}

$mergeXmlCommand = if ($PSCmdlet.ParameterSetName -eq 'CustomCommand') {
    Get-Command $MergeXmlCommandName -ErrorAction Ignore
}
if ($mergeXmlCommand) {
    # Quoted as a whole so git's quoted %P (paths with spaces) reaches PowerShell as one string.
    $driver = "pwsh -NoProfile -Command `"$($mergeXmlCommand.Name) $driverArguments`""
}
else {
    if ([System.IO.Path]::IsPathRooted($MergeXmlScriptPath)) {
        $resolvedScriptPath = $MergeXmlScriptPath
    }
    else {
        $resolvedScriptPath = Join-Path $PSScriptRoot $MergeXmlScriptPath
    }
    if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
        throw "Merge-D365XmlFile.ps1 not found at expected path: $resolvedScriptPath"
    }
    # git runs the driver through sh; forward slashes avoid backslash escaping on Windows.
    $resolvedScriptPath = (Resolve-Path -LiteralPath $resolvedScriptPath).ProviderPath.Replace('\', '/')
    $driver = "pwsh -NoProfile -File `"$resolvedScriptPath`" $driverArguments"
}
Write-Verbose "Resolved merge driver command: $driver"
$scope = if ($Global) { '--global' } else { '--local' }

& git config $scope merge.d365fo-xml.name 'XML merger for order-independent elements'
if ($LASTEXITCODE -ne 0) {
    throw "git config $scope failed with exit code $LASTEXITCODE."
}
& git config $scope merge.d365fo-xml.driver $driver
if ($LASTEXITCODE -ne 0) {
    throw "git config $scope failed with exit code $LASTEXITCODE."
}

Write-Information "Merge driver 'd365fo-xml' registered ($( if ($Global) { 'global' } else { 'local' }))."
Write-Information '  Name:   XML merger for order-independent elements'
Write-Information "  Driver: $driver"
Write-Information ''
Write-Information 'Ensure your repository contains a .gitattributes file with, for example:'
Write-Information '  *.xml merge=d365fo-xml'
Write-Information 'Optionally commit custom rules as .xmlmergerules (Merge-D365XmlFile -ExportDefaultRules ./.xmlmergerules).'
