# Local Mac VPN development

This procedure creates a development-signed **Debug** build for routing tests on
this Mac. It does not publish, install a VPN profile, start a tunnel, accept
agreements, purchase membership or change macOS security settings.
`HoneyProxyCoreReady` stays false in the source and signed bundle. Only a Debug
build explicitly compiled with `HONEYPROXY_DEVELOPMENT_VPN`, valid Apple-anchored
development signatures and matching Network Extension/App Group entitlements
can pass the separate local development gate.

## What the owner must prepare

1. Open full Xcode personally, review its license and complete first launch.
   The helper checks the status and never accepts the license or runs first-launch
   installation. Use a working Python 3 installation; the system Python shim can
   itself stop at the Xcode license prompt.
2. Use an existing paid Apple Developer team, or enroll personally if appropriate.
   A free **Personal Team cannot provision Network Extension providers**. A paid
   Individual team can use this capability for local development; Organization
   enrollment is not required for local Debug testing. Apple DTS confirms the
   [Personal Team limit](https://developer.apple.com/forums/thread/128767) and
   [paid Individual support](https://developer.apple.com/forums/thread/815456).
   [Membership is 99 USD per year](https://developer.apple.com/programs/enroll/),
   with regional pricing shown during enrollment. No registration or payment is
   performed by the helper.
3. Sign in to Xcode → Settings → Apple Accounts. Select the same paid team for
   Runner and HoneyProxyPacketTunnel. Create an **Apple Development** identity in
   the local Keychain; its private key stays on this Mac. Provision both targets
   in Xcode, with these identifiers and capabilities:

   | Target | Bundle identifier | Required capabilities |
   | --- | --- | --- |
   | Runner | `ru.honeyvpn.proxy.macos` | App Sandbox, Network Extensions → Packet Tunnel, App Groups |
   | Packet tunnel | `ru.honeyvpn.proxy.macos.PacketTunnel` | App Sandbox, Network Extensions → Packet Tunnel, App Groups |

   Both targets must use `group.ru.honeyvpn.proxy`. Register that group to the
   selected team and include it in both profiles. The `group.` form requires
   profile authorization on macOS; see [Apple's App Group guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).
   Register this Mac and obtain **Mac App Development** profiles. For Apple
   silicon use its provisioning UDID, not an assumed hardware UUID.
   [Development profiles](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile),
   [device registration](https://developer.apple.com/help/account/devices/register-a-single-device/).
4. Obtain the reviewed `Libbox-macOS-framework-headers-preview` CI artifact.
   Verify the zip against its `SHA256SUMS` before extracting. That checksum entry
   may include a CI directory prefix; match the known basename
   `Libbox-macOS-preview.zip`, not an arbitrary artifact-supplied path. The artifact
   contains the zip, `apple-core-build.json` and `SHA256SUMS`. Stage it manually:

   ```sh
   python3 scripts/prepare_apple_framework.py /path/to/Libbox.xcframework /path/to/apple-core-build.json
   ```

   This separate staging command replaces `macos/Frameworks`; preflight never
   runs it. The reviewed revision is
   `a47bdbe2aefc4da0aa8dd2280fb54c429dd0bfe0`, version
   `v1.13.12-extended-2.1.2`, with the exact feature set in the staging script.
   `core-lock.json` is the shared selection; the framework is rebuilt with
   Go 1.26.8 and gomobile/gobind v0.1.12. Older staging is rejected after this
   update. This compatible patch preserves WireGuard/WARP `reserved` fields;
   later fork releases remove them and require a separate migration. See
   [the compatibility decision](APPLE_ROADMAP.md#core-build-and-runtime).
   The build helper checks the staged metadata, headers, universal slice and
   linkage configuration. This inspection does not replace verifying the
   downloaded artifact checksum.

Do not send Apple passwords, signing private keys, certificate subjects or
provisioning profiles to another person or attach them to a public issue. A Team
ID is sufficient to select a team; account access remains in Xcode. The helper
prints only identity/profile counts, not their subjects, UUIDs or device IDs.

## Inspect, then explicitly build

From the private repository, use the installed Flutter **3.41.7** executable:

```sh
python3 scripts/build_apple_development.py --flutter /path/to/flutter/bin/flutter
python3 scripts/build_apple_development.py --team-id ABCDE12345 --flutter /path/to/flutter/bin/flutter
```

The default is read-only. It checks full Xcode, first launch, native architecture,
valid local Apple Development identities, staged pinned Libbox, the cached
Flutter version, lockfiles and source readiness. With a team it also checks
existing profiles for both targets and this Mac. It returns `2` when prerequisites
are missing. `--developer-dir /path/to/Xcode.app/Contents/Developer` selects a
full Xcode for this invocation without changing global `xcode-select`.

After manually preparing all prerequisites:

```sh
python3 scripts/build_apple_development.py --build --team-id ABCDE12345 --flutter /path/to/flutter/bin/flutter
```

Only `--build` permits generated-file preparation and signing. It runs locked
`flutter pub get --enforce-lockfile`, Debug configuration-only preparation, then
native-architecture Xcode Debug compilation with the explicit development flag
and `CODE_SIGN_IDENTITY=Apple Development`. CocoaPods is used only if the project
has a Podfile, with a reviewed Podfile.lock and `pod install --deployment`. The
current Flutter project also supports its generated Swift Package Manager setup.
It never passes `-allowProvisioningUpdates` or
`-allowProvisioningDeviceRegistration`; missing account/profile preparation must
be resolved by the owner in Xcode. No private source upload, key import or profile
copying is performed.

The output is `build/macos-local-development/Build/Products/Debug/HoneyProxyUtility.app`.
The helper runs `validate_apple_bundle.py --verify-only --local-development`, so
it **does not modify the signed bundle**, then checks Apple-anchored strict
signatures, both bundle IDs, the requested team, signed entitlements and embedded
profiles. Profiles must be unexpired Mac development profiles with the exact
App ID, this registered Mac, required capabilities and the actual public signing
certificate. Public certificate bytes are extracted to an automatically removed
temporary directory solely for this comparison; private keys and profiles are
never copied or logged.

Success means a development bundle passed these checks. It is **not evidence of
VPN traffic forwarding**. The owner must still approve the native VPN permission
and test real connection/stop/reconnect, counter availability and rates,
IPv4/IPv6/DNS routing, permission refusal, provider failure and crash/reopen.
Record observed results before any production readiness change. Without a paid
team, UI, unit tests, native mapper tests and core configuration checks remain
possible; the custom Network Extension tunnel cannot be validated on-device.

## Distribution is a separate decision

Local Apple Development signing does not produce a public installer.
[Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
limits macOS packet-tunnel **app extensions** to App Store distribution; local
registered-Mac development remains a separate workflow. Direct Developer ID
distribution needs a **system extension**, its activation flow and
`packet-tunnel-provider-systemextension` entitlement, Developer ID profiles,
signing and notarization. Merely changing the certificate on the current `.appex`
is insufficient. [Apple's Developer ID guidance](https://developer.apple.com/forums/thread/737894).

For an App Store app offering VPN services, [App Review Guideline 5.4](https://developer.apple.com/app-store/review/guidelines/#vpn-apps)
requires Organization enrollment. This publication requirement is distinct from
paid Individual local testing. Neither this helper nor a successful unsigned CI
build establishes App Store acceptance or a working signed VPN release.
