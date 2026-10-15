#include "windows_tray.h"
#include "windows_tray_flags.h"

#include <algorithm>
#include <set>
#include <utility>

namespace {
bool ValidText(const std::string& value, size_t maximum, bool allow_empty) {
  if (value.size() > maximum || (!allow_empty && value.empty())) return false;
  // Validate Unicode before UTF-16 conversion and reject embedded terminators
  // and control characters that could change a native menu label's structure.
  for (size_t i = 0; i < value.size();) {
    const auto first = static_cast<unsigned char>(value[i++]);
    if (first < 0x80) {
      if (first < 0x20 || first == 0x7f) return false;
      continue;
    }
    unsigned int codepoint = 0;
    unsigned int minimum = 0;
    size_t following = 0;
    if (first >= 0xc2 && first <= 0xdf) {
      following = 1; minimum = 0x80; codepoint = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      following = 2; minimum = 0x800; codepoint = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      following = 3; minimum = 0x10000; codepoint = first & 0x07;
    } else {
      return false;
    }
    if (following > value.size() - i) return false;
    for (size_t j = 0; j < following; ++j) {
      const auto next = static_cast<unsigned char>(value[i++]);
      if ((next & 0xc0) != 0x80) return false;
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff) ||
        (codepoint >= 0x80 && codepoint <= 0x9f) || codepoint == 0x2028 ||
        codepoint == 0x2029) return false;
  }
  return true;
}
}  // namespace

bool ValidateWindowsTrayState(const WindowsTrayState& state) {
  if ((state.locale != "ru" && state.locale != "en") ||
      state.servers.size() > kMaximumWindowsTrayServers ||
      (state.selected_id && !ValidText(*state.selected_id, 128, false)) ||
      (state.selected_name && !ValidText(*state.selected_name, 512, true))) {
    return false;
  }
  std::set<std::string> identifiers;
  std::set<std::string> groups;
  for (const auto& server : state.servers) {
    if (!ValidText(server.id, 128, false) || !ValidText(server.name, 512, false) ||
        !ValidText(server.group, 256, true) ||
        !ValidText(server.group_id, 128, true) ||
        !ValidWindowsTrayCountryCode(server.country_code) ||
        !identifiers.insert(server.id).second) return false;
    groups.insert(server.group_id.empty() ? server.group : server.group_id);
  }
  return groups.size() <= 128;
}

bool CanToggleWindowsTrayConnection(const WindowsTrayState& state) {
  return !state.busy && (state.connected || state.can_connect);
}

std::optional<WindowsTrayAction> ResolveWindowsTrayCommand(
    const WindowsTrayState& current, const WindowsTrayState& shown,
    unsigned int command) {
  if (command == kWindowsTrayShow) return WindowsTrayAction{WindowsTrayActionKind::kShowWindow, {}, false};
  if (command == kWindowsTraySettings) return WindowsTrayAction{WindowsTrayActionKind::kShowSettings, {}, false};
  // Dart owns cancellation and confirmed disconnect before an explicit exit.
  if (command == kWindowsTrayQuit) return WindowsTrayAction{WindowsTrayActionKind::kQuit, {}, false};
  if (current.busy) return std::nullopt;
  if (command == kWindowsTrayToggle && CanToggleWindowsTrayConnection(current)) {
    return WindowsTrayAction{WindowsTrayActionKind::kToggleConnection, {}, false};
  }
  if (command == kWindowsTrayImport) return WindowsTrayAction{WindowsTrayActionKind::kImportClipboard, {}, false};
  if (command == kWindowsTrayTunnel || command == kWindowsTrayProxy) {
    const bool tunnel = command == kWindowsTrayTunnel;
    if (tunnel != current.tunnel) return WindowsTrayAction{WindowsTrayActionKind::kSetTunnel, {}, tunnel};
    return std::nullopt;
  }
  if (command >= kWindowsTrayFirstServer) {
    const auto index = static_cast<size_t>(command - kWindowsTrayFirstServer);
    if (index >= shown.servers.size()) return std::nullopt;
    const auto& id = shown.servers[index].id;
    const auto present = std::find_if(current.servers.begin(), current.servers.end(),
        [&id](const auto& server) { return server.id == id; });
    if (present != current.servers.end() && current.selected_id != id) {
      return WindowsTrayAction{WindowsTrayActionKind::kSelectServer, id, false};
    }
  }
  return std::nullopt;
}

#ifdef _WIN32
#include <shellapi.h>
#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;

std::wstring WideLabel(const std::string& value, bool menu = true) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring wide(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), wide.data(), size) != size) return {};
  if (!menu) return wide;
  std::wstring escaped;
  for (const auto character : wide) {
    escaped.push_back(character);
    if (character == L'&') escaped.push_back(L'&');
  }
  return escaped;
}

