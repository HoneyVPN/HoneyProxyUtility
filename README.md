# HoneyProxyUtility

Универсальный VPN-клиент для Android и Windows на базе [sing-box](https://github.com/SagerNet/sing-box).
macOS остаётся предпросмотром; iPhone — следующий этап.

Поддерживаемые протоколы: **VLESS Reality**, **VLESS xHTTP**, **VMess**, **Trojan**, **Shadowsocks**, **Hysteria2**, **TUIC**, **WireGuard**, **AmneziaWG**. **ShadowTLS + Shadowsocks** реализован на Android.

| Подключение | Android | Windows |
| --- | --- | --- |
| VLESS TCP, WebSocket, HTTP (`h2`/`http`), gRPC, HTTPUpgrade, базовый xHTTP | Да | Да |
| VLESS TLS / Reality / Vision, совместимый формат VLESS Encryption | Да, с ограничениями ниже | Да, с ограничениями ниже |
| Hysteria 2: TLS, Salamander, фиксированный port hopping | Да | Да |
| VMess, Trojan, Shadowsocks, TUIC, WireGuard | Да | Да |
| AmneziaWG: scalar J/S/H, INI / `awg://` / AWG-контейнер `vpn://` | Подмножество параметров | Подмножество параметров |
| Hysteria 1, расширенный AWG 2/3.1, другие протоколы внутри Amnezia `vpn://` | Нет | Нет |
| ShadowTLS + Shadowsocks | Да | Пока не реализовано |
| NaiveProxy HTTPS / QUIC | Недоступно в закреплённой сборке ядра | Пока не реализовано |

Ссылки NaiveProxy распознаются для импорта и конвертации, но подключение требует
ядра с `with_naive_outbound` и Cronet. Текущий клиент сообщает об ограничении,
вместо подмены NaiveProxy обычным HTTPS-прокси.

«Да» означает реализованную передачу указанных параметров закреплённому ядру;
schema tests выполняют `sing-box check`, а не подключение к VPN-серверу.
Поддержка не равна всем вариантам Xray, Hysteria или Amnezia:

- VLESS сохраняет `encryption`, заданный ALPN, явно заданный `insecure` и точный path.
  Для xHTTP с TLS/Reality без ALPN выбирается HTTP/2 (`h2`), в том числе
  при повторном подключении сохранённого профиля и проверке задержки.
  xHTTP с TLS/Reality и первым ALPN `http/1.1`, а также Reality с первым `h3`
  отклоняются: закреплённое ядро не выполняет нужный TLS-handshake в этих режимах.
  Vision без Encryption требует TCP + TLS/Reality. Глобальный multiplex
  применяется только к совместимым профилям и не отключает Vision.
  `vision-udp443`, старый XTLS, KCP/QUIC/Hysteria transport, RAW HTTP headers,
  xHTTP `extra`, ECH/PQV, WS early data и нестандартный Reality `spiderX`
  отклоняются. У выбранного fork есть неоднозначность между padding и base64
  в Encryption: несовместимые строки отклоняются до импорта, без изменения
  шифрования. Формат `none` сохраняет прежнее поведение.
- Hysteria 2 сохраняет userpass auth, IPv6, inline multi-port / `mport` / `ports`
  и фиксированный `hopInterval` в секундах (по умолчанию ядра — 30 s).
  `pinSHA256` означает отпечаток **целого сертификата**, а ядро не предоставляет
  эквивалентного поля: такие профили отклоняются, SPKI-хеш не подставляется.
  Gecko, ECH, realm и случайные интервалы нового Hysteria не поддерживаются.
- AWG поддерживает scalar J/S/H, а не полные версии 2/3.1. Активные I/J/Itime,
  неодиночные диапазоны H, Header Protection, Content Padding, новые timings,
  RandomTrailers и DisableCookies не теряются молча — импорт сообщает ошибку.
  Неактивные optional features (`0`/`off`/`false`/`0-0`) разрешены;
  H-диапазон `a-a` канонизируется в scalar `a` без изменения wire value.
  WireGuard AllowedIPs/keepalive и несколько Peer требуют отдельной typed model.

Обновление подписки с распознанными неподдерживаемыми параметрами сохраняет
прежние серверы и показывает причину на RU/EN. Полный импорт произвольных
Clash/sing-box конфигураций пока не заявляется.

Первичные спецификации: [VLESS/Xray](https://xtls.github.io/config/outbounds/vless.html),
[Hysteria URI](https://v2.hysteria.network/docs/developers/URI-Scheme/),
[Hysteria TLS и transport](https://v2.hysteria.network/docs/advanced/Full-Client-Config/),
[AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/).
Схема сверяется с исходниками Extended `a47bdbe2aefc4da0aa8dd2280fb54c429dd0bfe0`,
а не только с документацией последнего upstream.

<p align="left">
  <a href="https://honeyvpn.ru/HoneyProxyUtility.apk">
    <img src="https://img.shields.io/badge/скачать_APK-v1.2.1-brightgreen?style=for-the-badge" />
  </a>
    <img src="https://img.shields.io/badge/Android-7.0%2B-green?style=for-the-badge&logo=android" />
  <img src="https://img.shields.io/badge/лицензия-GPL--3.0-blue?style=for-the-badge" />
</p>

## Возможности

- Импорт серверов по ссылке, QR-коду или подписке
- Автообновление серверов по подписке
- Маршрутизация трафика: обход блокировок Роскомнадзора (ru-blocked, re-filter)
- Тест задержки (ping) для каждого сервера
- Встроенная бесплатная подписка: один случайный сервер при успешном обновлении.
  Удаление запоминается; вернуть сервер можно кнопкой «Добавить сервер» в каталоге HoneyVPN.
- Маркетплейс VPN-провайдеров
- TLS-фрагментация и мультиплексирование
- **AmneziaWG** — обфусцированный WireGuard с защитой от DPI (формат wg-quick INI и `awg://`)

## Скачать

Официальные сборки для Android и Windows — на странице
[Releases](https://github.com/HoneyVPN/HoneyProxyUtility/releases/latest).
Для версии 1.2.1 доступны:

- [Android 7.0+ — universal APK](https://github.com/HoneyVPN/HoneyProxyUtility/releases/download/v1.2.1/HoneyProxyUtility-v1.2.1-universal.apk).
- [Windows x64 — установщик](https://github.com/HoneyVPN/HoneyProxyUtility/releases/download/v1.2.1/HoneyProxyUtility-v1.2.1-Windows-Setup.exe).
- [SHA-256 файлов](https://github.com/HoneyVPN/HoneyProxyUtility/releases/download/v1.2.1/SHA256SUMS.txt).

Android можно добавить в [Obtainium](https://github.com/ImranR98/Obtainium),
чтобы получать обновления APK непосредственно из этого репозитория:
[добавить HoneyProxyUtility](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22ru.honeyvpn.proxy%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FHoneyVPN%2FHoneyProxyUtility%22%2C%22author%22%3A%22HoneyVPN%22%2C%22name%22%3A%22HoneyProxyUtility%22%7D).
Также доступна [конфигурация импорта](distribution/obtainium/ru.honeyvpn.proxy.json).
Obtainium загружает тот же APK с подписью HoneyVPN; это ссылка на источник
обновлений, а не подтверждение модерации в магазине.

Windows-установщик 1.2.1 пока не имеет цифровой подписи Authenticode.
Ограничения совместимости и незавершённые проверки указаны в описании релиза.

**English:** Download the official Android APK or Windows x64 installer from
[GitHub Releases](https://github.com/HoneyVPN/HoneyProxyUtility/releases/latest).
Verify downloads against the published SHA-256 checksums. Android users can
add this GitHub repository to Obtainium using the link above to receive
developer-signed APK updates. The Windows 1.2.1 installer is not yet
Authenticode-signed; see the release notes for current qualifications.

## Сборка

```bash
# Зависимости
flutter pub get

# APK (прямая раздача)
flutter build apk --flavor direct --release \
  --target-platform android-arm,android-arm64,android-x64 \
  --dart-define=FLAVOR=direct

# AAB (Google Play)
flutter build appbundle --flavor play --release \
  --dart-define=FLAVOR=play
```

Для подписания нужен файл `android/key.properties`:
```
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=../upload-keystore.jks
```

Текущая версия: **1.2.1, сборка 2130** для Android и Windows.
Android требует **Android 7.0 или новее**. Подключение проверено на TECNO с
Android 14; совместимость со всеми версиями Android этим не подтверждается.
Изолированная проверка обновления Android с публичной 1.1.21 ещё не завершена.
Сборка проверяется на **Flutter 3.41.7 / Dart 3.11.5**. Поддерживаемые Android ABI:
`armeabi-v7a`, `arm64-v8a` и `x86_64`. Для прямой раздачи собирается один
universal APK; сборка со `--split-per-abi` отклоняется. Версия Android-кода
общая для трёх ABI: `10000 + build`, то есть **12130** для этой сборки.
Файлы подписи и их резервные копии не должны попадать в Git.

## Проверки и выпуск

```bash
python3 -B scripts/prepare_android_cores.py --cache-dir build/android-core-cache --download
flutter pub get --enforce-lockfile
flutter analyze --no-fatal-infos
flutter test --reporter expanded
python3 scripts/release_metadata.py

# Проверка Android JSON ядром 1.14 той же версии (без подключения):
SINGBOX_CHECK_TARGET=android SINGBOX_CHECK_BINARY=/path/to/sing-box-1.14 \
  flutter test test/unit/connection/core_compatibility_test.dart

# Apple сохраняет отдельное ядро 1.13:
SINGBOX_APPLE_CHECK_BINARY=/path/to/sing-box-1.13 \
  flutter test test/unit/connection/apple_config_builder_test.dart

# Предпросмотр реальных UI-компонентов с локальными демонстрационными данными:
flutter run -d web-server -t test/support/design_preview.dart
```

Workflows в публичном репозитории запускаются только вручную; push и теги
не запускают сборку или публикацию. Автоматическая публикация отключена.
Quality checks можно запустить отдельно; platform build jobs сохраняют
ограничение на закрытый репозиторий. Windows использует закреплённое ядро
`v1.14.1-extended-2.7.2`; переход на типизированный DNS и политику WireGuard
проверен в частной сборке 2124. Android также использует эту версию
с типизированным DNS и явной проверкой `reserved` до запуска ядра. Проверка
конфигураций не заменяет испытание новой Android-сборки на телефоне.
Apple и обычный Linux CLI сохраняют `v1.13.12-extended-2.1.2`;
Linux-проверяющее ядро Android закреплено отдельным asset. Версия `latest`
не подставляется автоматически вместо проверенных платформенных версий.

Установщик Windows продолжает установку в 64-битный Program Files, если от
старой 32-битной версии осталась только проверенная запись, а каталог пуст
или отсутствует. Запись с небезопасными правами сохраняется с диагностикой
`HNG-39`: её права не исправляются, содержимое не удаляется и старый код не
запускается. Из-за этого в списке установленных программ может остаться
дополнительная запись старой версии. Чужой издатель, произвольная команда,
непустой старый каталог и дочерние ключи по-прежнему останавливают миграцию.

Служба Windows при старте даёт зарегистрированному владельцу приложения только
права проверки своего процесса и ожидания его завершения (`0x101000`). Это
устраняет отказ обычного пользователя при проверке процесса LocalSystem.
Права памяти, завершения процесса и изменения его защиты не предоставляются;
владелец процесса, его токен и уровень целостности сохраняются. Точная DACL
проверяется до открытия канала. Проверки образа, команды SCM и PID канала в
клиенте сохраняются; интеграционный тест вызывает только `readActive` с обычными
правами пользователя, без запуска VPN.

Все платформы и проверки читают `core-lock.json`: source revision,
версии, архивы, бинарные SHA-256 и build recipes согласованы. Платформенные
override-поля определяют эффективную версию, не меняя глобальный Apple pin.
Android включает sing-box 1.14.1 Extended 2.7.2 и tun2socks 2.7.0. Для arm64/x64
tun2socks пересобран из закреплённого upstream source с Go 1.26.8 и
64 KB/16 KB ELF alignment; ARMv7 использует закреплённые официальные архивы.
Аргументы native launcher
обновлены для его CLI. Проверка выпуска сверяет все шесть бинарников,
архитектуру, loader/dependencies, source revision, Go version и alignment.

Часть Android-бинарников sing-box превышает 100 MiB; они не хранятся в Git. Перед
сборкой они подготавливаются из закреплённых официальных архивов командой
`python3 -B scripts/prepare_android_cores.py --cache-dir build/android-core-cache --download`.
Gradle выполняет эту подготовку и проверку перед `preBuild`; CI делает её
также до проверок выпуска. Уже скачанные архивы используются после проверки
контрольных сумм. Все шесть native-бинарников проверяются до замены файлов;
при отсутствии built-cache tun2socks используется только проверенный
существующий бинарник из исходников. Рецепт tun2socks —
`scripts/build_android_tun2socks.py`; Windows/Linux schema core —
`scripts/prepare_cli_core.py`, отдельный Android checker выбирается через
`--platform linux-amd64-android-checker`. Обе стадии проверяют
контрольные суммы до замены файлов. Непроверенные новые AmneziaWG
параметры отклоняются при импорте, чтобы профиль не терял поведение:
активные I1–I5/J1–J3/Itime, неодиночные диапазоны H1–H4 и новые поля AWG 3.1
пока не представлены моделью приложения. Пустые optional поля и
Itime=0 не меняют подключение; scalar H/JC/S сохранены. WireGuard/WARP
`reserved` остаются в импортированном профиле: Android и Windows допускают
отсутствие, пустой список или ровно три нуля и не передают их ядру 1.14;
неподдерживаемые значения отклоняются явно. Apple передаёт сохранённые
`reserved` своему ядру 1.13.
Поддержка дополнительных форм требует расширения модели и проверок ядром.

## macOS и iPhone

В репозитории добавлены macOS Runner, отдельный Apple datasource и
Network Extension packet tunnel target. Apple больше не запускает Windows
`sing-box.exe`. Типизированный Libbox adapter и статическое ядро встроены
в расширение и собираются в CI. Реализованы нативные счётчики трафика и
восстановление точного profile/session ID; неизвестный активный сервер не
подменяется сохранённым выбором, недоступная скорость не выдаётся за ноль.
Обычная macOS-сборка остаётся предпросмотром, не готовым VPN-релизом.
`HoneyProxyCoreReady` в исходниках остаётся `false`.

Для локальных испытаний подготовлен отдельный signed Debug путь:
[MAC_DEVELOPMENT.md](docs/MAC_DEVELOPMENT.md). Команда
`scripts/build_apple_development.py` по умолчанию только проверяет готовность;
сборка требует явного `--build`, платной Developer team и подготовленных
development-профилей. Paid Individual подходит для локального Network Extension
теста; бесплатный Personal Team — нет. Для VPN-сервиса в App Store требуется
Organization. На этом Mac ещё не завершён первый запуск/принятие лицензии Xcode,
нет доступной Apple Development подписи и подготовленного Team/profile setup.
Регистрация, оплата и принятие лицензии не выполняются автоматически.

Apple-конфигурации проверяются той же командой `sing-box check`, но это не
заменяет испытание реального Network Extension. Ядро должно работать внутри
расширения с дескриптором системного utun, а не как root-процесс приложения.
Правила geo передаются в общий App Group; OS-статус определяет подключение.
Отдельные CI workflows проверяют unsigned host, собирают pinned universal
Libbox framework с generated headers и проверяют символы ядра в расширении.

Интерфейс использует спокойные светлую и тёмную темы, компактную боковую панель,
мобильные вкладки с иконками, поиск серверов и клавиатурные команды. Большая
кнопка закреплена над списком; выбранный сервер открывает все подписки.
Начальный запуск
сразу открывает основной экран без искусственной двухсекундной паузы.
Настоящие подписанные испытания VPN, счётчиков, IPv4/IPv6/DNS и восстановления
после сбоя ещё необходимы. План интеграции, подписи и будущего iPhone-клиента — в
[APPLE_ROADMAP.md](docs/APPLE_ROADMAP.md).

## Архитектура

- **Flutter + Riverpod** — UI и управление состоянием
- **sing-box** (libsingbox.so) — ядро VPN через JNI
- **tun2socks** — перенаправление TUN-трафика в SOCKS5
- **SharedPreferences** — хранение серверов и настроек

Логика подписок находится в `subscriptions/data/services`, независимо от UI.
Импорт и обновление используют одну политику: встроенная бесплатная подписка
содержит один стабильный узел, пользовательские подписки сохраняют все различные
подключения. Записи серверов и настроек сохраняются последовательно, чтобы
параллельные операции не перезаписывали друг друга.

Android исключает сохранённые конфигурации из стандартного backup; это не
заменяет шифрование локального хранилища.

## Лицензия

GPL-3.0 — см. [LICENSE](LICENSE).

Встроенная библиотека sing-box распространяется под [GPL-3.0](https://github.com/SagerNet/sing-box/blob/dev-next/LICENSE).
