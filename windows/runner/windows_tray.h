#ifndef RUNNER_WINDOWS_TRAY_H_
#define RUNNER_WINDOWS_TRAY_H_

#include <cstddef>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// Only presentation identifiers and labels cross this boundary. Connection
// configuration and credentials remain in Dart and the existing VPN backend.
constexpr size_t kMaximumWindowsTrayServers = 1024;
constexpr unsigned int kWindowsTrayShow = 100;
constexpr unsigned int kWindowsTrayToggle = 101;
constexpr unsigned int kWindowsTrayImport = 102;
constexpr unsigned int kWindowsTrayTunnel = 103;
constexpr unsigned int kWindowsTrayProxy = 104;
constexpr unsigned int kWindowsTraySettings = 105;
constexpr unsigned int kWindowsTrayQuit = 106;
constexpr unsigned int kWindowsTrayFirstServer = 1024;

struct WindowsTrayServer {
  std::string id;
  std::string name;
  std::string group;
  std::string country_code = "";
  std::string group_id = "";
};

struct WindowsTrayState {
  std::string locale = "en";
  bool connected = false;
  bool busy = false;
  bool tunnel = true;
  bool can_connect = false;
  std::optional<std::string> selected_id;
  std::optional<std::string> selected_name;
  std::vector<WindowsTrayServer> servers;
};

enum class WindowsTrayActionKind {
  kShowWindow,
  kToggleConnection,
  kSelectServer,
  kSetTunnel,
  kImportClipboard,
  kShowSettings,
  kQuit,
};

struct WindowsTrayAction {
  WindowsTrayActionKind kind;
  std::string server_id;
  bool tunnel = false;
};

bool ValidateWindowsTrayState(const WindowsTrayState& state);
bool CanToggleWindowsTrayConnection(const WindowsTrayState& state);
// A popup pumps messages: resolve its command against the captured menu, then
// re-check current state before acting. A refreshed list cannot retarget a click.
std::optional<WindowsTrayAction> ResolveWindowsTrayCommand(
    const WindowsTrayState& current, const WindowsTrayState& shown,
    unsigned int command);

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>

constexpr UINT kWindowsTrayMessage = WM_APP + 0x56;
constexpr UINT kWindowsTrayQuitMessage = WM_APP + 0x57;

class WindowsTray {
 public:
  using ActionHandler = std::function<void(const WindowsTrayAction&)>;
  using NotifyIcon = BOOL (WINAPI*)(DWORD, PNOTIFYICONDATAW);
  WindowsTray(HWND window, ActionHandler on_action,
              NotifyIcon notify_icon = Shell_NotifyIconW);
  ~WindowsTray();
  WindowsTray(const WindowsTray&) = delete;
  WindowsTray& operator=(const WindowsTray&) = delete;

  void SetState(WindowsTrayState state);
  bool HideWindow();
  void ShowWindow();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void Remove();

 private:
  bool AddIcon();
  bool RefreshIcon();
  void ShowMenu();
  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  UINT taskbar_created_ = 0;
  bool available_ = false;
  bool version_four_ = false;
  bool menu_open_ = false;
  bool removed_ = false;
  WindowsTrayState state_;
  ActionHandler on_action_;
  NotifyIcon notify_icon_;
};
#endif

#endif  // RUNNER_WINDOWS_TRAY_H_
