#include "../../../windows/runner/windows_deeplink.h"

#include <cstdint>
#include <cwchar>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef _WIN32
#include <sddl.h>
#include <shellapi.h>
#include "../../../windows/runner/utils.h"
#endif

namespace {
int passed = 0;
const std::string kLink =
    "honeyvpn://import?url=https%3A%2F%2Fsub.example.test%2Fsynthetic";
const std::string kSlashLink =
    "honeyvpn://import/?url=https%3A%2F%2Fsub.example.test%2Fsynthetic";

void Check(bool value, const char* label) {
  if (!value) throw std::runtime_error(label);
  ++passed;
}

void CheckPortableContract() {
  std::string output = "old";
  Check(ParseWindowsLinkArguments({}, &output) == WindowsLinkArguments::kActivate &&
            output.empty(), "empty arguments activate");
  Check(ParseWindowsLinkArguments({"--import-link", kLink}, &output) ==
            WindowsLinkArguments::kImport && output == kLink,
        "cold import retains complete envelope");
  for (const auto& accepted : std::vector<std::string>{
           kSlashLink,
           "honeyvpn://import/?url=https://example.invalid/shell-protocol-test"}) {
    Check(ParseWindowsLinkArguments({"--import-link", accepted}, &output) ==
              WindowsLinkArguments::kImport && output == accepted,
          "one optional slash preserves encoded and unencoded envelope bytes");
    WindowsLinkQueue slash_queue;
    Check(slash_queue.Push(accepted) && slash_queue.TakeLinks() == std::vector<std::string>{accepted},
          "pending optional-slash queue retains exact envelope bytes");
  }
  for (const auto& arguments : std::vector<std::vector<std::string>>{
           {kLink}, {"--unknown", kLink}, {"--import-link"},
           {"--import-link", kLink, "--start-vpn"},
           {"--import-link", "https://example.test"}}) {
    Check(ParseWindowsLinkArguments(arguments, &output) ==
              WindowsLinkArguments::kInvalid && output.empty(),
          "extra/native-command arguments rejected");
  }
  Check(ParseWindowsLinkArguments({}, nullptr) == WindowsLinkArguments::kInvalid,
        "null argument output rejected");
  for (const auto& bad : std::vector<std::string>{
           "honeyvpn://connect?url=test", "HONEYVPN://import?url=test", "honeyvpn://import?",
           "honeyvpn://import/?", "honeyvpn://import//?url=test",
           "honeyvpn://import/foo?url=test", "honeyvpn://import/%2F?url=test",
           "honeyvpn://import%2F?url=test",
           kLink + " ", kLink + "\n", kLink + "\"", kLink + "\\",
           kLink + std::string(1, '\0'), kLink + std::string("\xc0\x80", 2),
           kLink + std::string("\xed\xa0\x80", 3),
           kLink + std::string("\xf4\x90\x80\x80", 4)}) {
    Check(!IsWindowsImportLink(bad), "invalid import envelope rejected");
  }
  const auto slash_maximum = kSlashLink + std::string(kMaximumWindowsDeepLinkBytes - kSlashLink.size(), 'a');
  Check(IsWindowsImportLink(slash_maximum), "64 KiB optional-slash envelope accepted");
  Check(!IsWindowsImportLink(slash_maximum + "a"), "oversized optional-slash envelope rejected");
  const auto maximum = kLink + std::string(kMaximumWindowsDeepLinkBytes - kLink.size(), 'a');
  Check(IsWindowsImportLink(maximum), "64 KiB envelope accepted");
  Check(!IsWindowsImportLink(maximum + "a"), "oversized envelope rejected");
  WindowsLinkQueue queue;
  Check(queue.Push(kLink), "queue accepts import");
  Check(queue.Push(kLink), "queue deduplicates pending import");
  Check(queue.TakeActivation(), "import activates");
  Check(!queue.TakeActivation(), "activation drained once");
  Check(queue.TakeLinks() == std::vector<std::string>{kLink}, "queue retains exactly one import");
  Check(queue.TakeLinks().empty(), "drained queue empty");
  for (size_t i = 0; i < kMaximumPendingWindowsDeepLinks; ++i) {
    Check(queue.Push(kLink + std::to_string(i)), "pending queue accepts bounded entry");
  }
  Check(!queue.Push(kLink + "overflow"), "ninth pending import rejected");
  Check(queue.Push(""), "activation allowed with full import queue");
  Check(queue.TakeLinks().size() == kMaximumPendingWindowsDeepLinks, "queue remains bounded");
  Check(!queue.Push("not-an-import"), "queue rejects native command");
}

#ifdef _WIN32
constexpr DWORD kPipeAccess = 0x0012019b;

void CheckUtf16Conversion() {
  Check(Utf8FromUtf16(nullptr).empty(), "null native URI conversion rejected");
  Check(Utf8FromUtf16(L"").empty(), "empty native URI conversion remains empty");
  const wchar_t high[] = {0xd800, 0};
  const wchar_t low[] = {0xdc00, 0};
  const wchar_t malformed[] = {L'x', 0xd800, L'y', 0};
  Check(Utf8FromUtf16(high).empty(), "lone high surrogate rejected without huge allocation");
  Check(Utf8FromUtf16(low).empty(), "lone low surrogate rejected without huge allocation");
  Check(Utf8FromUtf16(malformed).empty(), "embedded invalid surrogate rejects the whole argument");
  Check(Utf8FromUtf16(L"honeyvpn://import?url=test") == "honeyvpn://import?url=test",
        "ASCII native URI conversion unchanged");
  const wchar_t non_ascii[] = {0x041f, 0x0440, 0x0438, 0x0432, 0x0435, 0x0442,
                              L' ', 0xd83d, 0xdc1d, 0};
  const auto converted = Utf8FromUtf16(non_ascii);
  Check(converted == "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82 \xf0\x9f\x90\x9d",
        "non-ASCII and valid emoji preserve exact UTF-8");
  const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      converted.data(), static_cast<int>(converted.size()), nullptr, 0);
  Check(required > 0, "converted Unicode is valid UTF-8");
  std::wstring roundtrip(static_cast<size_t>(required), L'\0');
  Check(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, converted.data(),
      static_cast<int>(converted.size()), roundtrip.data(), required) == required &&
      roundtrip == non_ascii, "real Windows UTF-8/UTF-16 roundtrip preserves Unicode");
  const std::wstring maximum_ascii(65536, L'a');
  Check(Utf8FromUtf16(maximum_ascii.c_str()) == std::string(65536, 'a'),
        "UTF-16 converter accepts exactly 64 KiB ASCII");
  const std::wstring oversized_ascii(65537, L'a');
  Check(Utf8FromUtf16(oversized_ascii.c_str()).empty(), "UTF-16 scanning is bounded");
  const std::wstring maximum_cyrillic(32768, 0x041f);
  Check(Utf8FromUtf16(maximum_cyrillic.c_str()).size() == 65536,
        "UTF-8 byte boundary accepts complete Unicode");
  const std::wstring oversized_cyrillic(32769, 0x041f);
  Check(Utf8FromUtf16(oversized_cyrillic.c_str()).empty(),
        "Unicode expansion beyond 64 KiB is rejected before allocation");
}

