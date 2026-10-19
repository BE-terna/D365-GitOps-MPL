<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
#Requires -Version 7.0

BeforeAll {
    $script:moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '../D365GitOps')).ProviderPath
    $script:driverDirectory = Join-Path $moduleRoot 'functions/MergeDrivers'
    $script:mergeScript = Join-Path $driverDirectory 'Merge-D365XmlFile.ps1'
    $script:registerScript = Join-Path $moduleRoot 'functions/DeveloperSetup/Register-D365XmlFileMergeDriver.ps1'

    function Get-Sample {
        param(
            [string]
            $Suffix
        )

        return [System.IO.File]::ReadAllText((Join-Path $driverDirectory "Sample-Base$Suffix.xml"))
    }

    function New-MergeInput {
        param(
            [string]
            $Base
            ,
            [string]
            $Ours
            ,
            [string]
            $Theirs
            ,
            [switch]
            $Bom
        )

        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        $encoding = [System.Text.UTF8Encoding]::new($Bom.IsPresent)
        [System.IO.File]::WriteAllText((Join-Path $directory 'Base.xml'), $Base, $encoding)
        [System.IO.File]::WriteAllText((Join-Path $directory 'Ours.xml'), $Ours, $encoding)
        [System.IO.File]::WriteAllText((Join-Path $directory 'Theirs.xml'), $Theirs, $encoding)
        return $directory
    }

    # Runs the driver the way git does: separate pwsh process, relative temp file names.
    function Invoke-XmlMerge {
        param(
            [string]
            $Base
            ,
            [string]
            $Ours
            ,
            [string]
            $Theirs
            ,
            [string[]]
            $ArgumentList = @()
            ,
            [switch]
            $Bom
        )

        $directory = New-MergeInput -Base $Base -Ours $Ours -Theirs $Theirs -Bom:$Bom
        $output = & pwsh -NoProfile -WorkingDirectory $directory -File $mergeScript -Base Base.xml -Ours Ours.xml -Theirs Theirs.xml -FilePath test.xml @ArgumentList 2>&1
        $resultPath = Join-Path $directory 'Ours.xml'
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = [System.IO.File]::ReadAllText($resultPath)
            Bytes    = [System.IO.File]::ReadAllBytes($resultPath)
            Output   = ($output | Out-String)
        }
    }

    function Invoke-LineMerge {
        param(
            [string]
            $Base
            ,
            [string]
            $Ours
            ,
            [string]
            $Theirs
        )

        $directory = New-MergeInput -Base $Base -Ours $Ours -Theirs $Theirs
        $null = & git -C $directory merge-file -L ours -L base -L theirs Ours.xml Base.xml Theirs.xml
        return [System.IO.File]::ReadAllText((Join-Path $directory 'Ours.xml'))
    }

    function New-AxTable {
        param(
            # Fields as Name:ExtendedDataType.
            [string[]]
            $Field = @()
            ,
            [string]
            $Label = '@Test:Table'
        )

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
        $lines.Add('<AxTable xmlns:i="http://www.w3.org/2001/XMLSchema-instance">')
        $lines.Add("`t<Name>TestTable</Name>")
        $lines.Add("`t<Label>$Label</Label>")
        $lines.Add("`t<DeleteActions />")
        $lines.Add("`t<FieldGroups />")
        if ($Field.Count -eq 0) {
            $lines.Add("`t<Fields />")
        }
        else {
            $lines.Add("`t<Fields>")
            foreach ($item in $Field) {
                $name, $type = $item -split ':'
                $lines.Add("`t`t<AxTableField xmlns=`"`"")
                $lines.Add("`t`t`ti:type=`"AxTableFieldString`">")
                $lines.Add("`t`t`t<Name>$name</Name>")
                $lines.Add("`t`t`t<ExtendedDataType>$type</ExtendedDataType>")
                $lines.Add("`t`t</AxTableField>")
            }
            $lines.Add("`t</Fields>")
        }
        $lines.Add("`t<Indexes />")
        $lines.Add('</AxTable>')
        return $lines -join "`r`n"
    }

    function New-AxClass {
        param(
            # Method name -> statements.
            [System.Collections.IDictionary]
            $Method
        )

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]@(
                '<?xml version="1.0" encoding="utf-8"?>'
                '<AxClass xmlns:i="http://www.w3.org/2001/XMLSchema-instance">'
                "`t<Name>TestClass</Name>"
                "`t<SourceCode>"
                "`t`t<Declaration><![CDATA["
                'class TestClass'
                '{'
                '}'
                ']]></Declaration>'
                "`t`t<Methods>"
            ))
        foreach ($entry in $Method.GetEnumerator()) {
            $lines.Add("`t`t`t<Method>")
            $lines.Add("`t`t`t`t<Name>$($entry.Key)</Name>")
            $lines.Add("`t`t`t`t<Source><![CDATA[")
            $lines.Add("    public void $($entry.Key)()")
            $lines.Add('    {')
            foreach ($statement in $entry.Value) {
                $lines.Add("        $statement")
            }
            $lines.Add('    }')
            $lines.Add('')
            $lines.Add(']]></Source>')
            $lines.Add("`t`t`t</Method>")
        }
        $lines.Add("`t`t</Methods>")
        $lines.Add("`t</SourceCode>")
        $lines.Add('</AxClass>')
        return $lines -join "`r`n"
    }

    function New-AxPrivilege {
        param(
            # Entry point name -> form names.
            [System.Collections.IDictionary]
            $EntryPoint
        )

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
        $lines.Add('<AxSecurityPrivilege xmlns:i="http://www.w3.org/2001/XMLSchema-instance">')
        $lines.Add("`t<Name>TestPrivilege</Name>")
        $lines.Add("`t<EntryPoints>")
        foreach ($entry in $EntryPoint.GetEnumerator()) {
            $lines.Add("`t`t<AxSecurityEntryPointReference>")
            $lines.Add("`t`t`t<Name>$($entry.Key)</Name>")
            $lines.Add("`t`t`t<Grant>")
            $lines.Add("`t`t`t`t<Read>Allow</Read>")
            $lines.Add("`t`t`t</Grant>")
            $lines.Add("`t`t`t<ObjectName>$($entry.Key)</ObjectName>")
            $lines.Add("`t`t`t<ObjectType>MenuItemDisplay</ObjectType>")
            $lines.Add("`t`t`t<Forms>")
            foreach ($form in $entry.Value) {
                $lines.Add("`t`t`t`t<AxSecurityEntryPointReferenceForm>")
                $lines.Add("`t`t`t`t`t<Name>$form</Name>")
                $lines.Add("`t`t`t`t</AxSecurityEntryPointReferenceForm>")
            }
            $lines.Add("`t`t`t</Forms>")
            $lines.Add("`t`t</AxSecurityEntryPointReference>")
        }
        $lines.Add("`t</EntryPoints>")
        $lines.Add('</AxSecurityPrivilege>')
        return $lines -join "`n"
    }

    function New-Config {
        param(
            [string[]]
            $Id
        )

        $items = foreach ($value in $Id) { "    <item id=`"$value`">Item $value</item>" }
        return (@('<config>', '  <items>') + $items + @('  </items>', '</config>', '')) -join "`n"
    }
}

