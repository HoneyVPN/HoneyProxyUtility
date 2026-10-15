#include "windows_service_client.h"

#include <winsvc.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

#include "windows_session_path.h"

namespace {
constexpr DWORD kMaximumFrame = 1024 * 1024;
constexpr DWORD kPipeClientAccess = 0x0012019B;
constexpr wchar_t kServiceName[] = L"HoneyVpnTunnelService";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\HoneyVpnTunnelService-v1";

#ifdef HONEY_SERVICE_CLIENT_TESTING
thread_local WindowsServiceProbeForTest* test_probe = nullptr;
thread_local const std::wstring* test_expected_image = nullptr;
void ProbeStage(const char* stage) {
  if (test_probe != nullptr) {
    test_probe->stage = stage;
    // Logical mismatches have no native error. Do not report an older API's
    // unrelated error as the reason for a later gate rejecting an identity.
    SetLastError(ERROR_SUCCESS);
  }
}
#define HONEY_PROBE_STAGE(stage) ProbeStage(stage)
#else
#define HONEY_PROBE_STAGE(stage) do {} while (false)
#endif

struct Handle {
  HANDLE value = nullptr;
  explicit Handle(HANDLE handle = nullptr) : value(handle) {}
  ~Handle() { if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};
struct ServiceHandle {
  SC_HANDLE value = nullptr;
  explicit ServiceHandle(SC_HANDLE handle) : value(handle) {}
  ~ServiceHandle() { if (value != nullptr) CloseServiceHandle(value); }
};

WindowsServiceReply Failure(const char* code = "serviceUnavailable") {
#ifdef HONEY_SERVICE_CLIENT_TESTING
  if (test_probe != nullptr) test_probe->win32_error = GetLastError();
#endif
  return WindowsServiceReply{"", code};
}

bool ValidUtf8(const std::string& text) {
  return !text.empty() && text.size() <= kMaximumFrame &&
      text.find('\0') == std::string::npos &&
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                         static_cast<int>(text.size()), nullptr, 0) > 0;
}

std::wstring ExpectedServiceImage() {
#ifdef HONEY_SERVICE_CLIENT_TESTING
  if (test_expected_image != nullptr) return *test_expected_image;
#endif
  std::vector<wchar_t> path(32768);
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
                                      static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) return {};
  std::wstring result(path.data(), size);
  const auto slash = result.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return {};
  return result.substr(0, slash + 1) + L"HoneyVpnService.exe";
}

bool SamePath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() &&
      CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(),
                           static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

bool IsInstalledServiceCommand(const std::wstring& image, const std::wstring& command) {
  return SamePath(command, L"\"" + image + L"\" --service");
}

