$script:ModuleRoot = $PSScriptRoot

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
        . (Resolve-Path $Path).ProviderPath
    }
}

if (Test-Path "$ModuleRoot/internal/scripts/preimport.ps1") {
    . Import-ModuleFile -Path "$ModuleRoot/internal/scripts/preimport.ps1"
}

foreach ($function in (Get-ChildItem "$ModuleRoot/internal/functions" -Recurse -File -Filter "*.ps1")) {
    . Import-ModuleFile -Path $function.FullName
}

foreach ($function in (Get-ChildItem "$ModuleRoot/functions" -Recurse -File -Filter "*.ps1")) {
    . Import-ModuleFile -Path $function.FullName
}

if (Test-Path "$ModuleRoot/internal/scripts/postimport.ps1") {
    . Import-ModuleFile -Path "$ModuleRoot/internal/scripts/postimport.ps1"
}
