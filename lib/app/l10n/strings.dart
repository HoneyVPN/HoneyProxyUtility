import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/presentation/notifiers/settings_notifier.dart';
import 'supported_locale.dart';
import '../../features/subscriptions/domain/entities/provider_geo_state.dart';

final stringsProvider = Provider<S>((ref) {
  final systemLocale = ref.watch(systemLocaleProvider);
  final locale = ref.watch(
    settingsProvider.select((s) => s.value?.locale ?? systemLocale),
  );
  return S(locale);
});

class S {
  final String locale;
  const S(this.locale);
  bool get _ru => locale == 'ru';

  // ── Connect button ──────────────────────────────────────────────────────────
  String get connect => _ru ? 'Подключить' : 'Connect';
  String get disconnect => _ru ? 'Отключить' : 'Disconnect';
  String get connecting => _ru ? 'Подключение…' : 'Connecting…';
  String get disconnecting => _ru ? 'Отключение…' : 'Disconnecting…';
  String get preparing => _ru ? 'Подготовка…' : 'Preparing…';
  String get retry => _ru ? 'Повторить' : 'Retry';

  // ── Connection status labels ────────────────────────────────────────────────
  String get statusConnected => _ru ? 'Подключено' : 'Connected';
  String get statusConnecting => _ru ? 'Подключение…' : 'Connecting…';
  String get statusPreparing => _ru ? 'Подготовка…' : 'Preparing…';
  String get statusDisconnecting => _ru ? 'Отключение…' : 'Disconnecting…';
  String get statusError => _ru ? 'Ошибка' : 'Error';
  String get statusDisconnected => _ru ? 'Отключено' : 'Disconnected';
  String protocolUnavailable(String protocol) => _ru
      ? '$protocol недоступен в этой версии. Выберите другой протокол.'
      : '$protocol is unavailable in this release. Choose another protocol.';
  String get appleVpnUnavailable => _ru
      ? 'VPN для Apple ещё не готов к подключению: требуется сборка с подписанным сетевым расширением.'
      : 'Apple VPN is not ready to connect yet. A build with a signed network extension is required.';
  String get appleProxyUnavailable => _ru
      ? 'На Apple доступен режим VPN-туннеля. Выберите его в настройках.'
      : 'Apple supports VPN Tunnel mode. Select it in Settings.';
  String get unsupportedPlatform => _ru
      ? 'VPN на этой платформе пока недоступен.'
      : 'VPN is not available on this platform yet.';
  String get vpnPermissionDenied => _ru
      ? 'Доступ к VPN не разрешён. Разрешите добавление VPN в системном запросе.'
      : 'VPN permission was denied. Allow the VPN configuration in the system prompt.';

  // ── Home screen ─────────────────────────────────────────────────────────────
  String get subscriptionsTooltip => _ru ? 'Подписки' : 'Subscriptions';
  String get refreshSubsTooltip =>
      _ru ? 'Обновить подписки' : 'Refresh subscriptions';
  String get pingAllTooltip => _ru ? 'Проверить задержку' : 'Check latency';
  String get cancelLatencyTest => _ru ? 'Остановить проверку' : 'Stop checking';
  String latencyProgress(int completed, int total) =>
      _ru ? 'Проверка: $completed из $total' : 'Checking: $completed of $total';
  String get importServerTooltip => _ru ? 'Импорт сервера' : 'Import server';

  String get noServerSelected => _ru
      ? 'Сервер не выбран — нажмите + для добавления'
      : 'No server selected — tap + to add';
  String get manualGroup => _ru ? 'Вручную' : 'Manual';

  String deleteGroupTitle(String label) =>
      _ru ? 'Удалить "$label"?' : 'Delete "$label"?';
  String deleteGroupContent(int count, bool hasSub) => _ru
      ? 'Удалить $count ${_serverCountNoun(count)}${hasSub ? ' и подписку' : ''}?'
      : 'Remove $count server${count == 1 ? '' : 's'}${hasSub ? ' and the subscription' : ''}?';

  String _serverCountNoun(int count) {
    final lastHundred = count.abs() % 100;
    if (lastHundred >= 11 && lastHundred <= 14) return 'серверов';
    return switch (count.abs() % 10) {
      1 => 'сервер',
      2 || 3 || 4 => 'сервера',
      _ => 'серверов',
    };
  }

