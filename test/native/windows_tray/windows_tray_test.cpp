#include "../../../windows/runner/windows_tray.h"
#include "../../../windows/runner/windows_tray_flags.h"

#include <algorithm>
#include <iostream>
#include <stdexcept>

namespace {
int passed = 0;
void Check(bool condition, const char* label) {
  if (!condition) throw std::runtime_error(label);
  ++passed;
}

WindowsTrayState State() {
  WindowsTrayState state;
  state.locale = "ru";
  state.can_connect = true;
  state.selected_id = "a";
  state.selected_name = "Finland";
  state.servers = {{"a", "Finland", "HoneyVPN"},
                   {"b", "Netherlands & Germany", "HoneyVPN"},
                   {"c", "Other server", "Another subscription"}};
  return state;
}

void CheckPresentationBounds() {
  auto state = State();
  Check(ValidateWindowsTrayState(state), "valid presentation accepted");
  state.servers[0].country_code = "FI";
  Check(ValidateWindowsTrayState(state), "country bitmap code accepted");
  for (const auto& malformed : {"fi", "F", "FIN", "../fi", "F/", "F1"}) {
    state.servers[0].country_code = malformed;
    Check(!ValidateWindowsTrayState(state), "non-ISO bitmap path input rejected");
  }
  state = State();
  state.servers[0].name = "\xd0\xa4\xd0\xb8\xd0\xbd\xd0\xbb\xd1\x8f\xd0\xbd\xd0\xb4\xd0\xb8\xd1\x8f \xf0\x9f\x87\xab\xf0\x9f\x87\xae";
  Check(ValidateWindowsTrayState(state), "Unicode labels and emoji accepted");
  state.locale = "de";
  Check(!ValidateWindowsTrayState(state), "unknown locale rejected");
  for (const auto& malformed : {std::string("name\ncommand"), std::string("x\0y", 3),
           std::string("\xc0\x80", 2), std::string("\xed\xa0\x80", 3),
           std::string("\xf4\x90\x80\x80", 4), std::string("\xe2\x80\xa8", 3)}) {
    state = State();
    state.servers[0].name = malformed;
    Check(!ValidateWindowsTrayState(state), "malformed/menu-control labels rejected");
  }
  state = State();
  state.servers[1].id = state.servers[0].id;
  Check(!ValidateWindowsTrayState(state), "duplicate stable identifiers rejected");
  state = State();
  state.selected_name = std::string(513, 'n');
  Check(!ValidateWindowsTrayState(state), "oversized selected label rejected");
  state = State();
  state.servers.clear();
  for (size_t i = 0; i < kMaximumWindowsTrayServers; ++i) {
    state.servers.push_back({std::to_string(i), "Server", "HoneyVPN"});
  }
  Check(ValidateWindowsTrayState(state), "server count boundary accepted");
  state.servers.push_back({"overflow", "Server", "HoneyVPN"});
  Check(!ValidateWindowsTrayState(state), "server count overflow rejected");
  state = State();
  state.servers.clear();
  for (size_t i = 0; i < 129; ++i) {
    state.servers.push_back({std::to_string(i), "Server", std::to_string(i)});
  }
  Check(!ValidateWindowsTrayState(state), "group count overflow rejected");
  state = State();
  state.servers.clear();
  for (size_t i = 0; i < 129; ++i) {
    state.servers.push_back({std::to_string(i), "Server", "Same display name", "FI", std::to_string(i)});
  }
  Check(!ValidateWindowsTrayState(state), "duplicate display names cannot bypass group ID limit");
}

void CheckConnectionAndExitPolicy() {
  auto state = State();
  Check(CanToggleWindowsTrayConnection(state), "idle selected server can connect");
  Check(ResolveWindowsTrayCommand(state, state, kWindowsTrayToggle)->kind ==
      WindowsTrayActionKind::kToggleConnection, "connect dispatch delegated to Dart");
  state.can_connect = false;
  Check(!ResolveWindowsTrayCommand(state, state, kWindowsTrayToggle),
      "missing available server cannot connect");
  state.connected = true;
  Check(CanToggleWindowsTrayConnection(state), "active connection can disconnect even if server was removed");
  state.busy = true;
  for (const auto command : {kWindowsTrayToggle, kWindowsTrayFirstServer + 1,
                           kWindowsTrayProxy, kWindowsTrayImport}) {
    Check(!ResolveWindowsTrayCommand(state, state, command), "busy operation cannot reenter connection/import actions");
  }
  Check(ResolveWindowsTrayCommand(state, state, kWindowsTrayQuit)->kind ==
      WindowsTrayActionKind::kQuit, "quit stays available for awaited connecting cancellation");
  Check(ResolveWindowsTrayCommand(state, state, kWindowsTrayShow)->kind ==
      WindowsTrayActionKind::kShowWindow, "busy hidden app remains restorable");
  Check(ResolveWindowsTrayCommand(state, state, kWindowsTraySettings)->kind ==
      WindowsTrayActionKind::kShowSettings, "settings remains accessible");
  state.busy = false;
  Check(!ResolveWindowsTrayCommand(state, state, kWindowsTrayTunnel), "active mode selection is a no-op");
  const auto proxy = ResolveWindowsTrayCommand(state, state, kWindowsTrayProxy);
  Check(proxy && proxy->kind == WindowsTrayActionKind::kSetTunnel && !proxy->tunnel,
      "proxy change passes explicit mode instead of toggling stale state");
  Check(!ResolveWindowsTrayCommand(state, state, 999), "unknown menu command ignored");
}

void CheckLiveMenuSnapshot() {
  const auto shown = State();
  auto current = shown;
  std::swap(current.servers[0], current.servers[1]);
  auto action = ResolveWindowsTrayCommand(current, shown, kWindowsTrayFirstServer + 1);
  Check(action && action->kind == WindowsTrayActionKind::kSelectServer && action->server_id == "b",
      "open-menu click retains stable ID after list reorder");
  current.servers.erase(std::remove_if(current.servers.begin(), current.servers.end(),
      [](const auto& server) { return server.id == "b"; }), current.servers.end());
  Check(!ResolveWindowsTrayCommand(current, shown, kWindowsTrayFirstServer + 1),
      "removed menu server cannot start a connection");
  current = shown;
  current.selected_id = "b";
  Check(!ResolveWindowsTrayCommand(current, shown, kWindowsTrayFirstServer + 1),
      "already selected stable ID does not reconnect");
  Check(!ResolveWindowsTrayCommand(current, shown, kWindowsTrayFirstServer + 100),
      "out-of-range menu server ignored");
  current.busy = true;
  Check(!ResolveWindowsTrayCommand(current, shown, kWindowsTrayFirstServer + 2),
      "new pending operation invalidates an old enabled popup action");
}

#ifdef _WIN32
void CheckBundledFlagBitmaps() {
  HBITMAP retired = nullptr;
  const auto gdi_before = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  {
    WindowsTrayFlagBitmaps flags(nullptr);
    const auto bitmap = flags.Get("FI");
    Check(bitmap != nullptr, "bundled Noto PNG decoded into owned native bitmap");
    BITMAP dimensions{};
    Check(GetObjectW(bitmap, static_cast<int>(sizeof(dimensions)), &dimensions) == static_cast<int>(sizeof(dimensions)) &&
        dimensions.bmWidth == 20 && dimensions.bmHeight == 16 && dimensions.bmBitsPixel == 32,
        "flag bitmap has bounded scaled dimensions and alpha format");
    const auto* pixels = static_cast<const BYTE*>(dimensions.bmBits);
    bool visible = false;
    bool premultiplied = pixels != nullptr;
    if (pixels != nullptr) {
      for (int i = 0; i < dimensions.bmWidth * dimensions.bmHeight; ++i) {
        const auto* pixel = pixels + i * 4;
        visible = visible || pixel[3] != 0;
        premultiplied = premultiplied && pixel[0] <= pixel[3] &&
            pixel[1] <= pixel[3] && pixel[2] <= pixel[3];
      }
    }
    Check(visible && premultiplied, "PNG alpha is preserved and premultiplied for native menu drawing");
    Check(flags.Get("FI") == bitmap, "same country reuses one popup bitmap");
    Check(flags.Get("ZZ") == nullptr && flags.Get("../fi") == nullptr &&
        flags.Get("") == nullptr, "missing and malformed flags retain text fallback");
    const auto menu = CreatePopupMenu();
    Check(menu != nullptr && AppendMenuW(menu, MF_STRING | MF_CHECKED, 1, L"Finland") &&
        SetWindowsTrayMenuBitmap(menu, 1, bitmap), "bitmap attached without replacing selected checkmark");
    MENUITEMINFOW item{};
    item.cbSize = sizeof(item);
    item.fMask = MIIM_BITMAP | MIIM_STATE;
    MENUINFO menu_info{};
    menu_info.cbSize = sizeof(menu_info);
    menu_info.fMask = MIM_STYLE;
    Check(GetMenuItemInfoW(menu, 1, FALSE, &item) && item.hbmpItem == bitmap &&
        (item.fState & MFS_CHECKED) && GetMenuInfo(menu, &menu_info) &&
        !(menu_info.dwStyle & (MNS_CHECKORBMP | MNS_NOCHECK)),
        "selected server keeps separate flag and checkmark slots");
    Check(DestroyMenu(menu) != FALSE, "popup retired before its bitmap cache");
    retired = bitmap;
  }
  BITMAP dead{};
  Check(GetObjectW(retired, static_cast<int>(sizeof(dead)), &dead) == 0,
      "popup destruction releases its owned bitmap");
  Check(GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) == gdi_before,
      "flag popup leaves no GDI bitmap leak");
}

