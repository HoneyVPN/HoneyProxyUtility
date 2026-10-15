#ifndef RUNNER_WINDOWS_DEEPLINK_H_
#define RUNNER_WINDOWS_DEEPLINK_H_

#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <atomic>
#include <thread>
#endif

constexpr size_t kMaximumWindowsDeepLinkBytes = 64 * 1024;
constexpr size_t kMaximumPendingWindowsDeepLinks = 8;

enum class WindowsLinkArguments { kActivate, kImport, kInvalid };
// Native code carries the entire envelope; the shared Dart validator owns
// payload parsing. No URL is ever interpreted as a native command or filename.
bool IsWindowsImportLink(const std::string& link);
WindowsLinkArguments ParseWindowsLinkArguments(
    const std::vector<std::string>& arguments, std::string* link);

class WindowsLinkQueue {
 public:
  bool Push(std::string link);
  bool TakeActivation();
  std::vector<std::string> TakeLinks();

 private:
  std::mutex mutex_;
  bool activation_ = false;
  std::deque<std::string> links_;
};

#ifdef _WIN32
constexpr UINT kWindowsDeepLinkMessage = WM_APP + 0x53;
enum class WindowsLinkLaunch { kPrimary, kForwarded, kRejected, kUnavailable };

#ifdef HONEY_DEEPLINK_TESTING
// Read-only kernel process-identity checks for negative SID/session/image cases.
bool AuthenticateWindowsLinkPeerForTest(DWORD pid, const std::wstring& sid,
                                       DWORD session, const std::wstring& image);
#endif

// One GUI per current account and Windows session. Secondary processes exit
// before creating Flutter or touching the VPN. All pipe IO runs off the UI.
class WindowsDeepLinkBroker {
 public:
  WindowsDeepLinkBroker();
  ~WindowsDeepLinkBroker();
  WindowsLinkLaunch StartOrForward(const std::vector<std::string>& arguments);
  void AttachWindow(HWND window);
  bool TakeActivation();
  std::vector<std::string> TakeLinks();
  void Shutdown();

#ifdef HONEY_DEEPLINK_TESTING
  // Only regression binaries can choose a unique temporary IPC namespace.
  explicit WindowsDeepLinkBroker(std::wstring test_namespace);
  const std::wstring& TestPipeName() const { return pipe_name_; }
  bool TestEnqueue(std::string link) { return queue_.Push(std::move(link)); }
#endif

 private:
  void Listen();
  bool Forward(const std::string& link);
  void Notify();
  std::wstring sid_;
  std::wstring image_;
  std::wstring mutex_name_;
  std::wstring pipe_name_;
  std::wstring test_namespace_;
  DWORD session_ = 0;
  HANDLE mutex_ = nullptr;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE cancel_ = nullptr;
  bool owns_mutex_ = false;
  std::atomic<HWND> window_{nullptr};
  WindowsLinkQueue queue_;
  std::thread worker_;
};
#endif

#endif  // RUNNER_WINDOWS_DEEPLINK_H_