  String get cancelButton => _ru ? 'Отмена' : 'Cancel';
  String get deleteButton => _ru ? 'Удалить' : 'Delete';
  String get deleteServerTitle => _ru ? 'Удалить сервер?' : 'Delete server?';
  String deleteServerContent(String name) =>
      _ru ? 'Удалить "$name"?' : 'Remove "$name"?';

  String get noServersYet => _ru ? 'Серверов нет' : 'No servers yet';
  String get noServersSubtitle => _ru
      ? 'Импортируйте ссылку прокси или URL подписки'
      : 'Import a proxy link or subscription URL';
  String get importServerButton => _ru ? 'Импорт сервера' : 'Import Server';

  String get homeTitle => _ru ? 'Подключение' : 'Connection';
  String get marketTitle => _ru ? 'Каталог' : 'Providers';
  String get navigationSection => _ru ? 'Навигация' : 'Navigation';
  String get showSidebar => _ru ? 'Показать боковую панель' : 'Show sidebar';
  String get hideSidebar =>
      _ru ? 'Свернуть боковую панель' : 'Collapse sidebar';
  String get serversTitle => _ru ? 'Серверы' : 'Servers';
  String get chooseServer => _ru ? 'Выбрать сервер' : 'Choose server';
  String get activeServerUnknown =>
      _ru ? 'Активный сервер неизвестен' : 'Active server unknown';
  String get statsUnavailable => _ru ? 'Недоступно' : 'Unavailable';
  String get closeButton => _ru ? 'Закрыть' : 'Close';
  String get serverSelectionLocked => _ru
      ? 'Дождитесь завершения подключения или отключения, чтобы сменить сервер.'
      : 'Wait for the connection transition to finish before changing servers.';
  String get searchServersHint => _ru ? 'Поиск серверов' : 'Search servers';
  String get clearSearch => _ru ? 'Очистить поиск' : 'Clear search';
  String get noServerMatches =>
      _ru ? 'Серверы не найдены' : 'No matching servers';
  String get searchServersHelp => _ru
      ? 'Попробуйте страну, протокол или название подписки.'
      : 'Try a country, protocol or subscription name.';
  String get serverDetails => _ru ? 'Свойства сервера' : 'Server details';
  String get serverActions => _ru ? 'Действия с сервером' : 'Server actions';
  String get favoritesTitle => _ru ? 'Избранное' : 'Favorites';
  String get favoriteServer => _ru ? 'Избранный сервер' : 'Favorite server';
  String get addToFavorites => _ru ? 'В избранное' : 'Add to favorites';
  String get removeFromFavorites =>
      _ru ? 'Убрать из избранного' : 'Remove from favorites';
  String get favoriteUpdateFailed =>
      _ru ? 'Не удалось сохранить избранное.' : 'Could not save favorites.';
  String get favoriteServerChanged => _ru
      ? 'Список серверов изменился. Повторите действие.'
      : 'The server list changed. Try again.';
  String get pingServer => _ru ? 'Проверить задержку' : 'Check latency';
  String get connectShortcut => _ru
      ? 'Подключить или отключить (⌘Enter / Ctrl+Enter)'
      : 'Connect or disconnect (⌘Enter / Ctrl+Enter)';
  String get appleTunnelMode => _ru ? 'VPN-туннель' : 'VPN Tunnel';
  String get appleProxyModeSaved => _ru
      ? 'Режим прокси недоступен. Переключите на VPN.'
      : 'Proxy mode is unavailable. Switch to VPN.';
  String get useVpnTunnel => _ru ? 'Использовать VPN' : 'Use VPN Tunnel';
  String get allowLanAppleUnavailable =>
      _ru ? 'Недоступно на Mac и iPhone.' : 'Unavailable on Mac and iPhone.';
  String get versionUnavailable =>
      _ru ? 'Версия недоступна' : 'Version unavailable';
  String get loading => _ru ? 'Загрузка…' : 'Loading…';
  String get serversLoadFailed => _ru
      ? 'Не удалось загрузить серверы. Откройте приложение ещё раз.'
      : 'Could not load your servers. Reopen the app and try again.';
  String get subscriptionsLoadFailed => _ru
      ? 'Не удалось загрузить подписки. Откройте приложение ещё раз.'
      : 'Could not load your subscriptions. Reopen the app and try again.';
  String get getStarted => _ru ? 'Начать' : 'Get started';
  String get systemTunStack => _ru ? 'Системный' : 'System';
  String get mixedTunStack => _ru ? 'Смешанный' : 'Mixed';
  String get genericServer => _ru ? 'сервер' : 'server';
  String connectionLogConnecting(String server, String protocol) => _ru
      ? 'Подключение к $server [$protocol]'
      : 'Connecting to $server [$protocol]';
  String connectionLogConnected(String server) =>
      _ru ? 'Подключено к $server' : 'Connected to $server';
  String get connectionLogDisconnected => _ru ? 'Отключено' : 'Disconnected';

