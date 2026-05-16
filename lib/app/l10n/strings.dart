import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/presentation/notifiers/settings_notifier.dart';

final stringsProvider = Provider<S>((ref) {
  final locale = ref.watch(
    settingsProvider.select((s) => s.value?.locale ?? 'en'),
  );
  return S(locale);
});

class S {
  final String locale;
  const S(this.locale);
  bool get _ru => locale == 'ru';

  // ── Connect button ──────────────────────────────────────────────────────────
  String get connect       => _ru ? 'ПОДКЛЮЧИТЬ'    : 'CONNECT';
  String get disconnect    => _ru ? 'ОТКЛЮЧИТЬ'     : 'DISCONNECT';
  String get connecting    => _ru ? 'ПОДКЛЮЧЕНИЕ...' : 'CONNECTING...';
  String get disconnecting => _ru ? 'ОТКЛЮЧЕНИЕ...' : 'DISCONNECTING...';
  String get preparing     => _ru ? 'ПОДГОТОВКА...'  : 'PREPARING...';
  String get retry         => _ru ? 'ПОВТОР'         : 'RETRY';

  // ── Connection status labels ────────────────────────────────────────────────
  String get statusConnected     => _ru ? 'Подключено'    : 'Connected';
  String get statusConnecting    => _ru ? 'Подключение…'  : 'Connecting…';
  String get statusPreparing     => _ru ? 'Подготовка…'   : 'Preparing…';
  String get statusDisconnecting => _ru ? 'Отключение…'   : 'Disconnecting…';
  String get statusError         => _ru ? 'Ошибка'        : 'Error';
  String get statusDisconnected  => _ru ? 'Отключено'     : 'Disconnected';

  // ── Home screen ─────────────────────────────────────────────────────────────
  String get subscriptionsTooltip => _ru ? 'Подписки'            : 'Subscriptions';
  String get refreshSubsTooltip   => _ru ? 'Обновить подписки'   : 'Refresh subscriptions';
  String get pingAllTooltip       => _ru ? 'Проверить пинг всех' : 'Ping all';
  String get importServerTooltip  => _ru ? 'Импорт сервера'      : 'Import server';

  String get noServerSelected =>
      _ru ? 'Сервер не выбран — нажмите + для добавления'
          : 'No server selected — tap + to add';
  String get manualGroup => _ru ? 'Вручную' : 'Manual';

  String deleteGroupTitle(String label) =>
      _ru ? 'Удалить "$label"?' : 'Delete "$label"?';
  String deleteGroupContent(int count, bool hasSub) => _ru
      ? 'Удалить все $count серверов${hasSub ? ' и отписаться' : ''}?'
      : 'Remove all $count servers${hasSub ? ' and unsubscribe' : ''}?';

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

  // ── Settings ────────────────────────────────────────────────────────────────
  String get settingsTitle      => _ru ? 'Настройки'     : 'Settings';
  String get appearanceSection  => _ru ? 'Внешний вид'   : 'Appearance';
  String get themeTitle         => _ru ? 'Тема'          : 'Theme';
  String get themeSystem        => _ru ? 'Как в системе' : 'Follow system';
  String get themeLight         => _ru ? 'Светлая'       : 'Light';
  String get themeDark          => _ru ? 'Тёмная'        : 'Dark';
  String get languageTitle      => _ru ? 'Язык'          : 'Language';

