<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

function Invoke-MergeLabelFile {
    [CmdletBinding(DefaultParameterSetName = 'Standalone')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
        [string]$Base,

        [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
        [string]$Ours,

        [Parameter(Mandatory, ParameterSetName = 'MergeDriver')]
        [string]$Theirs,

        [Parameter(ParameterSetName = 'MergeDriver')]
        [int]$MarkerSize = 7,

        [Parameter(ParameterSetName = 'MergeDriver')]
        [string]$FilePath = '',

        [Parameter(ParameterSetName = 'Standalone')]
        [string]$RepoRoot = (Get-Location).Path
    )

    & "$PSScriptRoot/MergeDriver/Merge-LabelFile.ps1" @PSBoundParameters
}
