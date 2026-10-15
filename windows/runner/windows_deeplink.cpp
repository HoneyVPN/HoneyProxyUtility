#include "windows_deeplink.h"

#include <algorithm>
#include <cstdint>
#include <utility>

#ifdef _WIN32
#include <sddl.h>
#endif

namespace {
bool ValidUtf8(const std::string& text) {
  // Reject invalid UTF-8 even in the portable geometry/argument fixture.
  size_t i = 0;
  while (i < text.size()) {
    const auto first = static_cast<unsigned char>(text[i++]);
    if (first < 0x80) continue;
    uint32_t value;
    size_t extra;
    if (first >= 0xc2 && first <= 0xdf) { value = first & 0x1f; extra = 1; }
    else if (first >= 0xe0 && first <= 0xef) { value = first & 0x0f; extra = 2; }
    else if (first >= 0xf0 && first <= 0xf4) { value = first & 7; extra = 3; }
    else return false;
    if (text.size() - i < extra) return false;
    for (size_t j = 0; j < extra; ++j) {
      const auto next = static_cast<unsigned char>(text[i++]);
      if ((next & 0xc0) != 0x80) return false;
      value = (value << 6) | (next & 0x3f);
    }
    if ((extra == 2 && value < 0x800) || (extra == 3 && value < 0x10000) ||
        value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
  }
  return true;
}
}  // namespace

bool IsWindowsImportLink(const std::string& link) {
  constexpr char prefix[] = "honeyvpn://import";
  constexpr size_t prefix_length = sizeof(prefix) - 1;
  if (link.size() <= prefix_length || link.size() > kMaximumWindowsDeepLinkBytes ||
      link.compare(0, prefix_length, prefix) != 0 || !ValidUtf8(link)) return false;
  // The shared URI validator permits an empty path or one slash. Shell/browser
  // activation may supply that slash; carry the original envelope unchanged.
  size_t query = prefix_length;
  if (link[query] == '/') ++query;
  if (query >= link.size() || link[query] != '?' || query + 1 >= link.size()) return false;
  for (const auto character : link) {
    const auto value = static_cast<unsigned char>(character);
    // The registered command quotes one URI argument. Raw quoting, whitespace,
    // backslashes and controls cannot smuggle a second native argument.
    if (value <= 0x20 || value == 0x7f || character == '"' || character == '\\') return false;
  }
  return true;
}

WindowsLinkArguments ParseWindowsLinkArguments(
    const std::vector<std::string>& arguments, std::string* link) {
  if (link == nullptr) return WindowsLinkArguments::kInvalid;
  link->clear();
  if (arguments.empty()) return WindowsLinkArguments::kActivate;
  if (arguments.size() != 2 || arguments[0] != "--import-link" ||
      !IsWindowsImportLink(arguments[1])) return WindowsLinkArguments::kInvalid;
  *link = arguments[1];
  return WindowsLinkArguments::kImport;
}

bool WindowsLinkQueue::Push(std::string link) {
  if (!link.empty() && !IsWindowsImportLink(link)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!link.empty() && std::find(links_.begin(), links_.end(), link) == links_.end()) {
    if (links_.size() >= kMaximumPendingWindowsDeepLinks) return false;
    links_.push_back(std::move(link));
  }
  activation_ = true;
  return true;
}

bool WindowsLinkQueue::TakeActivation() {
  std::lock_guard<std::mutex> lock(mutex_);
  const bool result = activation_;
  activation_ = false;
  return result;
}

std::vector<std::string> WindowsLinkQueue::TakeLinks() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<std::string> result(links_.begin(), links_.end());
  links_.clear();
  return result;
}

