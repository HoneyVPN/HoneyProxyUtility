import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appleVpnChannels: AppleVpnChannels?
  private var commandChannel: FlutterMethodChannel?
  private var originalMenuTitles: [ObjectIdentifier: String] = [:]
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacImportLinks.shared.install(messenger: flutterViewController.engine.binaryMessenger)
    appleVpnChannels = AppleVpnChannels(messenger: flutterViewController.engine.binaryMessenger)
    commandChannel = FlutterMethodChannel(name: "ru.honeyvpn.proxy/commands",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    commandChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setLocale", let locale = call.arguments as? String else {
        result(FlutterMethodNotImplemented); return
      }
      self?.updateMenuLocale(locale)
      result(nil)
    }

    super.awakeFromNib()
  }

  func navigateTo(_ path: String) {
    commandChannel?.invokeMethod("navigate", arguments: path)
  }

  private func updateMenuLocale(_ locale: String) {
    let isRussian = locale == "ru"
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "HoneyProxyUtility"
    let actionTitles: [String: (english: String, russian: String)] = [
      "orderFrontStandardAboutPanel:": ("About \(appName)", "О программе \(appName)"),
      "openPreferences:": ("Settings…", "Настройки…"),
      "importServer:": ("Import Server…", "Импорт сервера…"),
      "hide:": ("Hide \(appName)", "Скрыть \(appName)"),
      "hideOtherApplications:": ("Hide Others", "Скрыть остальные"),
      "unhideAllApplications:": ("Show All", "Показать все"),
      "terminate:": ("Quit \(appName)", "Завершить \(appName)"),
      "undo:": ("Undo", "Отменить"),
      "redo:": ("Redo", "Повторить"),
      "cut:": ("Cut", "Вырезать"),
      "copy:": ("Copy", "Скопировать"),
      "paste:": ("Paste", "Вставить"),
      "pasteAsPlainText:": ("Paste and Match Style", "Вставить с согласованием стиля"),
      "delete:": ("Delete", "Удалить"),
      "selectAll:": ("Select All", "Выбрать всё"),
      "centerSelectionInVisibleArea:": ("Jump to Selection", "Перейти к выделенному"),
      "showGuessPanel:": ("Show Spelling and Grammar", "Показать правописание и грамматику"),
      "checkSpelling:": ("Check Document Now", "Проверить документ"),
      "toggleContinuousSpellChecking:": ("Check Spelling While Typing", "Проверять правописание при вводе"),
      "toggleGrammarChecking:": ("Check Grammar With Spelling", "Проверять грамматику и правописание"),
      "toggleAutomaticSpellingCorrection:": ("Correct Spelling Automatically", "Исправлять правописание автоматически"),
      "orderFrontSubstitutionsPanel:": ("Show Substitutions", "Показать замены"),
      "toggleSmartInsertDelete:": ("Smart Copy/Paste", "Смарт-копирование и вставка"),
      "toggleAutomaticQuoteSubstitution:": ("Smart Quotes", "Смарт-кавычки"),
      "toggleAutomaticDashSubstitution:": ("Smart Dashes", "Смарт-тире"),
      "toggleAutomaticLinkDetection:": ("Smart Links", "Смарт-ссылки"),
      "toggleAutomaticDataDetection:": ("Data Detectors", "Распознавание данных"),
      "toggleAutomaticTextReplacement:": ("Text Replacement", "Замена текста"),
      "uppercaseWord:": ("Make Upper Case", "Прописные буквы"),
      "lowercaseWord:": ("Make Lower Case", "Строчные буквы"),
      "capitalizeWord:": ("Capitalize", "С заглавных букв"),
      "startSpeaking:": ("Start Speaking", "Начать произношение"),
      "stopSpeaking:": ("Stop Speaking", "Остановить произношение"),
      "performMiniaturize:": ("Minimize", "Свернуть"),
      "performZoom:": ("Zoom", "Масштабировать"),
      "arrangeInFront:": ("Bring All to Front", "Все окна на передний план"),
    ]
    let menuTitles: [String: String] = [
      "Services": "Службы",
      "File": "Файл",
      "Edit": "Правка",
      "Find": "Поиск",
      "Find…": "Найти…",
      "Find and Replace…": "Найти и заменить…",
      "Find Next": "Найти следующее",
      "Find Previous": "Найти предыдущее",
      "Use Selection for Find": "Искать выделенное",
      "Spelling and Grammar": "Правописание и грамматика",
      "Substitutions": "Замены",
      "Transformations": "Преобразования",
      "Speech": "Речь",
      "View": "Вид",
      "Window": "Окно",
      "Help": "Справка",
    ]
    func update(_ menu: NSMenu) {
      for item in menu.items {
        // Preserve the NIB title once so RU → EN → RU never depends on a
        // previously translated title. Menu actions and targets stay intact.
        let identity = ObjectIdentifier(item)
        let original = originalMenuTitles[identity] ?? item.title
        originalMenuTitles[identity] = original
        if let action = item.action, let titles = actionTitles[NSStringFromSelector(action)] {
          item.title = isRussian ? titles.russian : titles.english
        } else if item.action == NSSelectorFromString("toggleFullScreen:") {
          let fullScreen = styleMask.contains(.fullScreen)
          item.title = isRussian
            ? (fullScreen ? "Выйти из полноэкранного режима" : "Полноэкранный режим")
            : (fullScreen ? "Exit Full Screen" : "Enter Full Screen")
        } else if let russian = menuTitles[original] {
          item.title = isRussian ? russian : original
        }
        if let submenu = item.submenu {
          if menuTitles[original] != nil {
            submenu.title = item.title
          }
          update(submenu)
        }
      }
    }
    if let menu = NSApplication.shared.mainMenu { update(menu) }
  }
}

/// Retains only the newest OS activation while Flutter attaches its listener.
/// Import parsing and all user-facing errors belong to the shared Dart receiver.
final class MacImportLinks: NSObject, FlutterStreamHandler {
  static let shared = MacImportLinks()
  private var channel: FlutterEventChannel?
  private var sink: FlutterEventSink?
  private var pending: String?
  private var pendingTooLong = false

  func install(messenger: FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: "ru.honeyvpn.proxy/deeplink", binaryMessenger: messenger)
    channel?.setStreamHandler(self)
  }

  func receive(_ rawURI: String) {
    if rawURI.utf8.count > 65536 {
      pending = nil
      pendingTooLong = true
    } else {
      pending = rawURI
      pendingTooLong = false
    }
    drain()
  }

  private func drain() {
    guard let sink = sink else { return }
    let rawURI = pending
    let tooLong = pendingTooLong
    pending = nil
    pendingTooLong = false
    if tooLong {
      sink(FlutterError(code: "IMPORT_LINK_TOO_LONG", message: "Import link is too long", details: nil))
    } else if let rawURI = rawURI {
      sink(rawURI)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    drain()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