  // ── Settings ────────────────────────────────────────────────────────────────
  String navigationShortcut(String shortcut) =>
      _ru ? 'Сочетание клавиш: $shortcut' : 'Keyboard shortcut: $shortcut';
  String connectionModeLabel(String mode) => mode == 'proxy'
      ? (_ru ? 'Системный прокси' : 'System Proxy')
      : (_ru ? 'VPN-туннель' : 'VPN Tunnel');
  String connectionModeShortLabel(String mode) => mode == 'proxy'
      ? (_ru ? 'Прокси' : 'Proxy')
      : (_ru ? 'Туннель' : 'Tunnel');
  String connectionModeDescription(String mode, int socksPort, int httpPort) =>
      mode == 'proxy'
      ? 'SOCKS5 127.0.0.1:$socksPort · HTTP 127.0.0.1:$httpPort'
      : (_ru
            ? 'VPN-туннель для приложений устройства'
            : 'VPN Tunnel for apps on this device');
  String routingModeLabel(String mode) => switch (mode) {
    'global' => _ru ? 'Весь трафик' : 'All traffic',
    'bypassRU' => _ru ? 'Россия напрямую' : 'Russia directly',
    _ => _ru ? 'Встроенные правила' : 'Built-in rules',
  };
  String routingModeDescription(String mode) => switch (mode) {
    'global' =>
      _ru
          ? 'Трафик через прокси; локальные адреса — напрямую.'
          : 'Traffic through proxy; local addresses connect directly.',
    'bypassRU' =>
      _ru
          ? 'Российские IPv4-адреса напрямую; заблокированные ресурсы и прочий трафик — через прокси.'
          : 'Russian IPv4 addresses connect directly; blocked resources and other traffic use the proxy.',
    _ =>
      _ru
          ? 'Автоматический обход блокировок по встроенным правилам.'
          : 'Automatic bypass using built-in rules.',
  };
  String get routingScreenTitle => _ru ? 'Маршрутизация' : 'Routing';
  String get geoRoutingTitle => _ru ? 'Геоданные' : 'Geo data';
  String get geoRoutingBuiltIn => _ru ? 'Встроенные' : 'Built-in';
  String get geoRoutingProvider => _ru ? 'Провайдера' : 'Provider';
  String get geoRoutingCombined =>
      _ru ? 'Встроенные и провайдера' : 'Built-in and provider';
  String get geoRoutingPriority => _ru
      ? 'Блокировки и прокси провайдера имеют приоритет. Встроенные блокировки важнее прямых правил провайдера.'
      : 'Provider block and proxy rules take priority. Built-in blocked sites override provider direct rules.';
  String get geoRoutingBuiltInDescription => _ru
      ? 'Встроенные правила поставляются с приложением. Их новая версия приходит с обновлением Honey.'
      : 'Built-in rules are bundled with the app. New versions arrive with Honey updates.';
  String get geoRoutingOptional => _ru
      ? 'Если провайдер задаёт геоданные, Honey проверяет их при обновлении подписки. Правила действуют для серверов этой подписки.'
      : 'When a provider supplies geo data, Honey checks it during subscription updates. The rules apply to that subscription’s servers.';
  String get geoRoutingGlobal => _ru
      ? 'В режиме «Всё через прокси» геоправила не используются.'
      : 'Geo rules are unused when all traffic uses the proxy.';
  String get providerGeoReady =>
      _ru ? 'Геоданные проверены' : 'Geo data verified';
  String providerGeoWarning(
    ProviderGeoIssue? issue, {
    required bool hasLastGood,
  }) {
    if (issue == null)
      return hasLastGood ? providerGeoRefreshFailed : providerGeoUnavailable;
    final failure = providerGeoFailure(issue);
    if (!hasLastGood) return failure;
    return '$failure ${_ru ? 'Сохранены последние проверенные правила.' : 'Last verified rules are preserved.'}';
  }

