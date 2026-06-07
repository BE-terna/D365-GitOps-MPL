dotnet tool install  --prerelease sign


$m = Install-Module  Az.ArtifactSigning -PassThru
$m = import-module Az.ArtifactSigning -Force -PassThru
Connect-AzAccount -Tenant be-terna.com -UseDeviceAuthentication

Invoke-TrustedSigning `
-Endpoint https://weu.codesigning.azure.net/ `
-CodeSigningAccountName "BE-terna" `
-CertificateProfileName "BE-terna" `
--FilesFold ./D365GitOps -FileDigest 

Install-Module -Name ArtifactSigning -Verbose -PassThru
Import-Module -Name ArtifactSigning -Verbose -PassThru

Invoke-ArtifactSigning `
-Endpoint https://weu.codesigning.azure.net/ `
-CodeSigningAccountName "BE-terna" `
-CertificateProfileName "BE-terna" `
-FilesFolder ./D365GitOps -Verbose