struct Handle {
  HANDLE value = nullptr;
  explicit Handle(HANDLE handle = nullptr) : value(handle) {}
  ~Handle() { if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  bool valid() const { return value != nullptr && value != INVALID_HANDLE_VALUE; }
};

std::wstring CurrentImage() {
  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  Check(QueryFullProcessImageNameW(GetCurrentProcess(), 0, buffer.data(), &length) != FALSE,
        "read own executable identity");
  return std::wstring(buffer.data(), length);
}

std::wstring UniqueNamespace() {
  static unsigned counter = 0;
  return L"-fixture-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
      std::to_wstring(GetTickCount64()) + L"-" + std::to_wstring(++counter);
}

std::wstring WidenAscii(const std::string& value) {
  return std::wstring(value.begin(), value.end());
}

std::string NarrowAscii(const wchar_t* value) {
  std::string result;
  for (; *value != L'\0'; ++value) {
    if (static_cast<uint32_t>(*value) > 127) throw std::runtime_error("fixture argument must be ASCII");
    result.push_back(static_cast<char>(*value));
  }
  return result;
}

std::vector<std::string> DecodeNativeArguments(const std::wstring& command) {
  int count = 0;
  wchar_t** arguments = CommandLineToArgvW(command.c_str(), &count);
  Check(arguments != nullptr && count >= 1, "actual Windows command line parses");
  std::vector<std::string> decoded;
  try {
    for (int i = 1; i < count; ++i) decoded.push_back(Utf8FromUtf16(arguments[i]));
  } catch (...) {
    LocalFree(arguments);
    throw;
  }
  LocalFree(arguments);
  return decoded;
}

void CheckNativeCommandLine() {
  const auto command = L"\"HoneyProxyUtility.exe\" --import-link \"" + WidenAscii(kLink) + L"\"";
  std::string output;
  for (const auto& link : std::vector<std::string>{kLink, kSlashLink,
           "honeyvpn://import/?url=https://example.invalid/shell-protocol-test"}) {
    const auto registered = L"\"HoneyProxyUtility.exe\" --import-link \"" + WidenAscii(link) + L"\"";
    Check(ParseWindowsLinkArguments(DecodeNativeArguments(registered), &output) ==
        WindowsLinkArguments::kImport && output == link,
        "registered quoted command preserves empty/single-slash path and URI bytes");
  }
  Check(ParseWindowsLinkArguments(DecodeNativeArguments(command + L" --start-vpn"), &output) ==
      WindowsLinkArguments::kInvalid && output.empty(),
      "actual native parser rejects command-argument injection");
  std::wstring malformed = L"\"HoneyProxyUtility.exe\" --import-link \"honeyvpn://import?url=";
  malformed.push_back(0xd800);
  malformed += L"\"";
  Check(ParseWindowsLinkArguments(DecodeNativeArguments(malformed), &output) ==
      WindowsLinkArguments::kInvalid && output.empty(),
      "invalid UTF-16 native URI is rejected before IPC");
}

struct Child {
  Handle process;
  Handle thread;
  explicit Child(const PROCESS_INFORMATION& info) : process(info.hProcess), thread(info.hThread) {}
  ~Child() {
    if (WaitForSingleObject(process.value, 0) == WAIT_TIMEOUT) {
      TerminateProcess(process.value, ERROR_CANCELLED);
      WaitForSingleObject(process.value, 5000);
    }
  }
  DWORD Exit(DWORD timeout = 8000) {
    Check(WaitForSingleObject(process.value, timeout) == WAIT_OBJECT_0, "child exits before deadline");
    DWORD result = MAXDWORD;
    Check(GetExitCodeProcess(process.value, &result) != FALSE, "read retained child exit");
    return result;
  }
};

std::unique_ptr<Child> Spawn(const std::wstring& image,
                           const std::vector<std::wstring>& arguments) {
  // Only fixture-generated ASCII args are used; no shell or URI interpreter.
  std::wstring command = L"\"" + image + L"\"";
  for (const auto& argument : arguments) {
    Check(argument.find(L'"') == std::wstring::npos, "fixture argument has no quote");
    command += L" \"" + argument + L"\"";
  }
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  Check(CreateProcessW(image.c_str(), command.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE,
        "start real secondary executable");
  return std::make_unique<Child>(process);
}

bool Io(HANDLE pipe, bool write, BYTE* bytes, DWORD length, DWORD timeout = 4500,
        DWORD* failure = nullptr) {
  if (failure != nullptr) *failure = ERROR_SUCCESS;
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!event.valid()) {
    if (failure != nullptr) *failure = GetLastError();
    return false;
  }
  OVERLAPPED operation{}; operation.hEvent = event.value;
  DWORD count = 0;
  const BOOL immediate = write ? WriteFile(pipe, bytes, length, &count, &operation)
                               : ReadFile(pipe, bytes, length, &count, &operation);
  if (!immediate) {
    const DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) {
      if (failure != nullptr) *failure = error;
      return false;
    }
    if (WaitForSingleObject(event.value, timeout) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &operation);
      GetOverlappedResult(pipe, &operation, &count, TRUE);
      if (failure != nullptr) *failure = WAIT_TIMEOUT;
      return false;
    }
    if (!GetOverlappedResult(pipe, &operation, &count, FALSE)) {
      if (failure != nullptr) *failure = GetLastError();
      return false;
    }
  }
  if (count != length && failure != nullptr) *failure = ERROR_INVALID_DATA;
  return count == length;
}