  String get providerGeoRefreshFailed => _ru
      ? 'Не удалось обновить геоданные. Сохранены последние проверенные правила.'
      : 'Geo data update failed. Last verified rules are preserved.';
  String get providerGeoUpdating =>
      _ru ? 'Обновление геоданных…' : 'Updating geo data…';
  String get providerGeoUnavailable => _ru
      ? 'Геоданные этой подписки недоступны. Обновите подписку и повторите попытку.'
      : 'Geo data for this subscription is unavailable. Refresh the subscription and try again.';
  String get providerGeoOff => _ru
      ? 'Провайдер отключил свои правила.'
      : 'The provider disabled its rules.';
  String providerGeoFailure(ProviderGeoIssue issue) => switch (issue) {
    ProviderGeoIssue.absent => providerGeoUnavailable,
    ProviderGeoIssue.off => providerGeoOff,
    ProviderGeoIssue.download =>
      _ru ? 'Не удалось загрузить геоданные.' : 'Could not download geo data.',
    ProviderGeoIssue.invalid =>
      _ru
          ? 'Правила провайдера не удалось проверить.'
          : 'Provider rules could not be validated.',
    ProviderGeoIssue.tooLarge =>
      _ru
          ? 'Набор геоданных превышает поддерживаемый размер.'
          : 'The geo data set exceeds the supported size.',
    ProviderGeoIssue.cache =>
      _ru
          ? 'Сохранённые геоданные не прошли проверку. Обновите подписку.'
          : 'Saved geo data failed validation. Refresh the subscription.',
  };

  String get routingHelp => _ru
      ? 'Выберите, какой трафик передавать через прокси и какой подключать напрямую.'
      : 'Choose which traffic uses the proxy and which connects directly.';
  String dnsPresetLabel(String preset) => switch (preset) {
    'cloudflare' => 'Cloudflare',
    'google' => 'Google',
    'adguard' => 'AdGuard',
    _ => _ru ? 'Свой DNS' : 'Custom DNS',
  };
  String get customDnsNotSet =>
      _ru ? 'Свой DNS не настроен' : 'Custom DNS is not configured';

  String get saveButton => _ru ? 'Сохранить' : 'Save';
  String get customDnsAddress => _ru ? 'Адрес DNS-сервера' : 'DNS server URL';
  String get dnsHelp => _ru
      ? 'Выбранный DNS используется для запросов через прокси.'
      : 'The selected DNS server resolves queries through the proxy.';
  String get connectionSettingsApplyNext => _ru
      ? 'Сетевые настройки применяются при следующем подключении.'
      : 'Connection settings apply on your next connection.';
  String get invalidDnsAddress => _ru
      ? 'Укажите адрес https:// или tls:// с именем сервера.'
      : 'Enter an https:// or tls:// address with a server name.';
  String get customDnsPortUnsupported => _ru
      ? 'Порт DNS должен быть от 1 до 65535.'
      : 'The DNS port must be between 1 and 65535.';
  String get customDnsExtrasUnsupported => _ru
      ? 'Параметры, фрагменты и авторизация в адресе не поддерживаются.'
      : 'URL parameters, fragments and authentication are unsupported.';
  String get customDnsTlsPathUnsupported => _ru
      ? 'Для TLS укажите только сервер, например tls://dns.example.'
      : 'For TLS, enter only the server, such as tls://dns.example.';
  String get savingSettings => _ru ? 'Сохранение…' : 'Saving…';
  String get settingsSaveFailed => _ru
      ? 'Не удалось сохранить. Попробуйте ещё раз.'
      : 'Could not save. Please try again.';

  String get settingsTitle => _ru ? 'Настройки' : 'Settings';
  String get appearanceSection => _ru ? 'Общие' : 'General';
  String get themeTitle => _ru ? 'Тема' : 'Theme';
  String get themeSystem => _ru ? 'Системная' : 'System';
  String get themeLight => _ru ? 'Светлая' : 'Light';
  String get themeDark => _ru ? 'Тёмная' : 'Dark';
  String get languageTitle => _ru ? 'Язык' : 'Language';

