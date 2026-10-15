#include "windows_tray_flags.h"

bool ValidWindowsTrayCountryCode(const std::string& code) {
  return code.empty() || (code.size() == 2 && code[0] >= 'A' && code[0] <= 'Z' &&
                         code[1] >= 'A' && code[1] <= 'Z');
}

#ifdef _WIN32
#include <algorithm>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

WindowsTrayFlagBitmaps::WindowsTrayFlagBitmaps(HWND window) {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  owns_com_ = SUCCEEDED(initialized);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) return;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory_)))) return;

  wchar_t executable[32768]{};
  const DWORD count = GetModuleFileNameW(nullptr, executable, 32768);
  if (count == 0 || count >= 32768) return;
  const std::wstring path(executable, count);
  const auto separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return;
  asset_root_ = path.substr(0, separator + 1) +
      L"data\\flutter_assets\\assets\\flags\\noto\\";

  // Match the monitor of the popup's owner, with a bounded 100–400% fallback.
  UINT dpi = window != nullptr ? GetDpiForWindow(window) : 96;
  dpi = std::clamp(dpi, 96u, 384u);
  width_ = static_cast<UINT>(MulDiv(20, static_cast<int>(dpi), 96));
  height_ = static_cast<UINT>(MulDiv(16, static_cast<int>(dpi), 96));
}

WindowsTrayFlagBitmaps::~WindowsTrayFlagBitmaps() {
  for (const auto& entry : bitmaps_) {
    if (entry.second != nullptr) DeleteObject(entry.second);
  }
  if (factory_ != nullptr) factory_->Release();
  if (owns_com_) CoUninitialize();
}

HBITMAP WindowsTrayFlagBitmaps::Get(const std::string& country_code) {
  if (country_code.empty() || !ValidWindowsTrayCountryCode(country_code)) return nullptr;
  const auto existing = bitmaps_.find(country_code);
  if (existing != bitmaps_.end()) return existing->second;
  const auto bitmap = Load(country_code);
  bitmaps_.emplace(country_code, bitmap);
  return bitmap;
}

HBITMAP WindowsTrayFlagBitmaps::Load(const std::string& country_code) {
  if (factory_ == nullptr || asset_root_.empty()) return nullptr;
  std::wstring path = asset_root_;
  for (const auto character : country_code) {
    path.push_back(static_cast<wchar_t>(character - 'A' + L'a'));
  }
  path += L".png";
  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes) ||
      (attributes.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      attributes.nFileSizeHigh != 0 || attributes.nFileSizeLow == 0 ||
      attributes.nFileSizeLow > 1024 * 1024) return nullptr;

  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICBitmapScaler> scaler;
  ComPtr<IWICFormatConverter> converter;
  GUID container{};
  UINT source_width = 0, source_height = 0;
  if (FAILED(factory_->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
      WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetContainerFormat(&container)) ||
      container != GUID_ContainerFormatPng || FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(frame->GetSize(&source_width, &source_height)) ||
      source_width == 0 || source_height == 0 || source_width > 512 || source_height > 512 ||
      FAILED(factory_->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(frame.Get(), width_, height_, WICBitmapInterpolationModeFant)) ||
      FAILED(factory_->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA,
          WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom))) return nullptr;

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = static_cast<LONG>(width_);
  info.bmiHeader.biHeight = -static_cast<LONG>(height_);
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  const auto bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (bitmap == nullptr || pixels == nullptr) {
    if (bitmap != nullptr) DeleteObject(bitmap);
    return nullptr;
  }
  const UINT stride = width_ * 4;
  if (FAILED(converter->CopyPixels(nullptr, stride, stride * height_,
                                  static_cast<BYTE*>(pixels)))) {
    DeleteObject(bitmap);
    return nullptr;
  }
  return bitmap;
}

bool SetWindowsTrayMenuBitmap(HMENU menu, UINT command, HBITMAP bitmap) {
  if (bitmap == nullptr) return true;  // Missing assets retain the text command.
  MENUITEMINFOW item{};
  item.cbSize = sizeof(item);
  item.fMask = MIIM_BITMAP;
  item.hbmpItem = bitmap;
  return SetMenuItemInfoW(menu, command, FALSE, &item) != FALSE;
}
#endif