bool ConnectFixturePipe(HANDLE pipe, HANDLE ready) {
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!event.valid()) return false;
  OVERLAPPED operation{}; operation.hEvent = event.value;
  const BOOL immediate = ConnectNamedPipe(pipe, &operation);
  const DWORD error = immediate ? ERROR_SUCCESS : GetLastError();
  if (!immediate && error != ERROR_PIPE_CONNECTED && error != ERROR_IO_PENDING) return false;
  DWORD count = 0;
  // Publish readiness only after ConnectNamedPipe is armed. A secondary can
  // authenticate/reject/close immediately, before this thread runs again.
  if (!SetEvent(ready)) {
    if (!immediate && error == ERROR_IO_PENDING) {
      CancelIoEx(pipe, &operation);
      GetOverlappedResult(pipe, &operation, &count, TRUE);
    }
    return false;
  }
  if (immediate || error == ERROR_PIPE_CONNECTED) return true;
  if (WaitForSingleObject(event.value, 5000) != WAIT_OBJECT_0) {
    CancelIoEx(pipe, &operation);
    GetOverlappedResult(pipe, &operation, &count, TRUE);
    return false;
  }
  return GetOverlappedResult(pipe, &operation, &count, FALSE) != FALSE;
}

HANDLE OpenPipe(const std::wstring& name) {
  const ULONGLONG deadline = GetTickCount64() + 5000;
  while (GetTickCount64() < deadline) {
    HANDLE pipe = CreateFileW(name.c_str(), kPipeAccess, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) return pipe;
    const DWORD error = GetLastError();
    if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND) break;
    WaitNamedPipeW(name.c_str(), 50);
    Sleep(10);
  }
  return INVALID_HANDLE_VALUE;
}

