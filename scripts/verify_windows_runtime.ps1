param([Parameter(Mandatory=$true)][string]$BundleDirectory)
$ErrorActionPreference='Stop'
function Test-HoneyMicrosoftRuntimeSignature($Signature) {
    # Authenticode may select a Microsoft catalog signature instead of the
    # embedded signature. The additional alias is valid only for that type.
    if($null -eq $Signature -or $Signature.Status -ne 'Valid' -or
       $null -eq $Signature.SignerCertificate) { return $false }
    $certificate=$Signature.SignerCertificate
    $publisher=$certificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)
    if($certificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { return $false }
    if($publisher -in @('Microsoft Corporation','Microsoft Windows Software Compatibility Publisher')) {
        return $true
    }
    return $publisher -ceq 'Microsoft Windows' -and [string]$Signature.SignatureType -ceq 'Catalog'
}
$honeyBundle=(Get-Item -LiteralPath $BundleDirectory -ErrorAction Stop).FullName
foreach($honeyRequired in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    if(-not [IO.File]::Exists((Join-Path $honeyBundle $honeyRequired))) {
        throw ('Missing bundled Visual C++ runtime: '+$honeyRequired)
    }
}
$honeyRuntimeFiles=@(Get-ChildItem -LiteralPath $honeyBundle -File | Where-Object {
    $_.Name -match '^(msvcp140(?:_\w+)?|vcruntime140(?:_\w+)?|concrt140|vccorlib140)\.dll$'
})
foreach($honeyFile in $honeyRuntimeFiles) {
    if($honeyFile.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Bundled runtime must be a regular file.'
    }
    $honeySignature=Get-AuthenticodeSignature -LiteralPath $honeyFile.FullName
    if(-not (Test-HoneyMicrosoftRuntimeSignature $honeySignature)) {
        throw ('Bundled runtime lacks a valid Microsoft signature: '+$honeyFile.Name)
    }
    $honeyStream=[IO.File]::OpenRead($honeyFile.FullName)
    $honeyReader=[IO.BinaryReader]::new($honeyStream)
    try {
        if($honeyStream.Length -lt 64 -or $honeyReader.ReadUInt16() -ne 0x5a4d) {
            throw 'Runtime has an invalid DOS header.'
        }
        $null=$honeyStream.Seek(0x3c,[IO.SeekOrigin]::Begin)
        $honeyPeOffset=$honeyReader.ReadInt32()
        if($honeyPeOffset -lt 64 -or $honeyPeOffset -gt $honeyStream.Length-6) {
            throw 'Runtime has an invalid PE offset.'
        }
        $null=$honeyStream.Seek($honeyPeOffset,[IO.SeekOrigin]::Begin)
        if($honeyReader.ReadUInt32() -ne 0x00004550 -or $honeyReader.ReadUInt16() -ne 0x8664) {
            throw ('Runtime is not Windows x64: '+$honeyFile.Name)
        }
    } finally { $honeyReader.Dispose() }
    [pscustomobject]@{Runtime=$honeyFile.Name;SHA256=(Get-FileHash -LiteralPath $honeyFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant();Architecture='x64';MicrosoftSignature='Valid'} | ConvertTo-Json -Compress
}
