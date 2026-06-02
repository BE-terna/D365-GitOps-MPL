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