std::string Utf8Path(const std::wstring& wide) {
  const int length = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
      static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string utf8(length, '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        utf8.data(), length, nullptr, nullptr) != length) return {};
  return utf8;
}

DWORD Remaining(ULONGLONG deadline) {
  const auto now = GetTickCount64();
  if (now >= deadline) return 0;
  return static_cast<DWORD>(std::min<ULONGLONG>(deadline - now, MAXDWORD - 1));
}

// Buffers/OVERLAPPED remain alive until cancellation actually completes. An
// API timeout never frees memory still referenced by an outstanding kernel IO.
bool Transfer(HANDLE pipe, HANDLE cancel, bool write, BYTE* bytes, DWORD length,
              ULONGLONG deadline) {
  DWORD offset = 0;
  while (offset < length) {
    if (Remaining(deadline) == 0 || WaitForSingleObject(cancel, 0) != WAIT_TIMEOUT) return false;
    Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
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
      const DWORD waited = WaitForMultipleObjects(2, events, FALSE, Remaining(deadline));
      if (waited != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &operation);
        // CancelIoEx only requests cancellation. Join the owned operation before
        // closing its event or destroying the frame buffer (Microsoft contract).
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

WindowsServiceReply CallPipe(const std::wstring& name, DWORD expected_pid,
                            HANDLE service_process, const std::string& request,
                            HANDLE cancel, DWORD timeout_ms) {
  if (!ValidUtf8(request)) return Failure();
  HONEY_PROBE_STAGE("pipeConnect");
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  HANDLE raw = INVALID_HANDLE_VALUE;
  while (Remaining(deadline) > 0 && WaitForSingleObject(cancel, 0) == WAIT_TIMEOUT) {
    raw = CreateFileW(name.c_str(), kPipeClientAccess, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (raw != INVALID_HANDLE_VALUE) break;
    const DWORD error = GetLastError();
    if (error == ERROR_ACCESS_DENIED) return Failure("serviceAccessDenied");
    if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND) return Failure();
    // Short waits also observe application shutdown promptly.
    if (error == ERROR_PIPE_BUSY) WaitNamedPipeW(name.c_str(), std::min<DWORD>(Remaining(deadline), 100));
    else WaitForSingleObject(cancel, std::min<DWORD>(Remaining(deadline), 50));
  }
  if (raw == INVALID_HANDLE_VALUE) return Failure();
  Handle pipe(raw);
  ULONG actual_pid = 0;
  HONEY_PROBE_STAGE("pipeServerIdentity");
  // No request bytes, nonce or configuration leave the UI before kernel pipe
  // identity matches the running trusted service's retained process object.
  if (expected_pid == 0 || !GetNamedPipeServerProcessId(pipe.value, &actual_pid) ||
      actual_pid != expected_pid ||
      (service_process != nullptr && WaitForSingleObject(service_process, 0) != WAIT_TIMEOUT)) {
    return Failure();
  }
  const auto length = static_cast<DWORD>(request.size());
  BYTE header[4] = {static_cast<BYTE>(length), static_cast<BYTE>(length >> 8),
                    static_cast<BYTE>(length >> 16), static_cast<BYTE>(length >> 24)};
  std::vector<BYTE> body(request.begin(), request.end());
  HONEY_PROBE_STAGE("pipeFrameExchange");
  if (!Transfer(pipe.value, cancel, true, header, 4, deadline) ||
      !Transfer(pipe.value, cancel, true, body.data(), length, deadline) ||
      !Transfer(pipe.value, cancel, false, header, 4, deadline)) return Failure();
  const DWORD response_length = static_cast<DWORD>(header[0]) |
      (static_cast<DWORD>(header[1]) << 8) | (static_cast<DWORD>(header[2]) << 16) |
      (static_cast<DWORD>(header[3]) << 24);
  HONEY_PROBE_STAGE("replyLength");
  if (response_length == 0 || response_length > kMaximumFrame) return Failure();
  body.resize(response_length);
  HONEY_PROBE_STAGE("replyBody");
  if (!Transfer(pipe.value, cancel, false, body.data(), response_length, deadline)) return Failure();
  std::string response(body.begin(), body.end());
  HONEY_PROBE_STAGE("replyUtf8");
  if (!ValidUtf8(response)) return Failure();
  HONEY_PROBE_STAGE("replyReceived");
  return WindowsServiceReply{std::move(response), ""};
}

WindowsServiceReply CallService(const std::string& request, HANDLE cancel) {
  HONEY_PROBE_STAGE("requestUtf8");
  if (!ValidUtf8(request)) return Failure();
  HONEY_PROBE_STAGE("openScm");
  ServiceHandle manager(OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT));
  if (manager.value == nullptr) return Failure(GetLastError() == ERROR_ACCESS_DENIED ? "serviceAccessDenied" : "serviceUnavailable");
  HONEY_PROBE_STAGE("openService");
  ServiceHandle service(OpenServiceW(manager.value, kServiceName,
                                     SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG));
  if (service.value == nullptr) {
    const DWORD error = GetLastError();
    if (error == ERROR_SERVICE_DOES_NOT_EXIST) return Failure("serviceNotInstalled");
    return Failure(error == ERROR_ACCESS_DENIED ? "serviceAccessDenied" : "serviceUnavailable");
  }
  SERVICE_STATUS_PROCESS status{};
  DWORD returned = 0;
  HONEY_PROBE_STAGE("serviceStatus");
  const BOOL status_read = QueryServiceStatusEx(service.value, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<BYTE*>(&status), sizeof(status), &returned);
#ifdef HONEY_SERVICE_CLIENT_TESTING
  if (test_probe != nullptr) {
    test_probe->service_pid = status.dwProcessId;
    test_probe->service_state = status.dwCurrentState;
  }
#endif
  if (!status_read || status.dwCurrentState != SERVICE_RUNNING ||
      status.dwProcessId == 0) return Failure();
  HONEY_PROBE_STAGE("openServiceProcess");
  Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                             FALSE, status.dwProcessId));
  if (process.value == nullptr) {
    const auto failure = Failure();
#ifdef HONEY_SERVICE_CLIENT_TESTING
    if (test_probe != nullptr) {
      test_probe->query_limited_attempted = true;
      Handle limited(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                 FALSE, status.dwProcessId));
      test_probe->query_limited_opened = limited.value != nullptr;
      if (limited.value == nullptr) test_probe->query_limited_error = GetLastError();
      else {
        std::vector<wchar_t> limited_image(32768);
        DWORD length = static_cast<DWORD>(limited_image.size());
        if (!QueryFullProcessImageNameW(limited.value, 0, limited_image.data(), &length)) {
          test_probe->query_limited_image_error = GetLastError();
        } else {
          test_probe->query_limited_image_matches = SamePath(
              std::wstring(limited_image.data(), length), ExpectedServiceImage());
        }
      }
    }
#endif
    return failure;
  }
  std::vector<wchar_t> image(32768);
  DWORD image_length = static_cast<DWORD>(image.size());
  const auto expected_image = ExpectedServiceImage();
  HONEY_PROBE_STAGE("serviceImage");
  if (!IsPlainWindowsSessionPath(Utf8Path(expected_image)) ||
      !QueryFullProcessImageNameW(process.value, 0, image.data(), &image_length) ||
      !SamePath(std::wstring(image.data(), image_length), expected_image)) return Failure();
  DWORD config_size = 0;
  HONEY_PROBE_STAGE("serviceConfigSize");
  QueryServiceConfigW(service.value, nullptr, 0, &config_size);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || config_size == 0 || config_size > 65536) return Failure();
  std::vector<BYTE> config_bytes(config_size);
  auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(config_bytes.data());
  HONEY_PROBE_STAGE("serviceConfig");
  if (!QueryServiceConfigW(service.value, config, config_size, &config_size)) return Failure();
  // The installer registers the one fixed quoted executable and service mode.
  const std::wstring registered(config->lpBinaryPathName);
  HONEY_PROBE_STAGE("serviceCommand");
  if (!IsInstalledServiceCommand(expected_image, registered)) return Failure();
  SERVICE_STATUS_PROCESS fresh{};
  HONEY_PROBE_STAGE("serviceStatusRecheck");
  if (!QueryServiceStatusEx(service.value, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<BYTE*>(&fresh), sizeof(fresh), &returned) ||
      fresh.dwCurrentState != SERVICE_RUNNING ||
      fresh.dwProcessId != status.dwProcessId ||
      WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) return Failure();
  return CallPipe(kPipeName, status.dwProcessId, process.value, request, cancel, 8000);
}
}  // namespace

