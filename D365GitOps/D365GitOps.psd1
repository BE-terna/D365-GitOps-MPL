<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

@{

RootModule = 'D365GitOps.psm1'

ModuleVersion = '0.1.0'

GUID = 'cd877dd5-6526-48fa-b013-8d6e217b587d'

Author = 'BE-terna'

CompanyName = 'BE-terna'

Copyright = 'This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.'

Description = 'GitOps utilities for Dynamics 365 Finance and Operations: AxLabel merge driver and daily-build branch automation.'

PowerShellVersion = '7.0'

FunctionsToExport = @(
    'Register-D365MergeDriver',
    'Invoke-PrepareDailyBuildBranch',
    'Invoke-MergeLabelFile'
)

CmdletsToExport = @()

VariablesToExport = @()

AliasesToExport = @()

FileList = @(
    'D365GitOps.psm1',
    'functions/Invoke-MergeLabelFile.ps1',
    'functions/Invoke-PrepareDailyBuildBranch.ps1',
    'functions/DeveloperSetup/Register-D365MergeDriver.ps1',
    'functions/MergeDriver/Merge-LabelFile.ps1',
    'functions/DailyBuild/Prepare-DailyBuildBranch.ps1'
)

PrivateData = @{

    PSData = @{

        Tags = 'D365', 'D365FO', 'GitOps', 'git', 'merge-driver', 'AxLabel', 'AzureDevOps'

        LicenseUri = 'https://mozilla.org/MPL/2.0/'

        ProjectUri = 'https://github.com/BE-terna/D365-GitOps-MPL'

    }

}

}
