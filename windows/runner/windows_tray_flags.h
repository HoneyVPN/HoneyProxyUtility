#ifndef RUNNER_WINDOWS_TRAY_FLAGS_H_
#define RUNNER_WINDOWS_TRAY_FLAGS_H_

#include <string>

// Only an ISO presentation code crosses the channel, never a file path.
bool ValidWindowsTrayCountryCode(const std::string& code);

#ifdef _WIN32
#include <windows.h>
#include <wincodec.h>
#include <map>

// One popup owns its bitmaps. Destroy the menu before this cache is destroyed.
class WindowsTrayFlagBitmaps {
 public:
  explicit WindowsTrayFlagBitmaps(HWND window);
  ~WindowsTrayFlagBitmaps();
  WindowsTrayFlagBitmaps(const WindowsTrayFlagBitmaps&) = delete;
  WindowsTrayFlagBitmaps& operator=(const WindowsTrayFlagBitmaps&) = delete;
  HBITMAP Get(const std::string& country_code);

 private:
  HBITMAP Load(const std::string& country_code);
  bool owns_com_ = false;
  IWICImagingFactory* factory_ = nullptr;
  std::wstring asset_root_;
  UINT width_ = 20;
  UINT height_ = 16;
  std::map<std::string, HBITMAP> bitmaps_;
};

bool SetWindowsTrayMenuBitmap(HMENU menu, UINT command, HBITMAP bitmap);
#endif

#endif  // RUNNER_WINDOWS_TRAY_FLAGS_H_