  String get connectionSection => _ru ? 'Подключение' : 'Connection';
  String get modeTitle => _ru ? 'Режим' : 'Mode';
  String get routingTitle => _ru ? 'Маршрутизация' : 'Routing';
  String get dnsTitle => 'DNS';
  String get splitTunnelTitle =>
      _ru ? 'Раздельное туннелирование' : 'Split Tunneling';
  String get splitTunnelSubtitle => _ru
      ? 'Настройка VPN по приложениям пока недоступна. Используйте правила маршрутизации.'
      : 'Per-app VPN settings are unavailable in this release. Use routing rules.';
  String get ipTypeBothLabel => _ru ? 'Оба' : 'Both';
  String get preferredIpTitle => _ru ? 'Версия IP' : 'IP version';
  String preferredIpSubtitle(String type) =>
      _ru ? 'Адреса для доменных имён.' : 'Addresses for domain names.';
  String get fragmentationTitle =>
      _ru ? 'Фрагментация TLS' : 'TLS fragmentation';
  String get fragmentationSubtitle => _ru
      ? 'Разделять TLS ClientHello в TCP-соединениях.'
      : 'Fragment TLS ClientHello over TCP.';
  String get multiplexerTitle => _ru ? 'Мультиплексирование' : 'Multiplexing';
  String get multiplexerSubtitle => _ru
      ? 'Объединять потоки, если протокол и сервер поддерживают это.'
      : 'Combine streams when supported by the protocol and server.';
  String get allowLanTitle =>
      _ru ? 'Доступ из локальной сети' : 'Local network access';
  String get allowLanSubtitle => _ru
      ? 'Разрешать другим устройствам использовать прокси.'
      : 'Let other devices use this proxy.';

  String get fakeipTitle => _ru ? 'Fake IP' : 'Fake IP';
  String get fakeipSubtitle => _ru
      ? 'Fake IP в этой версии недоступен. DNS возвращает реальные адреса.'
      : 'Fake IP is unavailable in this release. DNS returns real addresses.';
  String get tunStackTitle => _ru ? 'TUN стек' : 'TUN Stack';
  String tunStackSubtitle(String stack) =>
      _ru ? 'Сетевой стек: $stack' : 'Network stack: $stack';
  String get tunStackUnavailable => _ru
      ? 'На этой платформе выбор VPN-стека недоступен.'
      : 'VPN stack selection is unavailable on this platform.';
  String get tunStackTunnelOnly => _ru
      ? 'Выбор стека доступен в режиме VPN-туннеля на Windows.'
      : 'Stack selection is available in Windows VPN Tunnel mode.';
  String get logLevelTitle => _ru ? 'Диагностика ядра' : 'Core diagnostics';
  String get coreLogLevelSubtitle => _ru
      ? 'Уровень записей в системном журнале VPN.'
      : 'Detail level for the system VPN log.';
  String get portsTitle => _ru ? 'Порты прокси' : 'Proxy Ports';
  String get invalidPorts => _ru
      ? 'Укажите разные порты от 1 до 65535. Порт 9090 занят приложением.'
      : 'Use different ports from 1 to 65535. Port 9090 is reserved.';

  String logLevelLabel(String level) => switch (level) {
    'trace' => _ru ? 'Подробно' : 'Trace',
    'debug' => _ru ? 'Отладка' : 'Debug',
    'info' => _ru ? 'Информация' : 'Info',
    'warn' => _ru ? 'Предупреждения' : 'Warnings',
    _ => _ru ? 'Ошибки' : 'Errors',
  };

  String get advancedSection => _ru ? 'Дополнительно' : 'Advanced';
  String get logsTitle => _ru ? 'Журнал' : 'Logs';
  String get logsSubtitle => _ru
      ? 'Журнал подключений в реальном времени'
      : 'Real-time connection log';
  String get urlSchemesTitle => _ru ? 'Ссылки для импорта' : 'Import links';
  String get urlSchemesSubtitle =>
      _ru ? 'honeyvpn://import' : 'honeyvpn://import';
  String get importLinkInvalid => _ru
      ? 'Не удалось открыть ссылку импорта. Проверьте её формат.'
      : 'Could not open the import link. Check its format.';
  String get importLinkTooLong => _ru
      ? 'Ссылка слишком длинная. Вставьте конфигурацию в разделе «Импорт».'
      : 'The link is too long. Paste the configuration in Import.';
  String get importLinkUnsupported => _ru
      ? 'Используйте ссылку подписки или сервера.'
      : 'Use a subscription or server link.';
  String get importLinkUnavailable => _ru
      ? 'Не удалось получить ссылку. Вставьте её в разделе «Импорт».'
      : 'Could not receive the link. Paste it in Import.';
  String get aboutSection => _ru ? 'О приложении' : 'About';
  String get developerCreditCaption =>
      _ru ? 'Приложение разработал' : 'Developed by';