bool shell_available = true;
int shell_adds = 0;
int shell_deletes = 0;
BOOL WINAPI MockNotifyIcon(DWORD message, PNOTIFYICONDATAW data) {
  if (data == nullptr || data->hWnd == nullptr || data->uID != 1) return FALSE;
  if (message == NIM_ADD) ++shell_adds;
  if (message == NIM_DELETE) {
    ++shell_deletes;
    return TRUE;
  }
  return shell_available ? TRUE : FALSE;
}

void CheckOwnedWindowLifecycle() {
  // No Explorer notification, engine, VPN backend, or host app is involved.
  // Only this fixture's own invisible/visible window and injected shell exist.
  const auto instance = GetModuleHandleW(nullptr);
  const wchar_t* name = L"HoneyOwnedTrayFixture";
  WNDCLASSW window_class{};
  window_class.hInstance = instance;
  window_class.lpszClassName = name;
  window_class.lpfnWndProc = DefWindowProcW;
  Check(RegisterClassW(&window_class) != 0, "owned lifecycle window class created");
  const auto window = CreateWindowW(name, L"Owned tray fixture", WS_OVERLAPPEDWINDOW,
      0, 0, 100, 100, nullptr, nullptr, instance, nullptr);
  Check(window != nullptr, "owned lifecycle window created");
  ::ShowWindow(window, SW_SHOWNOACTIVATE);
  {
    WindowsTray tray(window, [](const auto&) {}, MockNotifyIcon);
    Check(shell_adds == 1, "icon registered through injected shell only");
    Check(tray.HideWindow() && !IsWindowVisible(window), "close hides live window while icon is usable");
    tray.ShowWindow();
    Check(IsWindowVisible(window), "tray restores same owned window without replacement process");
    shell_available = false;
    Check(!tray.HideWindow() && IsWindowVisible(window), "notification failure preserves normal visible close fallback");
    shell_available = true;
    Check(tray.HideWindow(), "successful retry can hide again");
    const auto taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    const int previous_adds = shell_adds;
    Check(tray.HandleMessage(taskbar_created, 0, 0) && shell_adds == previous_adds + 1,
        "Explorer restart recreates owned notification icon");
    Check(!IsWindowVisible(window), "successful Explorer recovery retains hidden state");
    shell_available = false;
    Check(tray.HandleMessage(taskbar_created, 0, 0) && IsWindowVisible(window),
        "failed Explorer recovery restores hidden window instead of trapping app");
    tray.Remove();
    tray.Remove();
    Check(!tray.HideWindow() && !tray.HandleMessage(taskbar_created, 0, 0),
        "retired tray cannot hide or register a replacement icon");
  }
  Check(shell_deletes == 1, "destruction removes only the owned icon even after shell failure");
  Check(DestroyWindow(window) != FALSE, "owned fixture window retired");
  Check(UnregisterClassW(name, instance) != FALSE, "owned fixture class retired");
}
#endif
}  // namespace

int main() {
  try {
    CheckPresentationBounds();
    CheckConnectionAndExitPolicy();
    CheckLiveMenuSnapshot();
#ifdef _WIN32
    CheckBundledFlagBitmaps();
    CheckOwnedWindowLifecycle();
#endif
    std::cout << "PASS " << passed << " native tray state/menu dispatch checks\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