int SendFrame(const std::wstring& name, DWORD declared, const std::string& body) {
  Handle pipe(OpenPipe(name));
  if (!pipe.valid()) return -2;
  BYTE header[4] = {static_cast<BYTE>(declared), static_cast<BYTE>(declared >> 8),
                    static_cast<BYTE>(declared >> 16), static_cast<BYTE>(declared >> 24)};
  if (!Io(pipe.value, true, header, 4) ||
      (!body.empty() && !Io(pipe.value, true,
          reinterpret_cast<BYTE*>(const_cast<char*>(body.data())), static_cast<DWORD>(body.size())))) return -1;
  BYTE accepted = 0;
  if (!Io(pipe.value, false, &accepted, 1)) return -1;
  BYTE receipt = 1;
  Io(pipe.value, true, &receipt, 1);
  return accepted;
}

LRESULT CALLBACK FixtureWindowProc(HWND window, UINT message, WPARAM first, LPARAM second) {
  return DefWindowProcW(window, message, first, second);
}

class NotificationWindow {
 public:
  HWND value = nullptr;
  NotificationWindow() {
    WNDCLASSW type{};
    type.lpfnWndProc = FixtureWindowProc;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"HoneyImportNotificationFixture";
    Check(RegisterClassW(&type) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS,
          "register owned notification window");
    value = CreateWindowW(type.lpszClassName, L"", 0, 0, 0, 0, 0,
                          HWND_MESSAGE, nullptr, type.hInstance, nullptr);
    Check(value != nullptr, "create message-only window without desktop changes");
  }
  ~NotificationWindow() { if (value != nullptr) DestroyWindow(value); }
  bool Notification(DWORD timeout = 3000) {
    const ULONGLONG deadline = GetTickCount64() + timeout;
    while (GetTickCount64() < deadline) {
      MSG message{};
      if (PeekMessageW(&message, value, kWindowsDeepLinkMessage, kWindowsDeepLinkMessage, PM_REMOVE)) {
        DispatchMessageW(&message);
        return true;
      }
      Sleep(10);
    }
    return false;
  }
};

