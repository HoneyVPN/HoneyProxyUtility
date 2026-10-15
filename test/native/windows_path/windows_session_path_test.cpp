#include "../../../windows/runner/windows_session_path.h"

#include <windows.h>
#include <wininet.h>

#include <iostream>
#include <string>

static_assert(sizeof(INTERNET_PER_CONN_OPTIONW) == 16, "Proxy option x64 ABI");
static_assert(sizeof(INTERNET_PER_CONN_OPTION_LISTW) == 32, "Proxy option list x64 ABI");

std::string Utf8(const wchar_t* value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                      nullptr, nullptr);
  if (size <= 0) return {};
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, out.data(), size, nullptr, nullptr);
  out.pop_back();
  return out;
}

bool HasUnelevatedUiManifest(const wchar_t* application) {
  HMODULE image = LoadLibraryExW(application, nullptr,
      LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
  if (image == nullptr) return false;
  HRSRC resource = FindResourceW(image, MAKEINTRESOURCEW(1), MAKEINTRESOURCEW(24));
  HGLOBAL loaded = resource ? LoadResource(image, resource) : nullptr;
  const auto* data = loaded ? static_cast<const char*>(LockResource(loaded)) : nullptr;
  const DWORD length = resource ? SizeofResource(image, resource) : 0;
  std::string manifest;
  if (data != nullptr && length > 0) manifest.assign(data, length);
  FreeLibrary(image);
  return manifest.find("requestedExecutionLevel") != std::string::npos &&
      (manifest.find("level=\"asInvoker\"") != std::string::npos ||
       manifest.find("level='asInvoker'") != std::string::npos) &&
      manifest.find("requireAdministrator") == std::string::npos &&
      manifest.find("highestAvailable") == std::string::npos;
}

int wmain(int argc, wchar_t* argv[]) {
  if (argc != 4) return 2;
  const auto plain = Utf8(argv[1]);
  const auto junction = Utf8(argv[2]);
  struct Test { std::string path; bool expected; const char* name; };
  const Test tests[] = {
      {plain, true, "existing Unicode directory"},
      {plain + "/fixture.json", true, "existing plain file"},
      {plain + "/not-yet-created/session/state.json", true,
       "missing ordinary descendants"},
      {junction, false, "junction itself"},
      {junction + "/fixture.json", false, "junction ancestor"},
      {junction + "/absent/config.json", false,
       "missing descendant cannot hide a junction"},
      {"relative/state.json", false, "relative path"},
      {std::string("\xff\xfe", 2), false, "invalid UTF-8"},
      {plain + std::string("\0suffix", 7), false, "embedded NUL"},
      {"\\\\.\\NUL", false, "device namespace"},
      {"\\\\?\\" + plain, false, "extended device namespace"},
  };
  for (const auto& test : tests) {
    if (IsPlainWindowsSessionPath(test.path) != test.expected) {
      std::cerr << "FAIL " << test.name << '\n';
      return 1;
    }
    std::cout << "PASS " << test.name << '\n';
  }
  if (!HasUnelevatedUiManifest(argv[3])) {
    std::cerr << "FAIL packaged UI must run without elevation\n";
    return 1;
  }
  std::cout << "PASS packaged UI runs without elevation\n";
  // Read-only: the fixture never requests UAC or changes its own token.
  std::cout << "PASS native token query executed (fixture elevated="
            << IsWindowsSessionProcessElevated() << ")\n";
  std::cout << "PASS native desktop-account query executed (fixture ownsProxy="
            << OwnsInteractiveWindowsProxySettings() << ")\n";
  return 0;
}
