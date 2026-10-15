$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Load only the production predicate; do not inspect the host trust store or
# execute the bundle verifier when testing untrusted signature metadata.
$path=Join-Path $PSScriptRoot '../../scripts/verify_windows_runtime.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count -ne 0){throw 'Runtime verifier does not parse'}
$functions=@($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Test-HoneyMicrosoftRuntimeSignature'
},$true))
if($functions.Count -ne 1){throw 'Expected one production signature predicate'}
. ([scriptblock]::Create($functions[0].Extent.Text))

function New-Signature([string]$Publisher,[string]$Type='Authenticode',
    [string]$Status='Valid',[string]$Organization='Microsoft Corporation') {
    $certificate=[pscustomobject]@{
        Subject='CN='+$Publisher+', O='+$Organization+', C=US'
        PublicName=$Publisher
    }
    $certificate|Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value {
        param($Kind,$Issuer)
        return $this.PublicName
    }
    return [pscustomobject]@{Status=$Status;SignatureType=$Type;SignerCertificate=$certificate}
}
$cases=@(
    @{Name='Original Microsoft Authenticode';Signature=(New-Signature 'Microsoft Corporation');Expected=$true},
    @{Name='Original compatibility Authenticode';Signature=(New-Signature 'Microsoft Windows Software Compatibility Publisher');Expected=$true},
    @{Name='Original Microsoft catalog';Signature=(New-Signature 'Microsoft Corporation' 'Catalog');Expected=$true},
    @{Name='Original compatibility catalog';Signature=(New-Signature 'Microsoft Windows Software Compatibility Publisher' 'Catalog');Expected=$true},
    @{Name='Exact Microsoft Windows catalog';Signature=(New-Signature 'Microsoft Windows' 'Catalog');Expected=$true},
    @{Name='Microsoft Windows Authenticode rejected';Signature=(New-Signature 'Microsoft Windows');Expected=$false},
    @{Name='Microsoft Windows unsigned type rejected';Signature=(New-Signature 'Microsoft Windows' 'None');Expected=$false},
    @{Name='Microsoft Windows unknown type rejected';Signature=(New-Signature 'Microsoft Windows' 'Other');Expected=$false},
    @{Name='Case-changed new publisher rejected';Signature=(New-Signature 'microsoft windows' 'Catalog');Expected=$false},
    @{Name='Near-match new publisher rejected';Signature=(New-Signature 'Microsoft Windows Other' 'Catalog');Expected=$false},
    @{Name='Unrelated catalog publisher rejected';Signature=(New-Signature 'Other Corporation' 'Catalog');Expected=$false},
    @{Name='Wrong organization new publisher rejected';Signature=(New-Signature 'Microsoft Windows' 'Catalog' 'Valid' 'Other Corporation');Expected=$false},
    @{Name='Wrong organization original publisher rejected';Signature=(New-Signature 'Microsoft Corporation' 'Authenticode' 'Valid' 'Other Corporation');Expected=$false},
    @{Name='Organization substring rejected';Signature=(New-Signature 'Microsoft Windows' 'Catalog' 'Valid' 'Microsoft Corporation Extra');Expected=$false},
    @{Name='Null signature rejected';Signature=$null;Expected=$false},
    @{Name='Missing signer rejected';Signature=([pscustomobject]@{Status='Valid';SignatureType='Catalog';SignerCertificate=$null});Expected=$false},
    @{Name='Case-changed catalog type rejected';Signature=(New-Signature 'Microsoft Windows' 'catalog');Expected=$false}
)
foreach($status in @('NotSigned','HashMismatch','NotTrusted','UnknownError','NotSupportedFileFormat','Incompatible')){
    $cases+=@{Name=('Invalid catalog status '+$status);Signature=(New-Signature 'Microsoft Windows' 'Catalog' $status);Expected=$false}
    $cases+=@{Name=('Invalid original publisher status '+$status);Signature=(New-Signature 'Microsoft Corporation' 'Authenticode' $status);Expected=$false}
}
foreach($case in $cases){
    $actual=Test-HoneyMicrosoftRuntimeSignature $case.Signature
    if($actual -ne $case.Expected){throw ('Signature-policy fixture failed: '+$case.Name)}
}
Write-Output ('PASS '+$cases.Count+' production signature-policy fixtures; no host trust-store or bundle state changed')