void CheckColdWarmImport(const std::wstring& image, const std::string& cold_link) {
  const auto scope = UniqueNamespace();
  WindowsDeepLinkBroker broker(scope);
  Check(broker.StartOrForward({"--import-link", cold_link}) == WindowsLinkLaunch::kPrimary,
        "cold import owns primary broker");
  const std::string warm = cold_link + "-warm";
  auto child = Spawn(image, {L"--child-forward", scope, WidenAscii(warm)});
  Check(child->Exit() == 0, "real warm process forwards before GUI is attached");
  auto duplicate = Spawn(image, {L"--child-forward", scope, WidenAscii(warm)});
  Check(duplicate->Exit() == 0, "pending duplicate acknowledged without duplicate queue entry");
  NotificationWindow window;
  broker.AttachWindow(window.value);
  Check(window.Notification(), "pending cold/warm imports notify actual window on attach");
  Check(broker.TakeActivation(), "pending imports request activation");
  Check(broker.TakeLinks() == std::vector<std::string>{cold_link, warm},
        "cold and warm URLs remain ordered until GUI consumes them");
  Check(!broker.TakeActivation() && broker.TakeLinks().empty(), "GUI consumption drains once");
  auto activation = Spawn(image, {L"--child-forward", scope});
  Check(activation->Exit() == 0, "second normal launch activates existing app");
  Check(window.Notification() && broker.TakeActivation(), "warm activation posts actual window message");
  Check(broker.TakeLinks().empty(), "normal launch creates no synthetic import");
  for (size_t i = 0; i < kMaximumPendingWindowsDeepLinks; ++i)
    Check(broker.TestEnqueue(kLink + std::to_string(i)), "fill pending native queue");
  auto full = Spawn(image, {L"--child-forward", scope, WidenAscii(kLink + "overflow")});
  Check(full->Exit() == 1, "real secondary observes full queue rejection");
  Check(broker.TakeLinks().size() == kMaximumPendingWindowsDeepLinks, "overflow never expands queue");
  broker.Shutdown();
  WindowsDeepLinkBroker reopened(scope);
  Check(reopened.StartOrForward({}) == WindowsLinkLaunch::kPrimary,
        "shutdown releases mutex and pipe for a new primary");
}

void CheckFramesAndCancellation(const std::wstring& image) {
  const auto scope = UniqueNamespace();
  WindowsDeepLinkBroker broker(scope);
  Check(broker.StartOrForward({}) == WindowsLinkLaunch::kPrimary, "frame fixture owns broker");
  const auto maximum = kLink + std::string(kMaximumWindowsDeepLinkBytes - kLink.size(), 'a');
  Check(SendFrame(broker.TestPipeName(), static_cast<DWORD>(maximum.size()), maximum) == 1,
        "maximum-size frame crosses the actual pipe without truncation");
  Check(broker.TakeLinks() == std::vector<std::string>{maximum}, "actual maximum frame remains complete");
  Check(broker.TakeActivation(), "complete maximum frame activates");
  Check(SendFrame(broker.TestPipeName(), 65537, "") == 0, "oversized actual pipe frame rejected");
  Check(SendFrame(broker.TestPipeName(), 3, "bad") == 0, "invalid actual pipe envelope rejected");
  const std::string invalid = kLink + std::string("\xc0\x80", 2);
  Check(SendFrame(broker.TestPipeName(), static_cast<DWORD>(invalid.size()), invalid) == 0,
        "invalid actual pipe UTF-8 rejected");
  const auto stalled = GetTickCount64();
  Check(SendFrame(broker.TestPipeName(), 20, "partial") == -1,
        "incomplete actual pipe payload closes at its deadline without acceptance");
  Check(GetTickCount64() - stalled >= 2000 && GetTickCount64() - stalled < 5500,
        "partial frame deadline bounded");
  Check(broker.TakeLinks().empty(), "malformed/stalled frames never enter import queue");
  auto drop = Spawn(image, {L"--child-drop", broker.TestPipeName()});
  Check(drop->Exit() == 0, "client can exit after a partial frame");
  auto after_drop = Spawn(image, {L"--child-forward", scope, WidenAscii(kLink)});
  Check(after_drop->Exit() == 0, "client death cannot disable future imports");
  Check(broker.TakeLinks() == std::vector<std::string>{kLink}, "only complete live client import retained");
  Handle partial(OpenPipe(broker.TestPipeName()));
  Check(partial.valid(), "open actual pending cancellation client");
  BYTE short_header[2] = {1, 0};
  Check(Io(partial.value, true, short_header, 2), "begin partial actual frame");
  Sleep(100);
  const auto cancel = GetTickCount64();
  broker.Shutdown();
  Check(GetTickCount64() - cancel < 2000, "shutdown joins cancellation of owned pending read");
  WindowsDeepLinkBroker idle(UniqueNamespace());
  Check(idle.StartOrForward({}) == WindowsLinkLaunch::kPrimary, "idle broker starts");
  const auto idle_cancel = GetTickCount64();
  idle.Shutdown();
  Check(GetTickCount64() - idle_cancel < 2000, "shutdown cancels idle ConnectNamedPipe");
}