Describe 'Merge-D365XmlFile' {
    Context 'Task acceptance samples' {
        It 'merges ours <Ours> and theirs <Theirs> into Sample-Base<Expected>.xml' -TestCases @(
            @{ Ours = '-C001'; Theirs = '-C002'; Expected = '-Expected-a' }
            @{ Ours = '-C002'; Theirs = '-C001'; Expected = '-Expected-b' }
        ) {
            $result = Invoke-XmlMerge -Base (Get-Sample '') -Ours (Get-Sample $Ours) -Theirs (Get-Sample $Theirs)

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Merged order-independent XML elements'
            $result.Text | Should -BeExactly (Get-Sample $Expected)
        }
    }

    Context 'D365FO table fields' {
        It 'keeps fields added on both sides and preserves layout, CRLF and BOM' {
            $result = Invoke-XmlMerge -Bom `
                -Base (New-AxTable -Field 'A:Name') `
                -Ours (New-AxTable -Field 'A:Name', 'B:Name') `
                -Theirs (New-AxTable -Field 'A:Name', 'C:Name')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Merged order-independent XML elements'
            $result.Text | Should -BeExactly (New-AxTable -Field 'A:Name', 'B:Name', 'C:Name')
            $result.Bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'applies deletions and one-sided changes next to additions from the other side' {
            $result = Invoke-XmlMerge `
                -Base (New-AxTable -Field 'A:Name', 'B:Name', 'C:Name') `
                -Ours (New-AxTable -Field 'B:Description', 'C:Name', 'D:Name') `
                -Theirs (New-AxTable -Field 'A:Name', 'B:Name', 'E:Name')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Merged order-independent XML elements'
            $result.Text | Should -BeExactly (New-AxTable -Field 'B:Description', 'D:Name', 'E:Name')
        }

        It 'expands an empty collection' {
            $result = Invoke-XmlMerge `
                -Base (New-AxTable) `
                -Ours (New-AxTable -Field 'B:Name') `
                -Theirs (New-AxTable -Field 'C:Name')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (New-AxTable -Field 'B:Name', 'C:Name')
        }

        It 'collapses a collection emptied by both sides' {
            $result = Invoke-XmlMerge `
                -Base (New-AxTable -Field 'A:Name', 'B:Name') `
                -Ours (New-AxTable -Field 'B:Name') `
                -Theirs (New-AxTable -Field 'A:Name')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (New-AxTable)
        }

        It 'reports a conflict for the same field added with different content' {
            $result = Invoke-XmlMerge `
                -Base (New-AxTable -Field 'A:Name') `
                -Ours (New-AxTable -Field 'A:Name', 'B:Name') `
                -Theirs (New-AxTable -Field 'A:Name', 'B:Description')

            $result.ExitCode | Should -Be 1
            $result.Text | Should -Match '(?m)^<{7} ours'
            $result.Text | Should -Match '(?m)^>{7} theirs'
        }

        It 'reports a conflict when a field is deleted on one side and changed on the other' {
            $result = Invoke-XmlMerge `
                -Base (New-AxTable -Field 'A:Name', 'B:Name') `
                -Ours (New-AxTable -Field 'B:Name', 'C:Name') `
                -Theirs (New-AxTable -Field 'A:Description', 'B:Name', 'D:Name')

            $result.ExitCode | Should -Be 1
            $result.Text | Should -Match '(?m)^<{7} ours'
            $result.Text | Should -Match 'Description'
            $result.Text | Should -Match '<Name>C</Name>'
            $result.Text | Should -Match '<Name>D</Name>'
        }

        It 'keeps a clean line-based merge untouched' {
            $base = New-AxTable -Field 'A:Name'
            $ours = New-AxTable -Field 'A:Name' -Label '@Test:Changed'
            $theirs = New-AxTable -Field 'A:Name', 'C:Name'

            $result = Invoke-XmlMerge -Base $base -Ours $ours -Theirs $theirs

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (Invoke-LineMerge -Base $base -Ours $ours -Theirs $theirs)
            $result.Text | Should -BeExactly (New-AxTable -Field 'A:Name', 'C:Name' -Label '@Test:Changed')
        }
    }

    Context 'X++ methods' {
        It 'adds methods from both sides and line-merges a method changed on both sides' {
            $statements = 'int a = 1;', 'int b = 2;', 'int c = 3;', 'int d = 4;', 'int e = 5;'
            $oursStatements = 'int a = 10;', 'int b = 2;', 'int c = 3;', 'int d = 4;', 'int e = 5;'
            $theirsStatements = 'int a = 1;', 'int b = 2;', 'int c = 30;', 'int d = 4;', 'int e = 5;'

            $result = Invoke-XmlMerge `
                -Base (New-AxClass ([ordered]@{ run = $statements })) `
                -Ours (New-AxClass ([ordered]@{ run = $oursStatements; oursMethod = 'info("ours");' })) `
                -Theirs (New-AxClass ([ordered]@{ run = $theirsStatements; theirsMethod = 'info("theirs");' }))

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Merged order-independent XML elements'
            $result.Text | Should -BeExactly (New-AxClass ([ordered]@{
                        run          = 'int a = 10;', 'int b = 2;', 'int c = 30;', 'int d = 4;', 'int e = 5;'
                        oursMethod   = 'info("ours");'
                        theirsMethod = 'info("theirs");'
                    }))
        }
    }

    Context 'Nested collections' {
        It 'merges forms added on both sides inside the same entry point' {
            $result = Invoke-XmlMerge `
                -Base (New-AxPrivilege ([ordered]@{ EP1 = @('F1'); EP2 = @('F9') })) `
                -Ours (New-AxPrivilege ([ordered]@{ EP1 = @('F1', 'F2'); EP2 = @('F9') })) `
                -Theirs (New-AxPrivilege ([ordered]@{ EP1 = @('F1', 'F3'); EP2 = @('F9') }))

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Merged order-independent XML elements'
            $result.Text | Should -BeExactly (New-AxPrivilege ([ordered]@{ EP1 = @('F1', 'F2', 'F3'); EP2 = @('F9') }))
        }
    }

    Context 'Rules without key and namespaced documents' {
        It 'keeps module references added on both sides' {
            $descriptor = {
                param([string[]]$Reference)
                $items = foreach ($name in $Reference) { "    <d2p1:string>$name</d2p1:string>" }
                (@(
                        '<?xml version="1.0" encoding="utf-8"?>'
                        '<AxModelInfo xmlns:i="http://www.w3.org/2001/XMLSchema-instance">'
                        '  <ModuleReferences xmlns:d2p1="http://schemas.microsoft.com/2003/10/Serialization/Arrays">'
                    ) + $items + @(
                        '  </ModuleReferences>'
                        '  <Name>TestModel</Name>'
                        '</AxModelInfo>'
                    )) -join "`r`n"
            }

            $result = Invoke-XmlMerge `
                -Base (& $descriptor 'ApplicationPlatform') `
                -Ours (& $descriptor 'ApplicationPlatform', 'ApplicationSuite') `
                -Theirs (& $descriptor 'ApplicationPlatform', 'Directory')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (& $descriptor 'ApplicationPlatform', 'ApplicationSuite', 'Directory')
        }

        It 'matches rules by local name in a default namespace' {
            $form = {
                param([string[]]$Method)
                $items = foreach ($name in $Method) {
                    "`t`t`t<Method>`n`t`t`t`t<Name>$name</Name>`n`t`t`t`t<Source><![CDATA[`n    void $name() {}`n]]></Source>`n`t`t`t</Method>"
                }
                (@(
                        '<?xml version="1.0" encoding="utf-8"?>'
                        '<AxForm xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns="Microsoft.Dynamics.AX.Metadata.V6">'
                        "`t<Name>TestForm</Name>"
                        "`t<SourceCode>"
                        "`t`t<Methods xmlns=`"`">"
                    ) + $items + @(
                        "`t`t</Methods>"
                        "`t</SourceCode>"
                        '</AxForm>'
                    )) -join "`n"
            }

            $result = Invoke-XmlMerge `
                -Base (& $form 'init') `
                -Ours (& $form 'init', 'run') `
                -Theirs (& $form 'init', 'close')

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (& $form 'init', 'run', 'close')
        }
    }

    Context 'Rules lookup' {
        BeforeAll {
            $script:configRules = Join-Path $TestDrive 'config.xmlmergerules'
            Set-Content -LiteralPath $configRules -Value '# generic XML', '/config/items/item key=@id'
            $script:invalidRules = Join-Path $TestDrive 'invalid.xmlmergerules'
            Set-Content -LiteralPath $invalidRules -Value '/config/items/['
        }

        It 'returns the line-based conflict when no rule matches' {
            $base = New-Config '1'
            $ours = New-Config '1', '2'
            $theirs = New-Config '1', '3'

            $result = Invoke-XmlMerge -Base $base -Ours $ours -Theirs $theirs

            $result.ExitCode | Should -Be 1
            $result.Text | Should -BeExactly (Invoke-LineMerge -Base $base -Ours $ours -Theirs $theirs)
        }

        It 'uses -RulesPath' {
            $result = Invoke-XmlMerge -Base (New-Config '1') -Ours (New-Config '1', '2') -Theirs (New-Config '1', '3') -ArgumentList '-RulesPath', $configRules

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (New-Config '1', '2', '3')
        }

        It 'uses $env:D365GITOPS_XML_MERGE_RULES' {
            $env:D365GITOPS_XML_MERGE_RULES = $configRules
            try {
                $result = Invoke-XmlMerge -Base (New-Config '1') -Ours (New-Config '1', '2') -Theirs (New-Config '1', '3')
            }
            finally {
                Remove-Item Env:\D365GITOPS_XML_MERGE_RULES
            }

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Text | Should -BeExactly (New-Config '1', '2', '3')
        }

        It 'falls back to the line-based result for an invalid rules file' {
            $base = New-Config '1'
            $ours = New-Config '1', '2'
            $theirs = New-Config '1', '3'

            $result = Invoke-XmlMerge -Base $base -Ours $ours -Theirs $theirs -ArgumentList '-RulesPath', $invalidRules

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Invalid rule'
            $result.Text | Should -BeExactly (Invoke-LineMerge -Base $base -Ours $ours -Theirs $theirs)
        }
    }

    Context 'Export of the default rules' {
        It 'writes the shipped rules and refuses to overwrite without -Force' {
            $target = Join-Path $TestDrive '.xmlmergerules'

            & pwsh -NoProfile -File $mergeScript -ExportDefaultRules $target | Out-Null
            $LASTEXITCODE | Should -Be 0
            Get-Content -LiteralPath $target -Raw | Should -BeExactly (Get-Content -LiteralPath (Join-Path $driverDirectory 'D365FO.xmlmergerules') -Raw)

            & pwsh -NoProfile -File $mergeScript -ExportDefaultRules $target 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0

            & pwsh -NoProfile -File $mergeScript -ExportDefaultRules $target -Force | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context 'git integration' {
        It 'merges branches through git with the registered driver and repository rules' {
            $repository = Join-Path $TestDrive 'repository'
            $null = New-Item -ItemType Directory -Path $repository
            $git = {
                $output = & git -C $repository @args 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git $args failed: $($output | Out-String)" }
            }
            & $git init --quiet --initial-branch=main
            & $git config core.autocrlf false
            & $git config commit.gpgsign false
            & $git config user.name 'Test'
            & $git config user.email 'test@example.com'

            $moduleManifest = Join-Path $moduleRoot 'D365GitOps.psd1'
            $registration = & pwsh -NoProfile -WorkingDirectory $repository -Command "Import-Module '$moduleManifest'; Register-D365XmlFileMergeDriver" 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($registration | Out-String)
            (& git -C $repository config --get merge.d365fo-xml.driver) | Should -Match '-File'

            Set-Content -LiteralPath (Join-Path $repository '.gitattributes') -Value '*.xml merge=d365fo-xml'
            Set-Content -LiteralPath (Join-Path $repository '.xmlmergerules') -Value @(
                '/AxSecurityPrivilege/EntryPoints/AxSecurityEntryPointReference key=Name'
                '/config/items/item key=@id'
            )
            $privilege = Join-Path $repository 'Privilege.xml'
            $config = Join-Path $repository 'Config.xml'
            [System.IO.File]::WriteAllText($privilege, (Get-Sample ''))
            [System.IO.File]::WriteAllText($config, (New-Config '1'))
            & $git add --all
            & $git commit --quiet -m base

            & $git checkout --quiet -b user1
            [System.IO.File]::WriteAllText($privilege, (Get-Sample '-C001'))
            [System.IO.File]::WriteAllText($config, (New-Config '1', '2'))
            & $git commit --quiet --all -m user1

            & $git checkout --quiet -b user2 main
            [System.IO.File]::WriteAllText($privilege, (Get-Sample '-C002'))
            [System.IO.File]::WriteAllText($config, (New-Config '1', '3'))
            & $git commit --quiet --all -m user2

            & $git checkout --quiet user1
            $merge = & git -C $repository merge --no-edit user2 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($merge | Out-String)

            [System.IO.File]::ReadAllText($privilege) | Should -BeExactly (Get-Sample '-Expected-a')
            [System.IO.File]::ReadAllText($config) | Should -BeExactly (New-Config '1', '2', '3')
        }
    }
}

Describe 'D365GitOps module' {
    It 'has a valid manifest that exports the XML merge driver commands' {
        $manifest = Test-ModuleManifest -Path (Join-Path $moduleRoot 'D365GitOps.psd1') -ErrorAction Stop

        $manifest.ExportedFunctions.Keys | Should -Contain 'Merge-D365XmlFile'
        $manifest.ExportedFunctions.Keys | Should -Contain 'Register-D365XmlFileMergeDriver'
    }

    It 'exports the default rules when used as a module function' {
        # Same conversion D365GitOps.psm1 applies to advanced scripts.
        $scriptInfo = Get-Command -Name $mergeScript -CommandType ExternalScript
        $null = New-Item -Path Function:\Merge-D365XmlFileUnderTest -Value $scriptInfo.ScriptBlock -Force
        try {
            $target = Join-Path $TestDrive 'module.xmlmergerules'

            Merge-D365XmlFileUnderTest -ExportDefaultRules $target | Should -BeOfType [System.IO.FileInfo]
            Get-Content -LiteralPath $target -Raw | Should -BeExactly (Get-Content -LiteralPath (Join-Path $driverDirectory 'D365FO.xmlmergerules') -Raw)
        }
        finally {
            Remove-Item -Path Function:\Merge-D365XmlFileUnderTest
        }
    }

    It 'returns the merge status when used as a module function' {
        $directory = New-MergeInput `
            -Base (New-Config '1') `
            -Ours (New-Config '1', '2') `
            -Theirs (New-Config '1')
        $base = Join-Path $directory 'Base.xml'
        $ours = Join-Path $directory 'Ours.xml'
        $theirs = Join-Path $directory 'Theirs.xml'
        $command = @"
`$scriptInfo = Get-Command -Name '$mergeScript' -CommandType ExternalScript
`$null = New-Item -Path Function:\Merge-D365XmlFileUnderTest -Value `$scriptInfo.ScriptBlock -Force
`$status = Merge-D365XmlFileUnderTest -Base '$base' -Ours '$ours' -Theirs '$theirs'
"continued:`$status"
"@

        $output = & pwsh -NoProfile -Command $command

        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain 'continued:0'
        [System.IO.File]::ReadAllText($ours) | Should -BeExactly (New-Config '1', '2')
    }
}
