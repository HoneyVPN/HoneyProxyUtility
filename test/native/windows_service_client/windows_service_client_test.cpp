#include "../../../windows/runner/windows_service_client.h"

#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

namespace {
struct OwnedHandle {
  HANDLE value = nullptr;
  ~OwnedHandle() { if (value != nullptr) CloseHandle(value); }
  OwnedHandle() = default;
  OwnedHandle(const OwnedHandle&) = delete;
  OwnedHandle& operator=(const OwnedHandle&) = delete;
};

std::vector<BYTE> TokenInformation(HANDLE token, TOKEN_INFORMATION_CLASS kind) {
  DWORD length = 0;
  Require(!GetTokenInformation(token, kind, nullptr, 0, &length) &&
      GetLastError() == ERROR_INSUFFICIENT_BUFFER && length > 0 && length <= 16384,
      "bounded token metadata size");
  std::vector<BYTE> bytes(length);
  Require(GetTokenInformation(token, kind, bytes.data(), length, &length) != FALSE,
      "read token metadata");
  return bytes;
}

struct OwnerImpersonation {
  explicit OwnerImpersonation(HANDLE token) {
    Require(ImpersonateLoggedOnUser(token) != FALSE,
        "impersonate effective medium owner token without elevated fallback");
  }
  ~OwnerImpersonation() {
    // An inability to restore the original token must never continue a test
    // under an unintended identity.
    if (!RevertToSelf()) std::terminate();
  }
  OwnerImpersonation(const OwnerImpersonation&) = delete;
  OwnerImpersonation& operator=(const OwnerImpersonation&) = delete;
};

int InstalledServiceProbe(const std::wstring& image, bool assert_idle) {
  OwnedHandle previous;
  Require(!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &previous.value) &&
      GetLastError() == ERROR_NO_TOKEN, "probe starts without existing impersonation");
  OwnedHandle source;
  Require(OpenProcessToken(GetCurrentProcess(),
      TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ADJUST_DEFAULT, &source.value) != FALSE,
      "open own token for local restricted copy");
  const auto own = TokenInformation(source.value, TokenUser);

  BYTE admin[SECURITY_MAX_SID_SIZE]{};
  DWORD admin_length = sizeof(admin);
  Require(CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, admin,
      &admin_length) != FALSE, "build administrator SID for deny-only copy");
  SID_AND_ATTRIBUTES disabled{admin, 0};
  OwnedHandle restricted;
  Require(CreateRestrictedToken(source.value, DISABLE_MAX_PRIVILEGE, 1,
      &disabled, 0, nullptr, 0, nullptr, &restricted.value) != FALSE,
      "create same-owner token with administrator SID disabled and privileges removed");
  BYTE medium[SECURITY_MAX_SID_SIZE]{};
  DWORD medium_length = sizeof(medium);
  Require(CreateWellKnownSid(WinMediumLabelSid, nullptr, medium, &medium_length) != FALSE,
      "build medium integrity SID");
  TOKEN_MANDATORY_LABEL label{};
  label.Label.Sid = medium;
  label.Label.Attributes = SE_GROUP_INTEGRITY;
  Require(SetTokenInformation(restricted.value, TokenIntegrityLevel, &label,
      static_cast<DWORD>(sizeof(label)) + GetLengthSid(medium)) != FALSE,
      "set copied token to medium integrity");

  // Only this synchronous test thread uses the reduced token. The installed
  // service/SCM, registry/pipe/process ACLs, primary token and VPN remain intact.
  OwnerImpersonation impersonation(restricted.value);
  OwnedHandle effective;
  Require(OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &effective.value) != FALSE,
      "read effective restricted token");
  const auto user = TokenInformation(effective.value, TokenUser);
  const auto* own_user = reinterpret_cast<const TOKEN_USER*>(own.data());
  const auto* effective_user = reinterpret_cast<const TOKEN_USER*>(user.data());
  Require(IsValidSid(own_user->User.Sid) && IsValidSid(effective_user->User.Sid) &&
      EqualSid(own_user->User.Sid, effective_user->User.Sid), "effective token retains original owner SID");
  const auto integrity = TokenInformation(effective.value, TokenIntegrityLevel);
  const auto* mandatory = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(integrity.data());
  Require(IsValidSid(mandatory->Label.Sid) &&
      *GetSidSubAuthorityCount(mandatory->Label.Sid) > 0,
      "effective token has valid integrity label");
  const DWORD rid = *GetSidSubAuthority(mandatory->Label.Sid,
      *GetSidSubAuthorityCount(mandatory->Label.Sid) - 1);
  Require(rid == SECURITY_MANDATORY_MEDIUM_RID, "effective token is exactly medium integrity");
  BOOL administrator = TRUE;
  Require(CheckTokenMembership(nullptr, admin, &administrator) != FALSE &&
      administrator == FALSE, "administrator group cannot grant access to effective token");

  const auto probe = ProbeInstalledWindowsServiceReadActiveForTest(image);
  const bool idle = probe.reply.error.empty() &&
      probe.reply.json == "{\"version\":1,\"ok\":true,\"result\":null}";
  // Never print reply JSON: a running session can contain a nonce and paths.
  std::cout << "HNSP mode=" << (assert_idle ? "assert-idle" : "diagnostic")
      << " effectiveMedium=1 effectiveAdmin=0 sameOwner=1"
      << " serviceState=" << probe.service_state << " servicePid=" << probe.service_pid
      << " stage=" << probe.stage << " win32=" << probe.win32_error
      << " queryLimitedAttempted=" << probe.query_limited_attempted
      << " queryLimitedOpened=" << probe.query_limited_opened
      << " queryLimitedError=" << probe.query_limited_error
      << " queryLimitedImageMatches=" << probe.query_limited_image_matches
      << " queryLimitedImageError=" << probe.query_limited_image_error
      << " replyPresent=" << !probe.reply.json.empty() << " readActiveNull=" << idle
      << " error=" << (probe.reply.error.empty() ? "none" : probe.reply.error) << '\n';
  if (assert_idle) {
    Require(idle, "installed service authenticates medium owner readActive and reports idle");
    std::cout << "PASS installed LocalSystem service authenticated readActive under effective medium owner token\n";
  }
  return 0;
}
}  // namespace

