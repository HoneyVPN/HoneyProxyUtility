#include "window_placement.h"

#include <algorithm>
#include <limits>

#ifdef _WIN32
#include <flutter_windows.h>
#endif

namespace honey {

bool CalculateStartupPanelBounds(const PixelRect& work_area, uint32_t dpi,
                                 int horizontal_frame_width, PixelRect* bounds) {
  const int64_t width = static_cast<int64_t>(work_area.right) - work_area.left;
  const int64_t height = static_cast<int64_t>(work_area.bottom) - work_area.top;
  if (bounds == nullptr || width <= 0 || height <= 0 ||
      width > std::numeric_limits<int>::max() ||
      height > std::numeric_limits<int>::max() || horizontal_frame_width < 0) {
    return false;
  }
  if (dpi == 0) dpi = 96;
  const int64_t client_width =
      (static_cast<int64_t>(kStartupPanelClientWidth) * dpi + 48) / 96;
  const int64_t outer_width = std::min(width, client_width + horizontal_frame_width);
  *bounds = {static_cast<int>(static_cast<int64_t>(work_area.right) - outer_width),
             work_area.top, work_area.right, work_area.bottom};
  return true;
}

#ifdef _WIN32
HMONITOR StartupWindowMonitor() {
  POINT pointer{};
  if (GetCursorPos(&pointer)) {
    return MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST);
  }
  return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}

bool QueryStartupPanelBounds(HMONITOR monitor, RECT* bounds) {
  if (monitor == nullptr || bounds == nullptr) return false;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return false;

  // Flutter's utility uses the same monitor scaling as its rendering engine.
  // Coordinates from rcWork are already physical and must never be scaled.
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) dpi = 96;
  const int64_t width = (static_cast<int64_t>(kStartupPanelClientWidth) * dpi + 48) / 96;
  if (width > std::numeric_limits<int>::max()) return false;
  RECT frame{0, 0, static_cast<LONG>(width), 1};
  if (!AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi)) {
    return false;
  }
  const int64_t frame_width = static_cast<int64_t>(frame.right) - frame.left - width;
  if (frame_width < 0 || frame_width > std::numeric_limits<int>::max()) return false;

  PixelRect placement{};
  if (!CalculateStartupPanelBounds(
          {info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom},
          dpi, static_cast<int>(frame_width), &placement)) {
    return false;
  }
  *bounds = {placement.left, placement.top, placement.right, placement.bottom};
  return true;
}
#endif

}  // namespace honey
