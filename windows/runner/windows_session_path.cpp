#include "windows_session_path.h"

#include <windows.h>

#include <filesystem>
#include <limits>
#include <vector>

namespace {
bool ReadTokenUser(HANDLE token, std::vector<BYTE>& bytes) {
  DWORD length = 0;
  if (GetTokenInformation(token, TokenUser, nullptr, 0, &length) ||
      GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 16384) {
    return false;
  }
  bytes.resize(length);
  return GetTokenInformation(token, TokenUser, bytes.data(), length, &length) != 0;
}
}  // namespace

bool OwnsInteractiveWindowsProxySettings() {
  const HWND shell = GetShellWindow();
  DWORD shell_pid = 0;
  if (shell == nullptr || GetWindowThreadProcessId(shell, &shell_pid) == 0 ||
      shell_pid == 0) {
    return false;
  }
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, shell_pid);
  if (process == nullptr) return false;
  HANDLE own_token = nullptr;
  HANDLE shell_token = nullptr;
  bool matches = false;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own_token) &&
      OpenProcessToken(process, TOKEN_QUERY, &shell_token)) {
    std::vector<BYTE> own;
    std::vector<BYTE> desktop;
    if (ReadTokenUser(own_token, own) && ReadTokenUser(shell_token, desktop)) {
      const auto* own_user = reinterpret_cast<const TOKEN_USER*>(own.data());
      const auto* desktop_user = reinterpret_cast<const TOKEN_USER*>(desktop.data());
      matches = IsValidSid(own_user->User.Sid) &&
          IsValidSid(desktop_user->User.Sid) &&
          EqualSid(own_user->User.Sid, desktop_user->User.Sid);
    }
  }
  if (shell_token != nullptr) CloseHandle(shell_token);
  if (own_token != nullptr) CloseHandle(own_token);
  CloseHandle(process);
  return matches;
}

bool IsWindowsSessionProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD returned = 0;
  const BOOL read = GetTokenInformation(token, TokenElevation, &elevation,
                                       sizeof(elevation), &returned);
  CloseHandle(token);
  return read && returned == sizeof(elevation) && elevation.TokenIsElevated != 0;
}

bool IsPlainWindowsSessionPath(const std::string& utf8_path) {
  if (utf8_path.empty() || utf8_path.find('\0') != std::string::npos ||
      utf8_path.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      utf8_path.data(),
                                      static_cast<int>(utf8_path.size()),
                                      nullptr, 0);
  if (size <= 0) return false;
  std::wstring wide(size, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_path.data(),
                        static_cast<int>(utf8_path.size()), wide.data(), size) !=
      size) {
    return false;
  }
  try {
    // App-support paths are absolute. Reject relative/device namespaces rather
    // than interpreting them against an unrelated process working directory.
    std::filesystem::path path(wide);
    if (!path.is_absolute() || wide.rfind(L"\\\\?\\", 0) == 0 ||
        wide.rfind(L"\\\\.\\", 0) == 0) {
      return false;
    }
    path = path.lexically_normal();
    for (;;) {
      const DWORD attributes = GetFileAttributesW(path.c_str());
      if (attributes == INVALID_FILE_ATTRIBUTES) {
        const DWORD error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) {
          return false;
        }
      } else if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return false;
      }
      const auto parent = path.parent_path();
      if (parent.empty() || parent == path) break;
      path = parent;
    }
    return true;
  } catch (...) {
    return false;
  }
}
