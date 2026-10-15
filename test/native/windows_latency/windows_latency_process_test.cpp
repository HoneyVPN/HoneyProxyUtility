#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "windows_latency_process.h"

namespace fs = std::filesystem;

namespace {
void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

std::wstring Executable() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  Check(length > 0 && length < path.size(), "module path unavailable");
  return std::wstring(path.data(), length);
}

std::string Utf8(const fs::path& path) {
  const auto value = path.wstring();
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  Check(size > 0, "path UTF-8 conversion failed");
  std::string result(size, '\0');
  Check(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(),
      static_cast<int>(value.size()), result.data(), size, nullptr, nullptr) == size,
      "path UTF-8 conversion incomplete");
  return result;
}

struct Fixture {
  fs::path directory;
  fs::path config;
  explicit Fixture(const std::string& mode) {
    std::vector<wchar_t> temporary(32768);
    const DWORD length = GetTempPathW(static_cast<DWORD>(temporary.size()), temporary.data());
    Check(length > 0 && length < temporary.size(), "temporary path unavailable");
    static unsigned serial = 0;
    directory = fs::path(std::wstring(temporary.data(), length)) /
        (L"honey-latency-native-" + std::to_wstring(GetCurrentProcessId()) +
         L"-" + std::to_wstring(++serial));
    Check(fs::create_directory(directory), "fixture directory create failed");
    config = directory / L"config.json";
    std::ofstream file(config);
    file << mode;
    Check(file.good(), "fixture config write failed");
  }
  ~Fixture() { std::error_code error; fs::remove_all(directory, error); }
};

HANDLE ObserveChild(const fs::path& config) {
  const fs::path marker(config.wstring() + L".pid");
  DWORD pid = 0;
  const ULONGLONG deadline = GetTickCount64() + 3000;
  while (GetTickCount64() < deadline) {
    std::ifstream file(marker);
    if (file >> pid && pid != 0) break;
    Sleep(10);
  }
  Check(pid != 0, "dummy child did not start");
  // This read-only observation handle is retained solely by the fixture. The
  // manager under test never reads this PID and never opens processes by PID.
  HANDLE handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  Check(handle != nullptr, "dummy child observation handle unavailable");
  return handle;
}

PROCESS_INFORMATION Launch(const std::wstring& command, const fs::path& directory) {
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  std::wstring writable = L"\"" + Executable() + L"\" " + command;
  Check(CreateProcessW(Executable().c_str(), writable.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, directory.c_str(), &startup, &process) != 0,
      "fixture process creation failed");
  CloseHandle(process.hThread);
  process.hThread = nullptr;
  return process;
}

int Dummy(const fs::path& config) {
  std::string mode;
  std::ifstream input(config);
  input >> mode;
  if (mode == "quick") return 7;
  { std::ofstream pid(fs::path(config.wstring() + L".pid")); pid << GetCurrentProcessId(); }
  for (;;) Sleep(1000);
}

int Parent(const fs::path& config, const fs::path& directory) {
  WindowsLatencyProcessManager manager(Executable());
  Check(manager.Start(Utf8(config), Utf8(directory)) != 0, "parent could not start owned child");
  const ULONGLONG deadline = GetTickCount64() + 10000;
  while (!fs::exists(directory / L"leave") && GetTickCount64() < deadline) Sleep(10);
  // Skip destructors, exercising kernel job-handle cleanup on abrupt parent exit.
  ExitProcess(0);
}

