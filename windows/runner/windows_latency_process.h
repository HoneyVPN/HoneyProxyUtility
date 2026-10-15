#ifndef RUNNER_WINDOWS_LATENCY_PROCESS_H_
#define RUNNER_WINDOWS_LATENCY_PROCESS_H_

#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>

struct WindowsLatencyStatus {
  bool known = false;
  bool exited = false;
  DWORD exit_code = STILL_ACTIVE;
};

// Each child stays attached to its original process handle and a private
// KILL_ON_JOB_CLOSE job. Neither status nor stop ever reopens a process by PID.
class WindowsLatencyProcessManager {
 public:
  WindowsLatencyProcessManager();
  ~WindowsLatencyProcessManager();
  WindowsLatencyProcessManager(const WindowsLatencyProcessManager&) = delete;
  WindowsLatencyProcessManager& operator=(const WindowsLatencyProcessManager&) = delete;

  uint64_t Start(const std::string& config, const std::string& directory);
  WindowsLatencyStatus Status(uint64_t id);
  bool Stop(uint64_t id);

  // Native fixture supplies its adjacent synthetic dummy binary. Production
  // always uses the default constructor and the adjacent pinned sing-box.exe.
  explicit WindowsLatencyProcessManager(const std::wstring& fixture_binary);

 private:
  struct Child;
  std::wstring binary_;
  std::mutex mutex_;
  uint64_t next_id_ = 0;
  std::map<uint64_t, std::unique_ptr<Child>> children_;
};

#endif