class PipeFixture {
 public:
  enum Mode { valid, wrong_pid, oversized, zero, invalid_utf8, partial, stalled };
  std::wstring name;
  DWORD received = 0;
  explicit PipeFixture(Mode mode) {
    static unsigned counter = 0;
    name = L"\\\\.\\pipe\\honey-service-client-fixture-" +
        std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(++counter);
    pipe_ = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, 4096, 4096, 1000, nullptr);
    Require(pipe_ != INVALID_HANDLE_VALUE, "create owned dummy pipe");
    thread_ = std::thread([this, mode] {
      if (!ConnectNamedPipe(pipe_, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) return;
      BYTE header[4]{};
      DWORD count = 0;
      if (!ReadFile(pipe_, header, 4, &count, nullptr)) return;
      received = count;
      if (mode == wrong_pid || count != 4) return;
      const DWORD request_size = static_cast<DWORD>(header[0]) |
          (static_cast<DWORD>(header[1]) << 8) | (static_cast<DWORD>(header[2]) << 16) |
          (static_cast<DWORD>(header[3]) << 24);
      if (request_size == 0 || request_size > 1024 * 1024) return;
      std::vector<BYTE> request(request_size);
      DWORD offset = 0;
      while (offset < request_size) {
        if (!ReadFile(pipe_, request.data() + offset, request_size - offset, &count, nullptr) || count == 0) return;
        offset += count;
        received += count;
      }
      std::string response = "{\"version\":1,\"ok\":true,\"result\":null}";
      if (mode == invalid_utf8) response = std::string("\xff\xfe", 2);
      DWORD length = static_cast<DWORD>(response.size());
      if (mode == oversized) length = 1024 * 1024 + 1;
      if (mode == zero) length = 0;
      if (mode == stalled) length = 20;
      header[0] = static_cast<BYTE>(length);
      header[1] = static_cast<BYTE>(length >> 8);
      header[2] = static_cast<BYTE>(length >> 16);
      header[3] = static_cast<BYTE>(length >> 24);
      if (mode == partial) { WriteFile(pipe_, header, 2, &count, nullptr); return; }
      // Split writes exercise exact framing rather than assuming one IO packet.
      if (!WriteFile(pipe_, header, 2, &count, nullptr) || count != 2) return;
      if (!WriteFile(pipe_, header + 2, 2, &count, nullptr) || count != 2) return;
      if (mode == stalled) { Sleep(500); return; }
      if (mode == oversized || mode == zero) return;
      WriteFile(pipe_, response.data(), static_cast<DWORD>(response.size()), &count, nullptr);
    });
  }
  void Join() {
    // Client has already closed its connection. A server-side short read should
    // return broken pipe, and joining retains the fixture's original handle.
    if (thread_.joinable()) thread_.join();
    if (pipe_ != INVALID_HANDLE_VALUE) {
      DisconnectNamedPipe(pipe_);
      CloseHandle(pipe_);
      pipe_ = INVALID_HANDLE_VALUE;
    }
  }
  ~PipeFixture() { Join(); }
 private:
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  std::thread thread_;
};

