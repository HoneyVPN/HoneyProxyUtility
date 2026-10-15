# Windows publisher signing / Подпись издателя Windows

Status checked: 2026-10-15. The private 1.2.0+2129 Setup is unsigned.
The verified Microsoft signatures on bundled Visual C++ libraries are not a
publisher signature on HoneyProxyUtility. Android keeps its existing signing
identity; this document does not authorize changing that key.

## Release procedure

1. Choose a publicly trusted Windows Authenticode code-signing service or
   certificate. Validate the actual publisher identity, code-signing usage,
   supported algorithms, certificate chain and expiration before paying.
2. Keep its private key on the provider's HSM or supported hardware token.
   Do not commit keys, export them into the source tree or put a token PIN in
   shell arguments, CI output or support reports.
3. Freeze and test the source. Sign the application's own executable and
   `HoneyVpnService.exe` with SHA-256 and an RFC 3161 timestamp. Verify
   each resulting signature with SignTool's Authenticode policy (`verify /pa`).
   Preserve upstream signatures on third-party dependencies.
4. Build Inno Setup from those signed payloads. Configure Inno's documented
   signed-uninstaller support, then sign and timestamp the completed Setup.
   Do not modify a binary after signing it.
5. Verify the installed app, service, Setup and uninstaller: expected publisher,
   valid chain, code-signing use and timestamp. A local self-signed certificate
   installed on a developer PC is not proof of public trust.
6. Re-run installation, direct public-version upgrade, medium-token service
   access and uninstall on a clean guest. Record SHA-256 of the final signed
   Setup and publish only those exact bytes after release approval.

Signing changes binary hashes and must precede the final installer qualification.
The certificate issuer/provider has not yet been chosen. No certificate purchase,
key enrollment, publisher change or production signing has been performed.

## Eligibility and current limitation

The owner currently identifies the publisher as an individual entrepreneur in
Russia. Microsoft Artifact Signing Public Trust is currently offered to
organizations in the USA, Canada, EU and UK, and to individuals in the USA and
Canada. It is therefore not presently an available enrollment path for this
Russian publisher. Its advertised Basic price is $9.99/month, but that is not an
offer available to this publisher.

DigiCert and Sectigo also publish restrictions on Russian issuance. Do not assume
a reseller's checkout means a certificate can be issued. Verify eligibility with
the actual issuer before purchase.

The owner has an Interfax-related signature previously used for Google Play
Console, currently unavailable for inspection. Its suitability is **unverified**.
A document/identity-verification signature or an Android APK signing key must not
be described as a Windows code-signing certificate without checking its purpose
and public Windows trust. Inspection needs only the public certificate and its
chain; no private key, PIN or password is needed.

SignPath Foundation is a possible application route for qualifying fully open
source projects, subject to acceptance and its published conditions. It is not
an issued certificate for this project. Its publisher identity is the Foundation,
not automatically the developer's brand.

Authenticode authenticates the publisher and detects changes. It does not promise
that every new download immediately avoids SmartScreen warnings or antivirus
false positives.

## Кратко для владельца

Для установщика нужен сертификат **подписи программ Windows (Code Signing)** с
доверенной цепочкой. Подпись документов для Google Play сама по себе этого не
подтверждает. Имеющийся открытый сертификат ещё не проверен. Для ИП РФ доступность
выпуска нужно подтвердить у удостоверяющего центра; облачный вариант Microsoft
сейчас не поддерживает эту страну. До выбора доступного поставщика и проверки
сертификата сборки остаются без подписи издателя. Покупка и выпуск сертификата
требуют участия владельца.

## Primary references

- [Microsoft: code-signing options and eligibility](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
- [Microsoft: SignTool](https://learn.microsoft.com/windows/win32/seccrypto/signtool)
- [Microsoft: Artifact Signing pricing](https://azure.microsoft.com/en-us/products/artifact-signing)
- [DigiCert: restricted issuance](https://knowledge.digicert.com/solution/embargoed-countries-and-regions)
- [Sectigo: restricted countries](https://support.sectigo.com/Com_KnowledgeDetailPage?Id=kA01N000000zFKI)
- [SignPath Foundation: conditions](https://signpath.org/terms.html)
- [Inno Setup: SignTool](https://jrsoftware.org/ishelp/topic_setup_signtool.htm)