WindowsServiceClient::WindowsServiceClient(std::function<void()> notify)
    : notify_(std::move(notify)), cancel_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
  if (cancel_ != nullptr) worker_ = std::thread([this] { Run(); });
}
WindowsServiceClient::~WindowsServiceClient() { Shutdown(); }

void WindowsServiceClient::Request(std::string request, Reply reply) {
  bool rejected = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || cancel_ == nullptr || pending_.size() >= 32) rejected = true;
    else pending_.push_back(Pending{std::move(request), std::move(reply)});
  }
  if (rejected) { reply(Failure()); return; }
  wake_.notify_one();
}

void WindowsServiceClient::Run() {
  for (;;) {
    Pending request;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this] { return stopping_ || !pending_.empty(); });
      if (stopping_) return;
      request = std::move(pending_.front());
      pending_.pop_front();
    }
    WindowsServiceReply response;
    try { response = CallService(request.request, cancel_); }
    catch (...) { response = Failure(); }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      completed_.push_back(Completed{std::move(response), std::move(request.reply)});
    }
    notify_();
  }
}

void WindowsServiceClient::DrainRepliesUI() {
  std::deque<Completed> replies;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    replies.swap(completed_);
  }
  for (auto& reply : replies) reply.reply(std::move(reply.response));
}

void WindowsServiceClient::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    stopping_ = true;
    pending_.clear();
    completed_.clear();
  }
  if (cancel_ != nullptr) SetEvent(cancel_);
  wake_.notify_all();
  if (worker_.joinable()) worker_.join();
  if (cancel_ != nullptr) { CloseHandle(cancel_); cancel_ = nullptr; }
}

#ifdef HONEY_SERVICE_CLIENT_TESTING
WindowsServiceReply CallWindowsServiceTestPipe(const std::wstring& pipe,
    DWORD expected_pid, const std::string& request, HANDLE cancel, DWORD timeout_ms) {
  return CallPipe(pipe, expected_pid, nullptr, request, cancel, timeout_ms);
}
WindowsServiceReply QueryWindowsServiceForTest(const std::string& request) {
  Handle cancel(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (cancel.value == nullptr) return Failure();
  return CallService(request, cancel.value);
}
bool IsWindowsServiceCommandForTest(const std::wstring& expected_image,
                                   const std::wstring& registered) {
  return IsInstalledServiceCommand(expected_image, registered);
}
WindowsServiceProbeForTest ProbeInstalledWindowsServiceReadActiveForTest(
    const std::wstring& expected_image) {
  WindowsServiceProbeForTest result;
  // No caller-supplied operation, pipe name or PID: this mode can only inspect
  // the one installed service, with all production authentication gates intact.
  Handle cancel(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (cancel.value == nullptr) {
    result.stage = "cancelEvent";
    result.win32_error = GetLastError();
    result.reply = Failure();
    return result;
  }
  struct ProbeScope {
    ProbeScope(WindowsServiceProbeForTest* probe, const std::wstring* image) {
      test_probe = probe;
      test_expected_image = image;
    }
    ~ProbeScope() { test_probe = nullptr; test_expected_image = nullptr; }
  } scope(&result, &expected_image);
  result.reply = CallService("{\"version\":1,\"operation\":\"readActive\"}", cancel.value);
  return result;
}
#endif
