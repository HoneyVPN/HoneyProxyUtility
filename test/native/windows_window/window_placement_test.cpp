#include "../../../windows/runner/window_placement.h"

#include <algorithm>
#include <cstdlib>
#include <cwchar>
#include <iostream>
#include <limits>

#ifdef _WIN32
#include <flutter_windows.h>
#endif

namespace {
int checked = 0;

void Check(bool condition, const char* label) {
  if (!condition) {
    std::cerr << "FAIL " << label << std::endl;
    std::exit(1);
  }
  ++checked;
}

void CheckPanel(const honey::PixelRect& work, uint32_t dpi, int frame,
                int expected_width) {
  honey::PixelRect bounds{};
  Check(honey::CalculateStartupPanelBounds(work, dpi, frame, &bounds),
        "Valid monitor geometry must be accepted");
  Check(bounds.right == work.right && bounds.top == work.top &&
            bounds.bottom == work.bottom &&
            bounds.right - bounds.left == expected_width,
        "Panel must align right, include its title bar and fit the full work height");
  Check(bounds.left >= work.left, "Small monitors must clamp the panel width");
}

void CheckGeometry() {
  CheckPanel({0, 0, 1920, 1040}, 96, 16, 536);  // Bottom taskbar.
  CheckPanel({0, 40, 1920, 1080}, 120, 20, 670);  // Top taskbar, 125%.
  CheckPanel({0, 0, 2560, 1392}, 144, 24, 804);  // 150%.
  CheckPanel({0, 0, 3840, 2080}, 192, 32, 1072);  // 200%.
  CheckPanel({-1920, 0, 0, 1040}, 144, 24, 804);  // Left monitor.
  CheckPanel({1920, -1440, 4480, -48}, 144, 24, 804);  // Above/right monitor.
  CheckPanel({-1512, -100, -80, 940}, 120, 20, 670);  // Side taskbar.
  CheckPanel({0, 0, 320, 240}, 192, 32, 320);  // Smaller than desired panel.
  CheckPanel({0, 0, 1920, 1040}, 0, 16, 536);  // Missing DPI uses 96.
  CheckPanel({0, 0, 1920, 1040}, std::numeric_limits<uint32_t>::max(),
             std::numeric_limits<int>::max(), 1920);  // No overflow.
  honey::PixelRect bounds{};
  Check(!honey::CalculateStartupPanelBounds({0, 0, 0, 400}, 96, 16, &bounds),
        "Empty work area must be rejected");
  Check(!honey::CalculateStartupPanelBounds({100, 0, 0, 400}, 96, 16, &bounds),
        "Reversed work area must be rejected");
  Check(!honey::CalculateStartupPanelBounds({0, 0, 800, 400}, 96, -1, &bounds),
        "Negative frame width must be rejected");
  Check(!honey::CalculateStartupPanelBounds(
            {std::numeric_limits<int>::min(), 0, std::numeric_limits<int>::max(), 400},
            96, 16, &bounds),
        "Virtual-screen spans outside Win32 dimensions must be rejected");
  Check(!honey::CalculateStartupPanelBounds({0, 0, 800, 400}, 96, 16, nullptr),
        "Missing output must be rejected");
}

#ifdef _WIN32
BOOL CALLBACK CheckMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM count) {
  Check(AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE,
        "Real monitor queries must retain exact PerMonitorV2 awareness");
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  Check(GetMonitorInfoW(monitor, &info) != FALSE, "Real monitor work-area query");
  RECT bounds{};
  Check(honey::QueryStartupPanelBounds(monitor, &bounds), "Real DPI/frame query");
  Check(bounds.right == info.rcWork.right && bounds.top == info.rcWork.top &&
            bounds.bottom == info.rcWork.bottom && bounds.left >= info.rcWork.left,
        "Real taskbar/work-area bounds must be retained");
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) dpi = 96;
  const LONG client_width = MulDiv(honey::kStartupPanelClientWidth,
                                  static_cast<int>(dpi), 96);
  RECT frame{0, 0, client_width, 1};
  Check(AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi) != FALSE,
        "Real native title/frame adjustment");
  const LONG expected_width = (std::min)(info.rcWork.right - info.rcWork.left,
                                        frame.right - frame.left);
  Check(bounds.right - bounds.left == expected_width,
        "The content width must remain 520 logical pixels unless monitor is smaller");
  const POINT center{info.rcMonitor.left + (info.rcMonitor.right - info.rcMonitor.left) / 2,
                      info.rcMonitor.top + (info.rcMonitor.bottom - info.rcMonitor.top) / 2};
  Check(MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST) == monitor,
        "Virtual-screen coordinates select the actual monitor");
  std::cout << "MONITOR dpi=" << dpi << " work=" << info.rcWork.left << ","
            << info.rcWork.top << "," << info.rcWork.right << ","
            << info.rcWork.bottom << " panel=" << bounds.left << ","
            << bounds.top << "," << bounds.right << "," << bounds.bottom
            << std::endl;
  ++*reinterpret_cast<int*>(count);
  return TRUE;
}