#ifdef _WIN32
namespace {
constexpr DWORD kPipeClientAccess = 0x0012019b;  // Excludes CREATE_PIPE_INSTANCE.
constexpr DWORD kFrameTimeoutMs = 3000;

struct OwnedHandle {
  HANDLE value = nullptr;
  explicit OwnedHandle(HANDLE handle = nullptr) : value(handle) {}
  ~OwnedHandle() { if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  OwnedHandle(const OwnedHandle&) = delete;
  OwnedHandle& operator=(const OwnedHandle&) = delete;
};

bool SameImage(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() &&
      CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(),
                           static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

bool ProcessIdentity(HANDLE process, std::wstring* sid, DWORD* session,
                     std::wstring* image) {
  OwnedHandle token;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return false;
  DWORD length = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &length);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 65536) return false;
  std::vector<BYTE> buffer(length);
  if (!GetTokenInformation(token.value, TokenUser, buffer.data(), length, &length)) return false;
  auto* user = reinterpret_cast<TOKEN_USER*>(buffer.data());
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &text)) return false;
  *sid = text;
  LocalFree(text);
  if (!GetTokenInformation(token.value, TokenSessionId, session, sizeof(*session), &length)) return false;
  std::vector<wchar_t> path(32768);
  DWORD size = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &size) || size == 0) return false;
  *image = std::wstring(path.data(), size);
  return true;
}

HANDLE AuthenticatedProcess(DWORD pid, const std::wstring& sid, DWORD session,
                            const std::wstring& image) {
  if (pid == 0) return nullptr;
  OwnedHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid));
  if (process.value == nullptr || WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) return nullptr;
  std::wstring actual_sid, actual_image;
  DWORD actual_session = 0;
  if (!ProcessIdentity(process.value, &actual_sid, &actual_session, &actual_image) ||
      actual_sid != sid || actual_session != session || !SameImage(actual_image, image) ||
      WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) return nullptr;
  HANDLE result = process.value;
  process.value = nullptr;
  return result;
}

DWORD Remaining(ULONGLONG deadline) {
  const auto now = GetTickCount64();
  return now >= deadline ? 0 : static_cast<DWORD>((std::min<ULONGLONG>)(deadline - now, MAXDWORD - 1));
}

bool Transfer(HANDLE pipe, HANDLE cancel, bool write, BYTE* bytes, DWORD length,
              ULONGLONG deadline) {
  DWORD offset = 0;
  while (offset < length) {
    if (Remaining(deadline) == 0 || WaitForSingleObject(cancel, 0) != WAIT_TIMEOUT) return false;
    OwnedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (event.value == nullptr) return false;
    OVERLAPPED operation{};
    operation.hEvent = event.value;
    DWORD count = 0;
    const BOOL immediate = write
        ? WriteFile(pipe, bytes + offset, length - offset, &count, &operation)
        : ReadFile(pipe, bytes + offset, length - offset, &count, &operation);
    if (!immediate) {
      if (GetLastError() != ERROR_IO_PENDING) return false;
      const HANDLE events[] = {event.value, cancel};
      if (WaitForMultipleObjects(2, events, FALSE, Remaining(deadline)) != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &operation);
        // Cancellation must complete before its OVERLAPPED and buffer die.
        GetOverlappedResult(pipe, &operation, &count, TRUE);
        return false;
      }
      if (!GetOverlappedResult(pipe, &operation, &count, FALSE)) return false;
    }
    if (count == 0 || count > length - offset) return false;
    offset += count;
  }
  return true;
}

bool WaitForClient(HANDLE pipe, HANDLE cancel) {
  OwnedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (event.value == nullptr) return false;
  OVERLAPPED operation{};
  operation.hEvent = event.value;
  const BOOL immediate = ConnectNamedPipe(pipe, &operation);
  if (immediate || GetLastError() == ERROR_PIPE_CONNECTED) return true;
  if (GetLastError() != ERROR_IO_PENDING) return false;
  const HANDLE events[] = {event.value, cancel};
  if (WaitForMultipleObjects(2, events, FALSE, INFINITE) != WAIT_OBJECT_0) {
    CancelIoEx(pipe, &operation);
    DWORD ignored = 0;
    GetOverlappedResult(pipe, &operation, &ignored, TRUE);
    return false;
  }
  DWORD ignored = 0;
  return GetOverlappedResult(pipe, &operation, &ignored, FALSE) != FALSE;
}

HANDLE CreateSecuredMutex(const std::wstring& name, const std::wstring& sid) {
  const auto descriptor_text = L"O:" + sid + L"D:P(A;;GA;;;SY)(A;;GA;;;" + sid + L")";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor_text.c_str(),
      SDDL_REVISION_1, &descriptor, nullptr)) return nullptr;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  HANDLE result = CreateMutexW(&attributes, TRUE, name.c_str());
  const DWORD error = GetLastError();
  LocalFree(descriptor);
  SetLastError(error);
  return result;
}

