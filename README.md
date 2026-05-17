# HoneyProxyUtility

Универсальный VPN-клиент для Android на базе [sing-box](https://github.com/SagerNet/sing-box).

Поддерживаемые протоколы: **VLESS Reality**, **VLESS xHTTP**, **VMess**, **Trojan**, **Shadowsocks**, **Hysteria2**, **TUIC**, **WireGuard**, **NaiveProxy**, **ShadowTLS**.

<p align="left">
  <a href="https://honeyvpn.ru/HoneyProxyUtility.apk">
    <img src="https://img.shields.io/badge/APK-v1.1.3-brightgreen?style=for-the-badge&logo=android" />
  </a>
  <img src="https://img.shields.io/badge/Android-5.0%2B-green?style=for-the-badge&logo=android" />
  <img src="https://img.shields.io/badge/лицензия-GPL--3.0-blue?style=for-the-badge" />
</p>

## Возможности

- Импорт серверов по ссылке, QR-коду или подписке
- Автообновление серверов по подписке
- Маршрутизация трафика: обход блокировок Роскомнадзора (ru-blocked, re-filter)
- Тест задержки (ping) для каждого сервера
- Встроенная бесплатная подписка
- Маркетплейс VPN-провайдеров
- TLS-фрагментация и мультиплексирование

## Скачать

Актуальный APK — на странице [Releases](https://github.com/HoneyVPN/HoneyProxyUtility/releases/latest).

## Сборка

```bash
# Зависимости
flutter pub get

# APK (прямая раздача)
flutter build apk --flavor direct --release \
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

## Архитектура

- **Flutter + Riverpod** — UI и управление состоянием
- **sing-box** (libsingbox.so) — ядро VPN через JNI
- **tun2socks** — перенаправление TUN-трафика в SOCKS5
- **SharedPreferences** — хранение серверов и настроек

## Лицензия

GPL-3.0 — см. [LICENSE](LICENSE).

Встроенная библиотека sing-box распространяется под [GPL-3.0](https://github.com/SagerNet/sing-box/blob/dev-next/LICENSE).