void CheckIdentity(const std::wstring& image) {
  Handle token;
  Check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value) != FALSE, "query fixture token");
  DWORD length = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &length);
  Check(length != 0, "size fixture SID");
  std::vector<BYTE> data(length);
  Check(GetTokenInformation(token.value, TokenUser, data.data(), length, &length) != FALSE,
        "read fixture SID");
  LPWSTR text = nullptr;
  Check(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &text) != FALSE,
        "format fixture SID");
  const std::wstring sid(text); LocalFree(text);
  DWORD session = 0;
  Check(GetTokenInformation(token.value, TokenSessionId, &session, sizeof(session), &length) != FALSE,
        "query kernel session identity");
  Check(AuthenticateWindowsLinkPeerForTest(GetCurrentProcessId(), sid, session, image),
        "matching live kernel identity accepted");
  Check(!AuthenticateWindowsLinkPeerForTest(GetCurrentProcessId(),
      sid == L"S-1-5-18" ? L"S-1-5-19" : L"S-1-5-18", session, image), "foreign SID rejected");
  Check(!AuthenticateWindowsLinkPeerForTest(GetCurrentProcessId(), sid, session ^ 1, image),
        "foreign session rejected");
  Check(!AuthenticateWindowsLinkPeerForTest(GetCurrentProcessId(), sid, session, image + L".other"),
        "foreign executable identity rejected");
  Check(!AuthenticateWindowsLinkPeerForTest(0, sid, session, image), "missing process rejected");
  auto exited = Spawn(image, {L"--child-exit"});
  Check(exited->Exit() == 0, "identity fixture child exits");
  Check(!AuthenticateWindowsLinkPeerForTest(GetProcessId(exited->process.value), sid, session, image),
        "retained exited process is never an authenticated live peer");

  std::vector<wchar_t> temp(32768);
  const DWORD temp_length = GetTempPathW(static_cast<DWORD>(temp.size()), temp.data());
  Check(temp_length != 0 && temp_length < temp.size(), "read owned temporary root");
  const std::wstring directory = std::wstring(temp.data(), temp_length) + L"honey-import" + UniqueNamespace();
  Check(CreateDirectoryW(directory.c_str(), nullptr) != FALSE, "create owned foreign-image fixture directory");
  const std::wstring foreign = directory + L"\\foreign-import.exe";
  try {
    Check(CopyFileW(image.c_str(), foreign.c_str(), TRUE) != FALSE, "copy fixture only to a foreign image path");
    const auto scope = UniqueNamespace();
    WindowsDeepLinkBroker broker(scope);
    Check(broker.StartOrForward({}) == WindowsLinkLaunch::kPrimary, "identity fixture owns actual broker");
    auto attacker = Spawn(foreign, {L"--child-rejected-peer", broker.TestPipeName()});
    Check(attacker->Exit() == 0, "actual foreign image pipe client never receives acceptance");
    Check(broker.TakeLinks().empty() && !broker.TakeActivation(), "foreign pipe peer cannot enqueue or activate");
    auto valid = Spawn(image, {L"--child-forward", scope, WidenAscii(kLink)});
    Check(valid->Exit() == 0, "foreign peer rejection preserves normal imports");
    Check(broker.TakeLinks() == std::vector<std::string>{kLink}, "only authenticated executable reaches queue");

    // A secondary must authenticate the server too, before it writes even the
    // frame header. Run the hostile server from the copied foreign image.
    const auto spoof_scope = UniqueNamespace();
    WindowsDeepLinkBroker discover(spoof_scope);
    Check(discover.StartOrForward({}) == WindowsLinkLaunch::kPrimary, "derive owned unique pipe namespace");
    const auto spoof_pipe = discover.TestPipeName();
    discover.Shutdown();
    const std::wstring pipe_prefix = L"\\\\.\\pipe\\";
    Check(spoof_pipe.rfind(pipe_prefix, 0) == 0, "fixture pipe uses local namespace");
    const std::wstring mutex_name = L"Local\\" + spoof_pipe.substr(pipe_prefix.size());
    Handle mutex(CreateMutexW(nullptr, TRUE, mutex_name.c_str()));
    Check(mutex.valid() && GetLastError() != ERROR_ALREADY_EXISTS, "own isolated primary mutex for spoof-server fixture");
    const std::wstring event_name = L"Local\\HoneyImportReady" + UniqueNamespace();
    Handle ready(CreateEventW(nullptr, TRUE, FALSE, event_name.c_str()));
    Check(ready.valid(), "create isolated server readiness event");
    auto spoof = Spawn(foreign, {L"--child-spoof-server", spoof_pipe, event_name});
    Check(WaitForSingleObject(ready.value, 5000) == WAIT_OBJECT_0, "foreign actual pipe server becomes ready");
    auto secondary = Spawn(image, {L"--child-forward", spoof_scope, WidenAscii(kLink)});
    Check(secondary->Exit() == 1, "secondary refuses foreign image server");
    Check(spoof->Exit() == 0, "no frame header or URI bytes reach foreign server");
    Check(ReleaseMutex(mutex.value) != FALSE, "release isolated spoof fixture mutex");
  } catch (...) {
    DeleteFileW(foreign.c_str()); RemoveDirectoryW(directory.c_str()); throw;
  }
  Check(DeleteFileW(foreign.c_str()) != FALSE, "delete owned foreign-image fixture");
  Check(RemoveDirectoryW(directory.c_str()) != FALSE, "delete owned empty fixture directory");
}