HANDLE CreateSecuredPipe(const std::wstring& name, const std::wstring& sid) {
  const auto descriptor_text = L"O:" + sid + L"D:P(A;;GA;;;SY)(A;;0x0012019b;;;" + sid + L")";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor_text.c_str(),
      SDDL_REVISION_1, &descriptor, nullptr)) return INVALID_HANDLE_VALUE;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  HANDLE result = CreateNamedPipeW(name.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
      1, 4096, 4096, 0, &attributes);
  LocalFree(descriptor);
  return result;
}
}  // namespace

WindowsDeepLinkBroker::WindowsDeepLinkBroker() = default;
#ifdef HONEY_DEEPLINK_TESTING
WindowsDeepLinkBroker::WindowsDeepLinkBroker(std::wstring test_namespace)
    : test_namespace_(std::move(test_namespace)) {}
bool AuthenticateWindowsLinkPeerForTest(DWORD pid, const std::wstring& sid,
                                       DWORD session, const std::wstring& image) {
  OwnedHandle process(AuthenticatedProcess(pid, sid, session, image));
  return process.value != nullptr;
}
#endif
WindowsDeepLinkBroker::~WindowsDeepLinkBroker() { Shutdown(); }

WindowsLinkLaunch WindowsDeepLinkBroker::StartOrForward(const std::vector<std::string>& arguments) {
  std::string link;
  if (ParseWindowsLinkArguments(arguments, &link) == WindowsLinkArguments::kInvalid)
    return WindowsLinkLaunch::kRejected;
  if (mutex_ != nullptr || !ProcessIdentity(GetCurrentProcess(), &sid_, &session_, &image_))
    return WindowsLinkLaunch::kUnavailable;
  const auto scope = L"HoneyProxyUtility-Launch-v1-" + sid_ + L"-" + std::to_wstring(session_) + test_namespace_;
  mutex_name_ = L"Local\\" + scope;
  pipe_name_ = L"\\\\.\\pipe\\" + scope;
  cancel_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (cancel_ == nullptr) return WindowsLinkLaunch::kUnavailable;
  mutex_ = CreateSecuredMutex(mutex_name_, sid_);
  const bool existed = GetLastError() == ERROR_ALREADY_EXISTS;
  if (mutex_ == nullptr) { Shutdown(); return WindowsLinkLaunch::kUnavailable; }
  if (existed) {
    const auto wait = WaitForSingleObject(mutex_, 0);
    if (wait == WAIT_TIMEOUT) {
      const bool forwarded = Forward(link);
      Shutdown();
      return forwarded ? WindowsLinkLaunch::kForwarded : WindowsLinkLaunch::kUnavailable;
    }
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      Shutdown(); return WindowsLinkLaunch::kUnavailable;
    }
  }
  owns_mutex_ = true;
  pipe_ = CreateSecuredPipe(pipe_name_, sid_);
  if (pipe_ == INVALID_HANDLE_VALUE || (!link.empty() && !queue_.Push(link))) {
    Shutdown(); return WindowsLinkLaunch::kUnavailable;
  }
  worker_ = std::thread([this] { Listen(); });
  return WindowsLinkLaunch::kPrimary;
}

