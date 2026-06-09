<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

Set-StrictMode -Off
$script:ModuleRoot = $PSScriptRoot
$script:CreateFunctionsFromAdvancedScripts = $true

$beVerbose = $MyInvocation.Statement -match "-Verbose" -or $VerbosePreference -eq "Continue"

function Import-ModuleFile {
    [CmdletBinding()]
    Param (
        [string]
        $Path
    )

    if ($script:dontDotSource) {
        $ExecutionContext.InvokeCommand.InvokeScript(
            $false,
            ([scriptblock]::Create([io.file]::ReadAllText((Resolve-Path $Path).ProviderPath))),
            $null,
            $null
        )
    }
    else {
        if ($script:CreateFunctionsFromAdvancedScripts) {
            $s = Get-Command -Name $Path -CommandType ExternalScript -ErrorAction Ignore
            if ($s -and $s.Parameters.Count -gt 0) {
                $functionName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                Write-Verbose " - Creating function $functionName from $Path"
                New-Item -Path Function:\$functionName -Value $s.ScriptBlock -Force
                return
            }
        }
        . (Resolve-Path $Path).ProviderPath
    }
}

$preImportScriptPath = Join-Path $ModuleRoot "internal/scripts/preimport.ps1"
if (Test-Path $preImportScriptPath) {
    . Import-ModuleFile -Path $preImportScriptPath
}

foreach ($function in (Get-ChildItem "$ModuleRoot/internal/functions" -Recurse -File -Filter "*.ps1")) {
    . Import-ModuleFile -Path $function.FullName -Verbose:$beVerbose
}

foreach ($function in (Get-ChildItem "$ModuleRoot/functions" -Recurse -File -Filter "*.ps1")) {
    . Import-ModuleFile -Path $function.FullName -Verbose:$beVerbose
}

$postImportScriptPath = Join-Path $ModuleRoot "internal/scripts/postimport.ps1"
if (Test-Path $postImportScriptPath) {
    . Import-ModuleFile -Path $postImportScriptPath
}