NOTIFYICONDATAW IconData(HWND window, HICON icon, const WindowsTrayState& state) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kWindowsTrayMessage;
  data.hIcon = icon;
  std::wstring tip = L"HoneyVPN";
  tip += state.locale == "ru"
      ? (state.connected ? L" — Подключено" : L" — Отключено")
      : (state.connected ? L" — Connected" : L" — Disconnected");
  if (state.selected_name && !state.selected_name->empty()) {
    tip += L"\n" + WideLabel(*state.selected_name, false);
  }
  constexpr size_t maximum = sizeof(data.szTip) / sizeof(data.szTip[0]) - 1;
  if (tip.size() > maximum) {
    tip.resize(maximum - 1);
    if (tip.back() >= 0xd800 && tip.back() <= 0xdbff) tip.pop_back();
    tip += L"…";
  }
  std::copy(tip.begin(), tip.end(), data.szTip);
  return data;
}

bool AppendCommand(HMENU menu, UINT command, const wchar_t* label,
                   bool enabled = true, bool checked = false) {
  const UINT flags = MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED) |
      (checked ? MF_CHECKED : MF_UNCHECKED);
  return AppendMenuW(menu, flags, command, label) != FALSE;
}

bool AppendSubmenu(HMENU parent, HMENU child, const wchar_t* label, bool enabled) {
  if (child != nullptr && AppendMenuW(parent, MF_POPUP | MF_STRING |
      (enabled ? MF_ENABLED : MF_GRAYED), reinterpret_cast<UINT_PTR>(child), label)) {
    return true;
  }
  if (child != nullptr) DestroyMenu(child);
  return false;
}
}  // namespace

WindowsTray::WindowsTray(HWND window, ActionHandler on_action, NotifyIcon notify_icon)
    : window_(window), on_action_(std::move(on_action)), notify_icon_(notify_icon) {
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  icon_ = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),
      MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
      GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  AddIcon();
}

WindowsTray::~WindowsTray() {
  Remove();
  if (icon_ != nullptr) DestroyIcon(icon_);
}

bool WindowsTray::AddIcon() {
  if (removed_ || icon_ == nullptr || window_ == nullptr || notify_icon_ == nullptr) return false;
  auto data = IconData(window_, icon_, state_);
  available_ = notify_icon_(NIM_ADD, &data) != FALSE;
  version_four_ = false;
  if (available_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    version_four_ = notify_icon_(NIM_SETVERSION, &data) != FALSE;
  }
  return available_;
}

bool WindowsTray::RefreshIcon() {
  if (removed_) return false;
  if (!available_) return AddIcon();
  auto data = IconData(window_, icon_, state_);
  if (notify_icon_(NIM_MODIFY, &data)) return true;
  available_ = false;
  return AddIcon();
}

void WindowsTray::SetState(WindowsTrayState state) {
  if (!ValidateWindowsTrayState(state)) return;
  state_ = std::move(state);
  if (!RefreshIcon() && !IsWindowVisible(window_)) ShowWindow();
}

bool WindowsTray::HideWindow() {
  if (!RefreshIcon()) return false;
  ::ShowWindow(window_, SW_HIDE);
  return true;
}

void WindowsTray::ShowWindow() {
  if (removed_ || !IsWindow(window_)) return;
  ::ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  if (!SetForegroundWindow(window_)) {
    FLASHWINFO flash{sizeof(flash), window_, FLASHW_TRAY, 3, 0};
    FlashWindowEx(&flash);
  }
}

void WindowsTray::Remove() {
  if (removed_) return;
  removed_ = true;
  if (icon_ != nullptr && window_ != nullptr && notify_icon_ != nullptr) {
    auto data = IconData(window_, icon_, state_);
    notify_icon_(NIM_DELETE, &data);
  }
  available_ = false;
}

bool WindowsTray::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  (void)wparam;
  if (removed_) return false;
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    // Explorer discarded the old icon. Never leave the app hidden without a
    // working way to restore it when the replacement notification area fails.
    available_ = false;
    if (!AddIcon() && !IsWindowVisible(window_)) ShowWindow();
    return true;
  }
  if (message != kWindowsTrayMessage) return false;
  if (version_four_ && HIWORD(lparam) != kTrayIconId) return true;
  const UINT event = version_four_ ? LOWORD(lparam) : static_cast<UINT>(lparam);
  if (event == NIN_SELECT || event == NIN_KEYSELECT ||
      (!version_four_ && (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK))) {
    ShowWindow();
  } else if (event == WM_CONTEXTMENU || (!version_four_ && event == WM_RBUTTONUP)) {
    ShowMenu();
  }
  return true;
}