int wmain(int argc, wchar_t* argv[]) {
  if (argc != 1) {
    try {
      Require(argc == 3, "installed probe requires mode and expected service image");
      const std::wstring mode(argv[1]);
      Require(mode == L"--diagnose-installed-service" || mode == L"--installed-readactive-medium",
          "only the two read-only installed-service modes are accepted");
      return InstalledServiceProbe(argv[2], mode == L"--installed-readactive-medium");
    } catch (const std::exception& error) {
      std::cerr << "FAIL " << error.what() << '\n';
      return 1;
    }
  }
  HANDLE cancel = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (cancel == nullptr) return 2;
  try {
    const std::wstring image = L"C:\\Program Files\\HoneyProxyUtility\\HoneyVpnService.exe";
    Require(IsWindowsServiceCommandForTest(image, L"\"" + image + L"\" --service"), "installed fixed quoted service command");
    Require(!IsWindowsServiceCommandForTest(image, image + L" --service"), "unquoted spaced command fails closed");
    Require(!IsWindowsServiceCommandForTest(image, L"\"" + image + L"\" --install"), "installation mode cannot authenticate as service");
    Require(!IsWindowsServiceCommandForTest(image, L"\"" + image + L"\" --service --other"), "extra service command arguments fail closed");
    std::cout << "PASS exact registered service command\n";
    const std::string request = "{\"version\":1,\"operation\":\"readActive\"}";
    for (const auto mode : {PipeFixture::valid, PipeFixture::wrong_pid,
                           PipeFixture::oversized, PipeFixture::zero,
                           PipeFixture::invalid_utf8, PipeFixture::partial,
                           PipeFixture::stalled}) {
      PipeFixture server(mode);
      const auto started = GetTickCount64();
      auto response = CallWindowsServiceTestPipe(server.name,
          mode == PipeFixture::wrong_pid ? GetCurrentProcessId() + 1 : GetCurrentProcessId(),
          request, cancel, 250);
      const auto elapsed = GetTickCount64() - started;
      // Close the owned server connection before joining its thread. A partial
      // frame simulates an actual broken pipe, not a long-lived foreign process.
      server.Join();
      if (mode == PipeFixture::valid) Require(response.error.empty() && !response.json.empty(), "valid framed response");
      else Require(response.error == "serviceUnavailable" && response.json.empty(), "malformed/foreign response fails closed");
      if (mode == PipeFixture::wrong_pid) Require(server.received == 0, "no configuration bytes before kernel server identity matches");
      if (mode == PipeFixture::stalled) Require(elapsed < 1500, "owned overlapped read cancellation is bounded");
      std::cout << "PASS owned pipe fixture mode " << static_cast<int>(mode) << '\n';
    }
    auto oversized = CallWindowsServiceTestPipe(L"\\\\.\\pipe\\unused-invalid-input",
        GetCurrentProcessId(), std::string(1024 * 1024 + 1, 'x'), cancel, 250);
    Require(oversized.error == "serviceUnavailable", "oversized request rejected before IPC");
    auto invalid = CallWindowsServiceTestPipe(L"\\\\.\\pipe\\unused-invalid-input",
        GetCurrentProcessId(), std::string("\xff", 1), cancel, 250);
    Require(invalid.error == "serviceUnavailable", "invalid UTF8 rejected before IPC");
    auto untrusted = QueryWindowsServiceForTest(request);
    Require(untrusted.json.empty() &&
        (untrusted.error == "serviceNotInstalled" || untrusted.error == "serviceUnavailable" ||
         untrusted.error == "serviceAccessDenied"), "read-only real SCM query cannot borrow another installed image");
    std::cout << "PASS bounds, UTF8 and genuine read-only SCM identity query\n";

    ResetEvent(cancel);
    PipeFixture server(PipeFixture::stalled);
    std::thread stopper([cancel] { Sleep(50); SetEvent(cancel); });
    auto response = CallWindowsServiceTestPipe(server.name, GetCurrentProcessId(), request, cancel, 8000);
    stopper.join();
    server.Join();
    Require(response.error == "serviceUnavailable", "shutdown event cancels owned pipe read");
    std::cout << "PASS shutdown cancellation keeps OVERLAPPED buffers alive through completion\n";
    CloseHandle(cancel);
    return 0;
  } catch (const std::exception& error) {
    CloseHandle(cancel);
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