int ChildMain(int argc, wchar_t** argv) {
  const std::wstring mode(argv[1]);
  if (mode == L"--child-exit") return 0;
  if (mode == L"--child-forward" && (argc == 3 || argc == 4)) {
    WindowsDeepLinkBroker broker(argv[2]);
    std::vector<std::string> arguments;
    if (argc == 4) arguments = {"--import-link", NarrowAscii(argv[3])};
    return broker.StartOrForward(arguments) == WindowsLinkLaunch::kForwarded ? 0 : 1;
  }
  if (mode == L"--child-drop" && argc == 3) {
    Handle pipe(OpenPipe(argv[2]));
    if (!pipe.valid()) return 2;
    BYTE partial[2] = {10, 0};
    return Io(pipe.value, true, partial, 2) ? 0 : 2;
  }
  if (mode == L"--child-rejected-peer" && argc == 3) {
    const int result = SendFrame(argv[2], static_cast<DWORD>(kLink.size()), kLink);
    return result == 0 || result == -1 ? 0 : 2;
  }
  if (mode == L"--child-spoof-server" && argc == 4) {
    Handle ready(OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[3]));
    Handle pipe(CreateNamedPipeW(argv[2], PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
        FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE |
        PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, nullptr));
    if (!ready.valid() || !pipe.valid() || !ConnectFixturePipe(pipe.value, ready.value)) return 3;
    BYTE first_byte = 0;
    DWORD failure = ERROR_SUCCESS;
    // A correctly rejected server sees EOF rather than any sensitive header.
    if (Io(pipe.value, false, &first_byte, 1, 5000, &failure)) return 2;
    return failure == ERROR_BROKEN_PIPE || failure == ERROR_NO_DATA ? 0 : 3;
  }
  return 3;
}
#endif
}  // namespace

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
#else
int main() {
#endif
  try {
#ifdef _WIN32
    if (argc > 1) return ChildMain(argc, argv);
#endif
    CheckPortableContract();
#ifdef _WIN32
    CheckUtf16Conversion();
    CheckNativeCommandLine();
    const auto image = CurrentImage();
    CheckColdWarmImport(image, kLink);
    CheckColdWarmImport(image, kSlashLink);
    CheckFramesAndCancellation(image);
    CheckIdentity(image);
#endif
    std::cout << "PASS " << passed << " Windows import checks" << std::endl;
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << std::endl;
    return 1;
  }
}
