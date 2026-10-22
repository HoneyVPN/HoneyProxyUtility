# WinGet submission metadata

These manifests describe the official HoneyProxyUtility 1.2.0 Windows x64
Inno Setup installer. English and Russian package descriptions are included.
The download URL is versioned; its SHA-256 matches the published release.

**These files are prepared for submission. They do not mean that the package
has been accepted into the WinGet community repository.**

Before creating a pull request in
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs), run the native
validator on Windows:

```powershell
winget validate --manifest .\manifests\h\HoneyVPN\HoneyProxyUtility\1.2.0
```

The four files have passed the official 1.12.0 JSON schemas. Native WinGet
validation, installation/detection checks, security scanning and moderation
remain separate steps. The public 1.2.0 installer is unsigned; this metadata
does not add Authenticode signing or change Windows trust decisions.

The installer performs a machine-wide installation, registers the `honeyvpn`
URI protocol and installs the Honey VPN service. Keep the original Inno
installation path; extracting the EXE as a portable package would omit service
setup. See the release notes for outstanding upgrade and recovery checks.