bool WindowsDeepLinkBroker::Forward(const std::string& link) {
  const ULONGLONG deadline = GetTickCount64() + 5000;
  HANDLE raw = INVALID_HANDLE_VALUE;
  while (Remaining(deadline) != 0) {
    raw = CreateFileW(pipe_name_.c_str(), kPipeClientAccess, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (raw != INVALID_HANDLE_VALUE) break;
    const DWORD error = GetLastError();
    if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND) return false;
    if (error == ERROR_PIPE_BUSY) WaitNamedPipeW(pipe_name_.c_str(), (std::min<DWORD>)(Remaining(deadline), 100));
    else WaitForSingleObject(cancel_, (std::min<DWORD>)(Remaining(deadline), 50));
  }
  if (raw == INVALID_HANDLE_VALUE) return false;
  OwnedHandle pipe(raw);
  ULONG pid = 0;
  if (!GetNamedPipeServerProcessId(pipe.value, &pid)) return false;
  OwnedHandle process(AuthenticatedProcess(pid, sid_, session_, image_));
  // No URL bytes leave this process before the kernel peer is authenticated.
  if (process.value == nullptr) return false;
  AllowSetForegroundWindow(pid);
  const DWORD length = static_cast<DWORD>(link.size());
  BYTE header[4] = {static_cast<BYTE>(length), static_cast<BYTE>(length >> 8),
                    static_cast<BYTE>(length >> 16), static_cast<BYTE>(length >> 24)};
  std::vector<BYTE> body(link.begin(), link.end());
  BYTE accepted = 0;
  if (!Transfer(pipe.value, cancel_, true, header, 4, deadline) ||
      (length != 0 && !Transfer(pipe.value, cancel_, true, body.data(), length, deadline)) ||
      !Transfer(pipe.value, cancel_, false, &accepted, 1, deadline)) return false;
  BYTE receipt = 1;
  return Transfer(pipe.value, cancel_, true, &receipt, 1, deadline) && accepted == 1;
}

void WindowsDeepLinkBroker::Listen() {
  while (WaitForSingleObject(cancel_, 0) == WAIT_TIMEOUT) {
    if (!WaitForClient(pipe_, cancel_)) {
      if (WaitForSingleObject(cancel_, 0) != WAIT_TIMEOUT) return;
      // A client can close between opening the pipe and ConnectNamedPipe. That
      // transient ERROR_NO_DATA must not disable every future import request.
      DisconnectNamedPipe(pipe_);
      WaitForSingleObject(cancel_, 50);
      continue;
    }
    const ULONGLONG deadline = GetTickCount64() + kFrameTimeoutMs;
    ULONG pid = 0;
    OwnedHandle process(GetNamedPipeClientProcessId(pipe_, &pid)
        ? AuthenticatedProcess(pid, sid_, session_, image_) : nullptr);
    BYTE accepted = 0;
    if (process.value != nullptr) {
      BYTE header[4]{};
      if (Transfer(pipe_, cancel_, false, header, 4, deadline)) {
        const DWORD length = static_cast<DWORD>(header[0]) |
            (static_cast<DWORD>(header[1]) << 8) | (static_cast<DWORD>(header[2]) << 16) |
            (static_cast<DWORD>(header[3]) << 24);
        if (length <= kMaximumWindowsDeepLinkBytes) {
          std::vector<BYTE> body(length);
          if (length == 0 || Transfer(pipe_, cancel_, false, body.data(), length, deadline)) {
            const std::string link(body.begin(), body.end());
            if (WaitForSingleObject(process.value, 0) == WAIT_TIMEOUT && queue_.Push(link)) {
              accepted = 1;
              Notify();
            }
          }
        }
      }
      if (Transfer(pipe_, cancel_, true, &accepted, 1, deadline)) {
        BYTE receipt = 0;
        Transfer(pipe_, cancel_, false, &receipt, 1, deadline);
      }
    }
    DisconnectNamedPipe(pipe_);
  }
}

void WindowsDeepLinkBroker::AttachWindow(HWND window) {
  window_.store(window);
  if (window != nullptr) Notify();
}
void WindowsDeepLinkBroker::Notify() {
  HWND window = window_.load();
  if (window != nullptr) PostMessageW(window, kWindowsDeepLinkMessage, 0, 0);
}
bool WindowsDeepLinkBroker::TakeActivation() { return queue_.TakeActivation(); }
std::vector<std::string> WindowsDeepLinkBroker::TakeLinks() { return queue_.TakeLinks(); }
void WindowsDeepLinkBroker::Shutdown() {
  AttachWindow(nullptr);
  if (cancel_ != nullptr) SetEvent(cancel_);
  if (worker_.joinable()) worker_.join();
  if (pipe_ != INVALID_HANDLE_VALUE) { CloseHandle(pipe_); pipe_ = INVALID_HANDLE_VALUE; }
  if (owns_mutex_ && mutex_ != nullptr) ReleaseMutex(mutex_);
  owns_mutex_ = false;
  if (mutex_ != nullptr) { CloseHandle(mutex_); mutex_ = nullptr; }
  if (cancel_ != nullptr) { CloseHandle(cancel_); cancel_ = nullptr; }
}
#endif