void WindowsTray::ShowMenu() {
  if (menu_open_) return;
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  menu_open_ = true;
  const WindowsTrayState shown = state_;
  WindowsTrayFlagBitmaps flag_bitmaps(window_);
  const bool russian = shown.locale == "ru";
  bool built = AppendCommand(menu, kWindowsTrayShow, russian ? L"Открыть HoneyVPN" : L"Open HoneyVPN");
  SetMenuDefaultItem(menu, kWindowsTrayShow, FALSE);
  const auto selected = shown.selected_name && !shown.selected_name->empty()
      ? WideLabel(*shown.selected_name) : (russian ? L"Сервер не выбран" : L"No server selected");
  built = AppendCommand(menu, 0, selected.c_str(), false) && built;
  built = AppendCommand(menu, kWindowsTrayToggle,
      shown.connected ? (russian ? L"Отключить" : L"Disconnect")
                      : (russian ? L"Подключить" : L"Connect"),
      CanToggleWindowsTrayConnection(shown)) && built;

  HMENU servers = CreatePopupMenu();
  bool servers_built = servers != nullptr;
  std::vector<std::string> groups;
  for (const auto& server : shown.servers) {
    const auto& group_id = server.group_id.empty() ? server.group : server.group_id;
    if (std::find(groups.begin(), groups.end(), group_id) == groups.end()) groups.push_back(group_id);
  }
  for (const auto& group : groups) {
    std::string group_label;
    HMENU entries = CreatePopupMenu();
    bool group_built = entries != nullptr;
    if (entries != nullptr) {
      for (size_t i = 0; i < shown.servers.size(); ++i) {
        const auto& server = shown.servers[i];
        if ((server.group_id.empty() ? server.group : server.group_id) != group) continue;
        group_label = server.group;
        const auto label = WideLabel(server.name);
        group_built = AppendCommand(entries, kWindowsTrayFirstServer + static_cast<UINT>(i),
            label.c_str(), !shown.busy, shown.selected_id == server.id) && group_built;
        // The default menu style reserves separate bitmap and checkmark slots.
        SetWindowsTrayMenuBitmap(entries, kWindowsTrayFirstServer + static_cast<UINT>(i),
            flag_bitmaps.Get(server.country_code));
      }
    }
    const auto label = group_label.empty() ? (russian ? L"Другие серверы" : L"Other servers") : WideLabel(group_label);
    if (group_built && servers != nullptr) {
      servers_built = AppendSubmenu(servers, entries, label.c_str(), !shown.busy) && servers_built;
    } else {
      if (entries != nullptr) DestroyMenu(entries);
      servers_built = false;
    }
  }
  if (servers_built) {
    built = AppendSubmenu(menu, servers, russian ? L"Выбрать сервер" : L"Choose server",
        !shown.busy && !shown.servers.empty()) && built;
  } else {
    if (servers != nullptr) DestroyMenu(servers);
    built = false;
  }
  HMENU mode = CreatePopupMenu();
  if (mode != nullptr) {
    const bool modes_built = AppendCommand(mode, kWindowsTrayTunnel, L"TUN", !shown.busy) &&
        AppendCommand(mode, kWindowsTrayProxy, russian ? L"Прокси" : L"Proxy", !shown.busy);
    if (modes_built) {
      CheckMenuRadioItem(mode, kWindowsTrayTunnel, kWindowsTrayProxy,
          shown.tunnel ? kWindowsTrayTunnel : kWindowsTrayProxy, MF_BYCOMMAND);
      built = AppendSubmenu(menu, mode, russian ? L"Режим" : L"Mode", !shown.busy) && built;
    } else {
      DestroyMenu(mode);
      built = false;
    }
  } else {
    built = false;
  }
  built = AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) != FALSE && built;
  built = AppendCommand(menu, kWindowsTrayImport,
      russian ? L"Импортировать из буфера" : L"Import from clipboard", !shown.busy) && built;
  built = AppendCommand(menu, kWindowsTraySettings, russian ? L"Настройки…" : L"Settings…") && built;
  built = AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) != FALSE && built;
  built = AppendCommand(menu, kWindowsTrayQuit, russian ? L"Выход" : L"Quit") && built;

  UINT selected_command = 0;
  POINT position{};
  if (built && GetCursorPos(&position)) {
    SetForegroundWindow(window_);
    selected_command = static_cast<UINT>(TrackPopupMenu(menu,
        TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
        position.x, position.y, 0, window_, nullptr));
    // Required by the notification-area menu contract so dismissal works on
    // subsequent clicks even though the application window may be hidden.
    PostMessageW(window_, WM_NULL, 0, 0);
  }
  DestroyMenu(menu);
  menu_open_ = false;
  if (removed_ || !IsWindow(window_)) return;
  const auto action = ResolveWindowsTrayCommand(state_, shown, selected_command);
  if (!action) return;
  if (action->kind == WindowsTrayActionKind::kShowWindow) ShowWindow();
  else if (on_action_) on_action_(*action);
}
#endif  // _WIN32
