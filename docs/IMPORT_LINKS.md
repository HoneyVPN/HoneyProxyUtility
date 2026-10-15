# Import links

Installed Honey apps use one import contract:

```text
honeyvpn://import?url=<percent-encoded-source>
```

Encode the entire subscription address or server link once: JavaScript
`encodeURIComponent(source)`; Python `urllib.parse.quote(source, safe="")`.
Embedded query parameters, plus signs and server-name fragments must remain
inside that encoded value. The envelope accepts exactly one `url` parameter;
it has no connect, delete, overwrite or automatic-save action.

Honey opens Import and prepares a preview. HTTP(S) subscription sources are
fetched by the existing importer. The user reviews the result and chooses
**Add** before a subscription or server is saved. A second link updates an
already-open preview and cancels an earlier pending import request. Repeated
native delivery of the same source within two seconds is ignored.

## Delivery and supported devices

Android receives `ACTION_VIEW` on cold startup or `onNewIntent`, then forwards
the complete URI through `ru.honeyvpn.proxy/deeplink`. Flutter's built-in Android
deep-link receiver is disabled so it cannot also route the URI. macOS declares
`CFBundleURLTypes` and forwards AppKit `application(_:open:)` activations through
the same channel. Native receivers retain a pending activation until Flutter
listens; Dart waits for a rendered frame before navigating. Windows registers
the scheme through the installer and forwards a second launch to the existing
unprivileged app instance. Install this candidate before testing its handler.

There is currently no iOS Runner or installable Honey iPhone app in this
repository. The URI contract can be reused by a future iOS host, but an iPhone
cannot open Honey until that app is implemented, signed and distributed.
Import support does not change the macOS VPN signing/readiness gates.

The existing HoneyVPN bot already generates this exact canonical URI through
its HTTPS `/app/honey-open?sub=<short_uuid>` endpoint. The bot constructs the full
subscription address from its configured `SUB_URL` and percent-encodes it once.
The WebApp opens that endpoint through Telegram's `openLink`. This candidate
adds the desktop OS receivers; it preserves the existing bot protocol.

Browsers and Telegram clients may refuse direct custom-scheme buttons. An
optional standalone HTTPS launcher template is also included:
`https://<your-host>/import#url=<percent-encoded-source>`.
It requires deployment to a controlled HTTPS host and an explicit user tap to
open Honey. Tokens belong in the fragment, not a launcher query or analytics.
The page has a copy fallback; it does not download subscriptions itself.
No launcher has been deployed and no live bot configuration is changed by
these source changes.

## Validation

The shared parser accepts envelopes up to 64 KiB UTF-8 and decoded sources up
to 16 KiB UTF-8. These are safety ceilings, not a guarantee that every browser
or OS will forward a link that large; notably Windows shell command lines have
a lower character limit. Long configurations can be pasted into Import.

Supported sources are HTTP(S) subscription addresses and the existing server
URI formats: `vless`, `vmess`, `trojan`, `ss`, `hy2`, `hysteria2`, `tuic`,
`wireguard`, `awg`, `vpn`, `naive`, `naive+https`, `naive+quic` and
`shadowtls`. The protocol importer still validates their actual options and
the VPN support matrix still applies. Importing a future-supported profile
does not enable a currently unavailable VPN protocol.

Invalid escapes, duplicate or unknown envelope parameters, control characters,
files, shell commands and nested Honey actions are rejected. Error messages
use localized safe codes; native and Dart receivers do not log the URI,
subscription token or native error details.

## Verification

Automated tests cover parsing, UTF-8 bounds, startup buffering, duplicate
delivery, updating a mounted preview, localized malformed/transport errors and
disposal while navigation is queued. The widget HTTP adapter uses synthetic
responses and does not contact a subscription service.

After installation, test a synthetic URI both when Honey is closed and when
Import is already open. On Android a package-scoped test is:

```sh
adb shell am start -W -a android.intent.action.VIEW \
  -d 'honeyvpn://import?url=https%3A%2F%2Fsub.example.test%2Fsynthetic' \
  ru.honeyvpn.proxy
```

On macOS launch the installed app normally once, then use
`open 'honeyvpn://import?url=...'` with a synthetic server link. This is an
import-only check: do not start a VPN or use a real token in commands/logs.
Also test two different links, duplicate delivery, malformed input and manual
copy fallback from each supported Telegram client. Actual OS registration and
Telegram client behavior require this installed-device QA.

Primary platform references:
[Android deep links](https://developer.android.com/training/app-links/create-deeplinks),
[Flutter custom-handler opt-out](https://docs.flutter.dev/release/breaking-changes/deep-links-flag-change),
[AppKit URL delivery](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopen%3A%29),
[Apple custom URL schemes](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app).
