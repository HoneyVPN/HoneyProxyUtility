param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$Application)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('honey-native-path-' + [Guid]::NewGuid().ToString('N'))
$plain = Join-Path $root ('Test User ' + [char]0x0422 + [char]0x0435 + [char]0x0441 + [char]0x0442)
$junction = Join-Path $root 'junction'
try {
    New-Item -ItemType Directory -Path $plain | Out-Null
    [IO.File]::WriteAllText((Join-Path $plain 'fixture.json'), '{}')
    New-Item -ItemType Junction -Path $junction -Target $plain | Out-Null
    & $Executable $plain $junction $Application
    if ($LASTEXITCODE -ne 0) { throw 'Native session path guard failed' }
} finally {
    if (Test-Path -LiteralPath $junction) {
        if (([IO.File]::GetAttributes($junction) -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw 'Fixture cleanup refuses a non-junction directory'
        }
        # Windows PowerShell Remove-Item asks about nonempty junction targets
        # even with -Force. Nonrecursive .NET deletion removes only the link.
        [IO.Directory]::Delete($junction, $false)
        if ((Test-Path -LiteralPath $junction) -or
            [IO.File]::ReadAllText((Join-Path $plain 'fixture.json')) -cne '{}') {
            throw 'Junction cleanup must preserve the target and its contents'
        }
        Write-Host 'PASS noninteractive junction cleanup preserves target contents'
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