  String get connectionSection  => _ru ? 'Подключение'   : 'Connection';
  String get modeTitle          => _ru ? 'Режим'         : 'Mode';
  String get routingTitle       => _ru ? 'Маршрутизация' : 'Routing';
  String get dnsTitle           => 'DNS';
  String get splitTunnelTitle   => _ru ? 'Раздельное туннелирование' : 'Split Tunneling';
  String get splitTunnelSubtitle => _ru ? 'VPN-правила для каждого приложения' : 'Per-app VPN rules';
  String get preferredIpTitle   => _ru ? 'Предпочтительный IP' : 'Preferred IP';
  String preferredIpSubtitle(String type) =>
      _ru ? 'Семейство адресов: $type' : 'Address family: $type';
  String get fragmentationTitle    => _ru ? 'Фрагментация' : 'Fragmentation';
  String get fragmentationSubtitle => _ru
      ? 'Разбить пакеты для обхода DPI'
      : 'Split packets to bypass DPI inspection';
  String get multiplexerTitle    => _ru ? 'Мультиплексор' : 'Multiplexer';
  String get multiplexerSubtitle => _ru
      ? 'Мультиплексирование потоков (Mux) — снижает задержку'
      : 'Multiplex streams (Mux) — reduces latency';
  String get allowLanTitle    => _ru ? 'Разрешить LAN' : 'Allow LAN';
  String get allowLanSubtitle => _ru
      ? 'Расшарить прокси в локальной сети'
      : 'Share proxy on local network';

  String get fakeipTitle    => _ru ? 'Fake IP'  : 'Fake IP';
  String get fakeipSubtitle => _ru
      ? 'Виртуальные IP для быстрого DNS (рекомендуется)'
      : 'Virtual IPs for fast DNS (recommended)';
  String get tunStackTitle => _ru ? 'TUN стек' : 'TUN Stack';
  String tunStackSubtitle(String stack) =>
      _ru ? 'Сетевой стек: $stack' : 'Network stack: $stack';
  String get logLevelTitle => _ru ? 'Уровень логов' : 'Log Level';
  String get portsTitle    => _ru ? 'Порты прокси'  : 'Proxy Ports';

  String get advancedSection   => _ru ? 'Дополнительно' : 'Advanced';
  String get logsTitle         => _ru ? 'Логи'          : 'Logs';
  String get logsSubtitle      => _ru
      ? 'Журнал подключений в реальном времени'
      : 'Real-time connection log';
  String get urlSchemesTitle   => _ru ? 'URL-схемы'     : 'URL Schemes';
  String get urlSchemesSubtitle => _ru
      ? 'Команды honey:// для диплинков'
      : 'honey:// deep link commands';
  String get aboutSection      => _ru ? 'О приложении'  : 'About';

  // ── URL Schemes screen ──────────────────────────────────────────────────────
  String get urlSchemesScreenTitle => _ru ? 'URL-схемы' : 'URL Schemes';
  String get urlSchemesVpnSection  => _ru ? 'Управление VPN' : 'VPN Control';
  String get urlSchemesWebSection  => _ru ? 'Веб-эквиваленты' : 'Web Equivalents';
  String get urlSchemesForProviders => _ru
      ? 'Для VPN-провайдеров'
      : 'For VPN Providers';
  String get urlSchemesProviderHint => _ru
      ? 'Используйте эти схемы в своих приложениях для управления HoneyProxyUtility через диплинки.'
      : 'Use these schemes in your apps to control HoneyProxyUtility via deep links.';
  String get copied => _ru ? 'Скопировано' : 'Copied';

  // ── Subscriptions screen ────────────────────────────────────────────────────
  String get subscriptionsScreenTitle => _ru ? 'Подписки' : 'Subscriptions';
  String get addSubscriptionHint      => _ru
      ? 'Добавить URL подписки'
      : 'Add subscription URL';
  String get addButton  => _ru ? 'Добавить' : 'Add';
  String get refreshing => _ru ? 'Обновление…' : 'Refreshing…';

  // ── Import / Converter screen ───────────────────────────────────────────────
  String get importScreenTitle  => _ru ? 'Импорт'                     : 'Import';
  String get importHint         => _ru ? 'Вставьте ссылку или контент' : 'Paste a link or content';
  String get parseButton        => _ru ? 'Разобрать'                   : 'Parse';
  String get importAllButton    => _ru ? 'Импортировать все'            : 'Import all';
  String get addToList          => _ru ? 'Добавить'                    : 'Add';
}
