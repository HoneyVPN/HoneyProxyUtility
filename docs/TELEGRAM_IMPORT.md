# Импорт из Telegram в HoneyProxyUtility

Существующая кнопка Honey уже создаёт правильную ссылку `honeyvpn://import`.
Новые обработчики приложения на Windows и Mac устраняют основной пробел;
менять действующий бот для этого не требуется. Подготовленная здесь страница —
отдельный шаблон для последующего улучшения интерфейса и передачи ссылки.
Она не развёрнута, бот и сайт этой работой не изменяются.

## Действующий маршрут

В проверенном серверном коде `/opt/honeyvpn-bot/bot/main.py` обработчик
`honey_open` принимает `/app/honey-open?sub=<short_uuid>`, собирает полный
адрес подписки из `SUB_URL` и создаёт:

```text
honeyvpn://import?url=<quote(full_subscription_url, safe="")>
```

Существующий `openHoneyWebApp()` вызывает
`tg.openLink(window.location.origin + '/app/honey-open?sub=' + last_segment)`.
Страница пытается открыть приложение автоматически и предлагает ручной переход.
Её запасная установка ведёт только на Android APK —
`https://honeyvpn.ru/HoneyProxyUtility.apk`. Этот маршрут не является ссылкой
на установку Windows/Mac и не подтверждает доступность нового публичного кандидата.
`sub` в этом действующем HTTP query остаётся идентификатором запроса к серверу.

## Контракт приложения

```text
honeyvpn://import?url=<percent-encoded complete source>
```

`source` — полная ссылка подписки или URI отдельного сервера. Закодировать
нужно всю строку ровно один раз как значение query-параметра; не весь envelope.
Существующие `%2F`, `+`, `&`, `?`, `#`, Unicode и нестандартные порты сохраняются.
Например, исходный `%2F` становится `%252F` во внешней ссылке, а `+` — `%2B`.
После одного декодирования приложение получает первоначальную строку.

```python
from urllib.parse import quote

app_link = "honeyvpn://import?url=" + quote(source, safe="")
```

```javascript
const appLink = 'honeyvpn://import?url=' + encodeURIComponent(source);
```

Импорт открывает preview, загружает/разбирает подписку и требует отдельного
нажатия «Добавить». Ссылка не сохраняет подписку и не включает VPN автоматически.
Холодный запуск, уже открытое приложение и повторная ссылка используют один
канал доставки; их проверка на реальных клиентах Telegram остаётся частью QA.
Mac сейчас содержит тестовый интерфейс; рабочий Apple VPN требует завершения
подписи и испытаний. iPhone Runner пока отсутствует: URI — будущий контракт,
а не доступное приложение для iPhone.

## Кнопка бота и новый необязательный шаблон