  // ── URL Schemes screen ──────────────────────────────────────────────────────
  String get urlSchemesScreenTitle => _ru ? 'URL-схемы' : 'URL Schemes';
  String get urlSchemesVpnSection => _ru ? 'Управление VPN' : 'VPN Control';
  String get urlSchemesWebSection =>
      _ru ? 'Веб-эквиваленты' : 'Web Equivalents';
  String get urlSchemesForProviders =>
      _ru ? 'Для VPN-провайдеров' : 'For VPN Providers';
  String get urlSchemesProviderHint => _ru
      ? 'Используйте эти схемы в своих приложениях для управления HoneyProxyUtility через диплинки.'
      : 'Use these schemes in your apps to control HoneyProxyUtility via deep links.';
  String get copied => _ru ? 'Скопировано' : 'Copied';
  String get copyFailed => _ru
      ? 'Не удалось скопировать. Попробуйте ещё раз.'
      : 'Could not copy. Please try again.';

  // ── Subscriptions screen ────────────────────────────────────────────────────
  String get subscriptionsScreenTitle => _ru ? 'Подписки' : 'Subscriptions';
  String get addSubscriptionHint =>
      _ru ? 'Добавить URL подписки' : 'Add subscription URL';
  String get addButton => _ru ? 'Добавить' : 'Add';
  String get refreshing => _ru ? 'Обновление…' : 'Refreshing…';
  String get subscriptionUnsupported => _ru
      ? 'Подписка содержит неподдерживаемые параметры.'
      : 'The subscription contains unsupported parameters.';
  String get subscriptionInvalidResponse => _ru
      ? 'В ответе нет подходящих профилей.'
      : 'The response contains no usable profiles.';
  String get subscriptionUpdateFailed => _ru
      ? 'Не удалось обновить подписку. Повторите попытку.'
      : 'Could not update the subscription. Please retry.';
  String get subscriptionRefreshFailureTooltip => _ru
      ? 'Не удалось обновить подписку'
      : 'Could not update the subscription';
  String get subscriptionServersPreserved =>
      _ru ? 'Сохранённые серверы не изменены.' : 'Saved servers are unchanged.';

  // ── VPN Disclosure dialog (Google Play VpnService policy) ──────────────────
  String get vpnDisclosureTitle => _ru ? 'Использование VPN' : 'VPN Usage';
  String get vpnDisclosureBody => _ru
      ? 'HoneyProxyUtility создаёт VPN-туннель для подключения к выбранному вами серверу.\n\n'
            '• Приложение обрабатывает сетевой трафик и DNS-запросы по вашим правилам маршрутизации. Соответствующий трафик и сетевые метаданные получает выбранный VPN- или DNS-провайдер; действуют его правила конфиденциальности.\n'
            '• Серверы, ссылки подписок и настройки хранятся на устройстве. Обновления подписок и геоданных обращаются к их источникам.\n'
            '• Технический журнал хранится локально. Отчёт с версией приложения, состоянием VPN и настройками можно отправить в поддержку Honey вручную. Автоматическая отправка при ошибках включается только с вашего отдельного согласия и отключается в настройках.'
      : 'HoneyProxyUtility creates a VPN tunnel to connect to the server you select.\n\n'
            '• The app processes network traffic and DNS requests according to your routing rules. Your selected VPN or DNS provider receives the corresponding traffic and connection metadata; its privacy rules apply.\n'
            '• Servers, subscription URLs and settings are stored on your device. Subscription and geo data updates contact their sources.\n'
            '• Technical logs stay on your device. You can send a report with the app version, VPN state and settings to Honey support manually. Automatic error reporting requires your separate consent and can be turned off in Settings.';
  String get vpnDisclosurePrivacyLink =>
      _ru ? 'Политика конфиденциальности' : 'Privacy Policy';
  String get vpnDisclosureAccept =>
      _ru ? 'Принять и продолжить' : 'Accept & Continue';
  String get vpnDisclosureDecline => _ru ? 'Отмена' : 'Cancel';
  String get playEncryptedTunnelRequired => _ru
      ? 'Для Google Play требуется шифрование между устройством и VPN-сервером. Выберите профиль с TLS, REALITY или другим поддерживаемым шифрованием.'
      : 'Google Play requires encryption between your device and the VPN server. Choose a profile with TLS, REALITY or another supported encryption method.';