void Run() {
  {
    WindowsLatencyProcessManager manager(Executable());
    Fixture fixture("hang");
    const uint64_t id = manager.Start(Utf8(fixture.config), Utf8(fixture.directory));
    Check(id != 0, "owned child did not start");
    HANDLE observer = ObserveChild(fixture.config);
    Check(manager.Status(id).known && !manager.Status(id).exited, "live child status wrong");
    Check(manager.Stop(id), "stop did not confirm owned child exit");
    Check(WaitForSingleObject(observer, 0) == WAIT_OBJECT_0, "stop returned before exit");
    CloseHandle(observer);
    Check(!manager.Status(id).known && !manager.Stop(id), "retired nonce was reused");
    Check(!manager.Status(id + 10000).known && !manager.Stop(id + 10000), "foreign ID accepted");
    fs::remove(fixture.config);
    Check(!fs::exists(fixture.config), "config lock remained after confirmed stop");
  }
  std::cout << "PASS retained child handle / stop ACK / config unlock / stale ID\n";

  {
    WindowsLatencyProcessManager manager(Executable());
    Fixture foreign("hang");
    auto foreign_process = Launch(L"run -c \"" + foreign.config.wstring() + L"\"", foreign.directory);
    HANDLE observer = ObserveChild(foreign.config);
    for (int i = 0; i < 50; ++i) {
      Fixture quick("quick");
      const uint64_t id = manager.Start(Utf8(quick.config), Utf8(quick.directory));
      Check(id != 0, "quick child launch failed");
      const ULONGLONG deadline = GetTickCount64() + 3000;
      while (!manager.Status(id).exited && GetTickCount64() < deadline) Sleep(5);
      const auto status = manager.Status(id);
      Check(status.exited && status.exit_code == 7, "natural exit status lost");
      Check(manager.Stop(id), "natural exit cleanup failed");
      Check(WaitForSingleObject(observer, 0) == WAIT_TIMEOUT, "foreign process was terminated");
    }
    TerminateProcess(foreign_process.hProcess, 0);
    Check(WaitForSingleObject(foreign_process.hProcess, 3000) == WAIT_OBJECT_0, "fixture cleanup failed");
    CloseHandle(observer);
    CloseHandle(foreign_process.hProcess);
  }
  std::cout << "PASS 50 natural exits without signalling foreign process\n";

  {
    WindowsLatencyProcessManager manager(Executable());
    std::vector<std::unique_ptr<Fixture>> fixtures;
    std::vector<uint64_t> ids;
    for (int i = 0; i < 5; ++i) {
      fixtures.push_back(std::make_unique<Fixture>("hang"));
      const auto& fixture = *fixtures.back();
      ids.push_back(manager.Start(Utf8(fixture.config), Utf8(fixture.directory)));
      Check(i < 4 ? ids.back() != 0 : ids.back() == 0, "four-child cap failed");
    }
    for (int i = 0; i < 4; ++i) Check(manager.Stop(ids[i]), "bounded child cleanup failed");
    const uint64_t final_id = manager.Start(Utf8(fixtures.back()->config), Utf8(fixtures.back()->directory));
    Check(final_id != 0,
        "confirmed cleanup did not release capacity");
    Check(manager.Stop(final_id), "final cap fixture did not retire");
    Check(manager.Start("relative/config.json", "relative") == 0, "relative path accepted");
    Check(manager.Start(Utf8(fixtures[0]->config), Utf8(fixtures[1]->directory)) == 0,
        "mismatched config directory accepted");
  }
  std::cout << "PASS four-child cap / release / path containment\n";

  {
    Fixture fixture("hang");
    HANDLE observer = nullptr;
    {
      WindowsLatencyProcessManager manager(Executable());
      Check(manager.Start(Utf8(fixture.config), Utf8(fixture.directory)) != 0, "destructor child failed");
      observer = ObserveChild(fixture.config);
    }
    Check(WaitForSingleObject(observer, 2000) == WAIT_OBJECT_0, "destructor did not retire job child");
    CloseHandle(observer);
  }
  std::cout << "PASS window/manager destruction retires owned job\n";

  {
    Fixture fixture("hang");
    auto parent = Launch(L"--parent \"" + fixture.config.wstring() + L"\" \"" +
        fixture.directory.wstring() + L"\"", fixture.directory);
    HANDLE observer = ObserveChild(fixture.config);
    { std::ofstream marker(fixture.directory / L"leave"); marker << "exit"; }
    Check(WaitForSingleObject(parent.hProcess, 3000) == WAIT_OBJECT_0, "dummy parent did not exit");
    Check(WaitForSingleObject(observer, 3000) == WAIT_OBJECT_0, "parent exit left orphan core");
    CloseHandle(observer);
    CloseHandle(parent.hProcess);
  }
  std::cout << "PASS abrupt parent exit closes KILL_ON_JOB_CLOSE job\n";
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  try {
    if (argc == 4 && std::wstring(argv[1]) == L"run" && std::wstring(argv[2]) == L"-c")
      return Dummy(argv[3]);
    if (argc == 4 && std::wstring(argv[1]) == L"--parent") return Parent(argv[2], argv[3]);
    Run();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
