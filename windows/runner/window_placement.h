#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <cstdint>

#ifdef _WIN32
#include <windows.h>
#endif

namespace honey {

// Signed physical pixels in the virtual desktop, including monitors left of
// or above the primary display. The outer height includes the native title bar.
struct PixelRect {
  int left;
  int top;
  int right;
  int bottom;
};

constexpr int kStartupPanelClientWidth = 520;

// The caller supplies the DPI-specific total horizontal frame width. Keeping
// this calculation separate makes multi-monitor geometry testable without UI.
bool CalculateStartupPanelBounds(const PixelRect& work_area, uint32_t dpi,
                                 int horizontal_frame_width, PixelRect* bounds);

#ifdef _WIN32
// Uses the monitor containing the pointer, or the primary monitor when the
// current input desktop cannot expose the pointer position.
HMONITOR StartupWindowMonitor();
bool QueryStartupPanelBounds(HMONITOR monitor, RECT* bounds);
#endif

}  // namespace honey

#endif  // RUNNER_WINDOW_PLACEMENT_H_
