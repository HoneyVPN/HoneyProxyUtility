import { parseLauncherLocation } from './import_contract.mjs';

const copy = Object.freeze({
  ru: {
    title: 'Добавить в HoneyProxyUtility', language: 'Язык', eyebrow: 'Импорт',
    heading: 'Добавить в Honey',
    description: 'Откройте приложение, проверьте подписку и нажмите «Добавить».',
    serverDescription: 'Откройте приложение, проверьте сервер и нажмите «Добавить».',
    ready: 'Ссылка готова', open: 'Открыть в HoneyProxyUtility',
    copy: 'Скопировать ссылку', copied: 'Ссылка скопирована',
    copying: 'Копирование…',
    opened: 'Если приложение не открылось, скопируйте ссылку.',
    copyFailed: 'Не удалось скопировать. Скопируйте исходную ссылку в боте.',
    openFailed: 'Не удалось открыть приложение. Можно скопировать ссылку.',
    help: 'Приложение не открылось? Установите актуальную версию HoneyProxyUtility или вставьте скопированную ссылку на экране «Импорт».',
    macHelp: 'Версия для Mac — тестовая. VPN пока недоступен; скопированную ссылку можно вставить на экране «Импорт».',
    iosHeading: 'Honey для iPhone готовится',
    iosDescription: 'Пока можно скопировать ссылку и использовать её в совместимом приложении.',
    iosHelp: 'Приложение HoneyProxyUtility для iPhone и iPad пока недоступно.',
    missingHeading: 'Откройте ссылку из бота',
    missingDescription: 'В Telegram-боте выберите «Добавить в HoneyProxyUtility».',
    invalidHeading: 'Не удалось открыть ссылку',
    invalidDescription: 'Получите новую ссылку в боте и попробуйте снова.',
    invalidHelp: 'Подписка и настройки приложения не изменены.',
    footer: 'Подписка добавляется после подтверждения в приложении.',
    serverFooter: 'Сервер добавляется после подтверждения в приложении.',
  },
  en: {
    title: 'Add to HoneyProxyUtility', language: 'Language', eyebrow: 'Import',
    heading: 'Add to Honey',
    description: 'Open the app, review your subscription and tap Add.',
    serverDescription: 'Open the app, review your server and tap Add.',
    ready: 'Link ready', open: 'Open in HoneyProxyUtility',
    copy: 'Copy link', copied: 'Link copied', copying: 'Copying…',
    opened: 'If the app did not open, copy the link instead.',
    copyFailed: 'Could not copy. Copy the original link from your bot.',
    openFailed: 'Could not open the app. You can copy the link instead.',
    help: 'App did not open? Install the current HoneyProxyUtility version, or paste the copied link into its Import screen.',
    macHelp: 'The Mac version is a preview. VPN is not available yet; you can paste the copied link into the Import screen.',
    iosHeading: 'Honey for iPhone is coming',
    iosDescription: 'You can copy the link and use it in a compatible app for now.',
    iosHelp: 'HoneyProxyUtility for iPhone and iPad is not available yet.',
    missingHeading: 'Open your link from the bot',
    missingDescription: 'Choose Add to HoneyProxyUtility in your Telegram bot.',
    invalidHeading: 'Could not open this link',
    invalidDescription: 'Get a new link from your bot and try again.',
    invalidHelp: 'Your subscription and app settings have not changed.',
    footer: 'Your subscription is added after confirmation in the app.',
    serverFooter: 'Your server is added after confirmation in the app.',
  },
});

function isIOS(navigator) {
  return /iPad|iPhone|iPod/u.test(navigator.userAgent ?? '') ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

export async function copyPrivately(source, document, navigator) {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(source);
      return true;
    }
  } catch { /* A denied Clipboard API may still allow the explicit copy fallback. */ }
  // A temporary clipped field also supports browsers without Clipboard API.
  // It is never visible, focusable by Tab, announced or retained after copying.
  const previous = document.activeElement;
  const field = document.createElement('textarea');
  field.className = 'clipboard-only';
  field.setAttribute('aria-hidden', 'true');
  field.tabIndex = -1;
  field.readOnly = true;
  field.value = source;
  try {
    document.body.appendChild(field);
    field.select();
    return document.execCommand?.('copy') === true;
  } catch { return false; }
  finally {
    field.value = '';
    field.remove();
    previous?.focus?.({ preventScroll: true });
  }
}