  // ── Import / Converter screen ───────────────────────────────────────────────
  String get importScreenTitle => _ru ? 'Импорт' : 'Import';
  String get importInputLabel =>
      _ru ? 'Ссылка или конфигурация' : 'Link or configuration';
  String get importHint => _ru
      ? 'Вставьте ссылку на подписку, сервер или текст конфигурации'
      : 'Paste a subscription link, server link or configuration';
  String get importPasteButton => _ru ? 'Вставить' : 'Paste';
  String get importScanButton => _ru ? 'Сканировать QR' : 'Scan QR';
  String get importClearButton => _ru ? 'Очистить поле' : 'Clear input';
  String get importLoading => _ru ? 'Загрузка…' : 'Loading…';
  String get parseButton => _ru ? 'Продолжить' : 'Continue';
  String get importRecheckButton => _ru ? 'Проверить снова' : 'Check again';
  String get importAllButton => _ru ? 'Добавить все' : 'Add all';
  String importResultsCount(int count) =>
      _ru ? 'Серверы · $count' : 'Servers · $count';
  String get addToList => _ru ? 'Добавить' : 'Add';
  String get vpnStopFailed => _ru
      ? 'Не удалось подтвердить остановку VPN. Повторите отключение перед новым подключением.'
      : 'Could not confirm that VPN stopped. Disconnect again before starting a new connection.';
  String get vpnStatusUnavailable => _ru
      ? 'Не удалось получить статус VPN. Соединение может оставаться активным.'
      : 'Could not verify VPN status. The connection may still be active.';
  String get vpnStartFailed => _ru
      ? 'Не удалось запустить VPN. Попробуйте подключиться снова или выберите другой сервер.'
      : 'Could not start the VPN. Try connecting again or choose another server.';
  String get vpnConnectionEnded => _ru
      ? 'VPN завершил работу. Подключитесь снова или выберите другой сервер.'
      : 'The VPN connection ended. Reconnect or choose another server.';
  String get vpnServiceStartFailed => _ru
      ? 'Не удалось запустить службу VPN. Откройте Honey и попробуйте подключиться снова.'
      : 'Could not start the VPN service. Open Honey and try connecting again.';
  String get vpnUnknownFailure => _ru
      ? 'Ошибка VPN. Попробуйте отключить соединение и подключиться снова.'
      : 'A VPN error occurred. Try disconnecting and reconnecting.';

  /// Native diagnostic strings are machine data, never UI text. Only known
  /// bounded reasons choose an explanation; unknown paths/URLs are not echoed.
  String nativeVpnError(String message) {
    switch (message) {
      case 'VPN stop could not be confirmed':
      case 'VPN stop was superseded by a newer command':
      case 'Cannot stop the Android VPN service':
        return vpnStopFailed;
      case 'Cannot start the Android VPN service':
        return vpnServiceStartFailed;
      case 'VPN startup failed':
      case 'VPN configuration is missing':
      case 'VPN forwarder could not start':
      case 'Could not create the VPN session directory':
        return vpnStartFailed;
      case 'sing-box ownership could not be confirmed':
      case 'VPN forwarder ownership could not be confirmed':
      case 'sing-box status could not be confirmed':
      case 'VPN forwarder status could not be confirmed':
        return vpnStatusUnavailable;
    }
    if (message.length <= 96) {
      final stopped = RegExp(
        r'^(sing-box|VPN forwarder) stopped (during startup|unexpectedly) \((exit|signal)=([0-9]{1,3})\)$',
      ).firstMatch(message);
      if (stopped != null) {
        final value = int.parse(stopped.group(4)!);
        final valid = stopped.group(3) == 'exit'
            ? value <= 255
            : value >= 1 && value <= 128;
        if (valid) {
          return stopped.group(2) == 'during startup'
              ? vpnStartFailed
              : vpnConnectionEnded;
        }
      }
    }
    return vpnUnknownFailure;
  }

  String get serverOptionsUnavailable => _ru
      ? 'Параметры сервера пока не поддерживаются.'
      : "This server's options are not supported yet.";
  String get appleVpnConnectFailed => _ru
      ? 'Не удалось подключиться к VPN. Проверьте сервер и попробуйте ещё раз.'
      : 'Could not connect to VPN. Check the server and try again.';
}