void CheckWindowsQueries() {
  wchar_t manifest_awareness[32]{};
  SIZE_T setting_length = 0;
  Check(QueryActCtxSettingsW(0, nullptr,
            L"http://schemas.microsoft.com/SMI/2016/WindowsSettings",
            L"dpiAwareness", manifest_awareness,
            sizeof(manifest_awareness) / sizeof(manifest_awareness[0]),
            &setting_length) != FALSE &&
            std::wcscmp(manifest_awareness, L"PerMonitorV2") == 0,
        "The active application manifest must request PerMonitorV2");

  const auto initial_awareness = GetThreadDpiAwarenessContext();
  DPI_AWARENESS_CONTEXT previous_awareness = nullptr;
  if (!AreDpiAwarenessContextsEqual(initial_awareness,
          DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
    USEROBJECTFLAGS station_flags{};
    DWORD flags_length = 0;
    Check(GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS,
              &station_flags, sizeof(station_flags), &flags_length) != FALSE,
          "The fixture's window station must be queryable");
    // The Windows OpenSSH service runs on a nonvisible Session 0 station.
    // That launch gives this correctly manifested process a V1 default on the
    // build PC. Query in an explicit V2 thread scope, without changing desktop
    // settings; an interactive launch must still inherit V2 from the manifest.
    Check((station_flags.dwFlags & WSF_VISIBLE) == 0,
          "Interactive startup must inherit PerMonitorV2 from the app manifest");
    previous_awareness = SetThreadDpiAwarenessContext(
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    Check(previous_awareness != nullptr &&
              AreDpiAwarenessContextsEqual(previous_awareness,
                  initial_awareness) != FALSE,
          "Noninteractive queries must enter a restorable PerMonitorV2 scope");
    std::cout << "INFO noninteractive window station: scoped PerMonitorV2 queries"
              << std::endl;
  }
  Check(AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE,
        "Fixture must query physical coordinates with the app's DPI awareness");
  int monitors = 0;
  Check(EnumDisplayMonitors(nullptr, nullptr, CheckMonitor,
                            reinterpret_cast<LPARAM>(&monitors)) != FALSE && monitors > 0,
        "At least one real monitor must be inspected without creating a window");
  const HMONITOR startup = honey::StartupWindowMonitor();
  Check(startup != nullptr, "Startup monitor selection must succeed");
  POINT pointer{};
  const HMONITOR expected = GetCursorPos(&pointer)
      ? MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST)
      : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  Check(startup == expected, "Startup monitor follows pointer or primary fallback");
  if (previous_awareness != nullptr) {
    const auto replaced_awareness = SetThreadDpiAwarenessContext(previous_awareness);
    Check(replaced_awareness != nullptr &&
              AreDpiAwarenessContextsEqual(replaced_awareness,
                  DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE &&
              AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),
                  initial_awareness) != FALSE,
          "Noninteractive queries must restore the original DPI context");
  }
  std::cout << "PASS read-only Windows monitor/DPI/frame API checks ("
            << monitors << " monitors, no window created)" << std::endl;
}
#endif
}  // namespace

int main() {
  CheckGeometry();
#ifdef _WIN32
  CheckWindowsQueries();
#else
  std::cout << "SKIP Windows monitor APIs on this platform" << std::endl;
#endif
  std::cout << "PASS " << checked << " startup window geometry checks" << std::endl;
  return 0;
}