export function mountBridge({ document, location, history, navigator }) {
  const nodes = {};
  for (const name of [
    'language-switcher', 'language-ru', 'language-en', 'eyebrow', 'heading',
    'description', 'ready-status', 'ready-label', 'actions', 'open-app',
    'copy-source', 'feedback', 'help', 'footer',
  ]) nodes[name] = document.getElementById(name);

  let state;
  let errorCode;
  try { state = parseLauncherLocation(location.href); }
  catch (error) { errorCode = error.code ?? 'invalid_link'; }

  // Keep the subscription in this page's memory only. Refresh returns to the
  // empty state; users can reopen the unchanged button in their Telegram bot.
  try {
    const clean = new URL(location.href);
    clean.search = '';
    clean.hash = '';
    history.replaceState(null, '', clean.pathname);
  } catch { /* No output of the original URL, even when History API is unavailable. */ }

  let language = (navigator.languages?.[0] ?? navigator.language ?? 'en')
    .toLowerCase().startsWith('ru') ? 'ru' : 'en';
  const ios = isIOS(navigator);
  const mac = !ios && (/Macintosh|Mac OS X/u.test(navigator.userAgent ?? '') ||
    navigator.platform?.startsWith('Mac'));
  let feedback;
  let copying = false;

  function render() {
    const strings = copy[language];
    document.documentElement.lang = language;
    document.title = strings.title;
    nodes['language-switcher'].setAttribute('aria-label', strings.language);
    nodes['language-ru'].setAttribute('aria-pressed', String(language === 'ru'));
    nodes['language-en'].setAttribute('aria-pressed', String(language === 'en'));
    nodes.eyebrow.textContent = strings.eyebrow;
    nodes['ready-label'].textContent = strings.ready;
    nodes['open-app'].textContent = strings.open;
    nodes['copy-source'].textContent = copying ? strings.copying : strings.copy;
    nodes['copy-source'].disabled = copying;
    nodes.feedback.textContent = feedback ? strings[feedback] : '';
    nodes['ready-status'].hidden = !state;
    nodes.actions.hidden = !state;
    nodes['open-app'].hidden = !state || ios;
    nodes['open-app'].disabled = !state || ios;
    nodes.footer.textContent = state?.kind === 'server' ? strings.serverFooter : strings.footer;
    if (!state) {
      const missing = errorCode === 'missing_link';
      nodes.heading.textContent = missing ? strings.missingHeading : strings.invalidHeading;
      nodes.description.textContent = missing ? strings.missingDescription : strings.invalidDescription;
      nodes.help.textContent = strings.invalidHelp;
    } else if (ios) {
      nodes.heading.textContent = strings.iosHeading;
      nodes.description.textContent = strings.iosDescription;
      nodes.help.textContent = strings.iosHelp;
    } else {
      nodes.heading.textContent = strings.heading;
      nodes.description.textContent = state.kind === 'server' ? strings.serverDescription : strings.description;
      nodes.help.textContent = mac ? strings.macHelp : strings.help;
    }
  }

  for (const value of ['ru', 'en']) {
    nodes[`language-${value}`].addEventListener('click', () => {
      language = value;
      render();
    });
  }
  nodes['open-app'].addEventListener('click', () => {
    if (!state || ios) return;
    try {
      // This is the only navigation path: a direct user click, fixed import
      // command, and the already validated source. No automatic connection.
      location.assign(state.appLink);
      feedback = 'opened';
    } catch { feedback = 'openFailed'; }
    render();
  });
  nodes['copy-source'].addEventListener('click', async () => {
    if (!state || copying) return;
    copying = true;
    render();
    try {
      feedback = await copyPrivately(state.source, document, navigator)
        ? 'copied' : 'copyFailed';
    } catch { feedback = 'copyFailed'; }
    finally {
      copying = false;
      render();
    }
  });
  render();
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  mountBridge({ document, location: window.location, history: window.history, navigator: window.navigator });
}