[Telegram Bot API](https://core.telegram.org/bots/api#inlinekeyboardbutton)
документирует HTTP и `tg://` для `InlineKeyboardButton.url`. Прямой
`honeyvpn://` в этом поле не является поддерживаемым контрактом.
Действующая Honey HTTPS-страница уже решает эту часть. В Mini App
[openLink](https://core.telegram.org/bots/webapps#initializing-mini-apps)
вызывается по нажатию и открывает HTTPS-страницу во внешнем браузере.

Новый статический шаблон находится в `tool/telegram_import_bridge/`.
Он получает source только из фрагмента:

```text
https://<OWN_HOST>/import/#url=<percent-encoded complete source>
```

`<OWN_HOST>` — явно незаполненный домен владельца, не развёрнутый endpoint.
Путь `/import/` тоже пример. Сохраняйте завершающий `/` при размещении папкой,
чтобы её относительные CSS/JS/SVG адреса разрешались внутри этой папки.
Другой путь допустим при сохранении такого же размещения ресурсов.

После фактического размещения формируется обычная URL-кнопка:

```javascript
// importPageUrl: подтверждённый владельцем HTTPS URL, без query/fragment.
const button = {
  text: 'Добавить в HoneyProxyUtility',
  url: importPageUrl + '#url=' + encodeURIComponent(source),
};
const replyMarkup = { inline_keyboard: [[button]] };
```

У URL-кнопки не должно быть одновременно `callback_data` или `web_app`.
Публиковать этот код в работающем боте можно после отдельного решения владельца.
Новый шаблон не принимает старый query `?sub=...` и не является прямой заменой
legacy endpoint без адаптации. Существующие кнопки сохраняют свой маршрут.

Фрагмент отделяется до HTTP обращения
([RFC 3986 §3.5](https://www.rfc-editor.org/rfc/rfc3986#section-3.5)).
Новая страница не загружает подписку: сервер получает только путь страницы и
её статических ресурсов. Source остаётся в памяти страницы, не показывается
в тексте и после разбора убирается из адресной строки через History API.
Это не шифрование: исходную ссылку всё ещё получают бот и браузер пользователя.

Кнопка «Открыть в HoneyProxyUtility» появляется только для валидного source и
открывает фиксированный import URI по явному нажатию. Запасное «Скопировать ссылку»
копирует исходную строку для ручного импорта. Если Clipboard API недоступен,
используется временное невидимое поле, которое очищается и удаляется сразу.
Ошибки не показывают source. На iPhone/iPad открытие скрыто; копирование остаётся.
На Mac явно указан статус тестовой версии и недоступность обычного VPN.
Ссылки на установщики здесь не придуманы: добавлять следует только фактически
опубликованные версии соответствующей платформы, после проверки владельцем.

## Размещение и проверки

Копировать нужно пять runtime файлов: `index.html`, `bridge.css`, `bridge.mjs`,
`import_contract.mjs`, `honey-shield.svg`. Страница не требует npm пакетов,
Telegram SDK, аналитики, CDN, внешних шрифтов или серверного кода.
Для `.mjs` сервер должен отдавать JavaScript MIME type, например `text/javascript`.
Для HTML выставить следующие HTTP headers, сохранив встроенные meta-политики:

```text
Referrer-Policy: no-referrer
Cache-Control: no-store
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors 'none'; worker-src 'none'; media-src 'none'; manifest-src 'none'
```

`frame-ancestors` требует HTTP header и не применяется из HTML meta.
Не встраивать в эту страницу аналитику/сторонние скрипты и не передавать source
в query, серверный шаблон, журнал или сторонний shortener.

```sh
node --test tool/telegram_import_bridge/import_contract.test.mjs
python3 -m http.server 8099 --bind 127.0.0.1 --directory tool/telegram_import_bridge
```

Для локальной проверки открыть только синтетический пример:

```text
http://127.0.0.1:8099/#url=https%3A%2F%2Fsub.example.com%2Fconfig
```

Тесты проверяют сохранение вложенного URL, UTF-8 лимиты, malformed encoding,
дубли и query, отсутствие открытия/копирования при загрузке, explicit actions,
неотображение токенов, удаление временного поля и ограничения Mac/iPhone.
HTTP-fixture на loopback проверяет, что запрос страницы и same-origin ресурсов
не содержит fragment/source. Проверяется контраст обычного текста в обеих темах.
Это не тест запуска внешнего приложения из Telegram на физическом устройстве.

Лимиты согласованы с приложением: outer URI до 65536 UTF-8 bytes, source до
16384 bytes; ASCII controls и malformed percent escapes запрещены.
Шаблон принимает только HTTPS-подписки, хотя приложение сохраняет legacy HTTP
совместимость. Proxy prefixes: `vless`, `vmess`, `trojan`, `ss`, `hy2`, `hysteria2`,
`tuic`, `wireguard`, `awg`, `vpn`, `naive`, `naive+https`, `naive+quic`, `shadowtls`.
Детальные параметры проверяет parser приложения; принятие ссылки не обещает
VPN-поддержку всех протоколов. `happ://crypt*` не является форматом Honey.
Очень длинные ссылки могут упираться в лимиты конкретного клиента/OS;
копирование остаётся запасным путём. Реальное Telegram cold/warm opening,
нет установленного приложения, cancel external-app prompt, clipboard и языки
нужно проверить на Android/Windows/Mac до публикации новой страницы.

## Verified HTTPS links в будущем

Для прямого HTTPS открытия приложения нужны отдельно настроенные платформенные
ассоциации. На Android — HTTPS intent filter с `autoVerify`, hosted
`.well-known/assetlinks.json`, package name и fingerprint фактической подписи
([Android App Links](https://developer.android.com/training/app-links/about)).
Существующий фильтр `honeyvpn` сам по себе не является verified HTTPS App Link.

На Apple — Associated Domains capability, `applinks:<OWN_HOST>`, hosted
`.well-known/apple-app-site-association`, соответствующие app identifiers и
обработчики Universal Links
([Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)).
Нельзя переносить signed-domain обещание на отсутствующий iPhone Runner.
Для Windows текущий Win32 installer регистрирует собственный URI protocol;
это отдельный механизм от Android/Apple HTTPS associations
([Microsoft URI registration](https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa767914(v=vs.85))).

Официальная [документация Happ](https://www.happ.su/main/faq/adding-configuration-subscription)
подтверждает импорт подписок через deep link, clipboard и QR.
Его [crypto links](https://www.happ.su/main/dev-docs/crypto-link) — отдельный формат
Happ. Для кнопки Honey не нужен вызов Happ crypto API или передача туда подписки.
