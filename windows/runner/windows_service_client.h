#ifndef RUNNER_WINDOWS_SERVICE_CLIENT_H_
#define RUNNER_WINDOWS_SERVICE_CLIENT_H_

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

constexpr UINT kWindowsServiceReplyMessage = WM_APP + 0x52;

struct WindowsServiceReply {
  std::string json;
  // One of the safe Dart WindowsSessionFailure enum names. Never native paths,
  // exception text, configs or caller credentials.
  std::string error;
};

// Requests run on one worker. Replies are delivered only by DrainRepliesUI()
// on the window thread; shutdown cancels pending pipe IO before joining.
class WindowsServiceClient {
 public:
  using Reply = std::function<void(WindowsServiceReply)>;
  explicit WindowsServiceClient(std::function<void()> notify);
  ~WindowsServiceClient();
  void Request(std::string request, Reply reply);
  void DrainRepliesUI();
  void Shutdown();

 private:
  struct Pending { std::string request; Reply reply; };
  struct Completed { WindowsServiceReply response; Reply reply; };
  void Run();
  std::function<void()> notify_;
  HANDLE cancel_ = nullptr;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Pending> pending_;
  std::deque<Completed> completed_;
  bool stopping_ = false;
  std::thread worker_;
};

#ifdef HONEY_SERVICE_CLIENT_TESTING
// Compiled only into the regression executable. The actual Flutter channel
// cannot select another pipe or supply a process identity.
WindowsServiceReply CallWindowsServiceTestPipe(
    const std::wstring& pipe, DWORD expected_pid, const std::string& request,
    HANDLE cancel, DWORD timeout_ms);
WindowsServiceReply QueryWindowsServiceForTest(const std::string& request);
bool IsWindowsServiceCommandForTest(const std::wstring& expected_image,
                                   const std::wstring& registered);
// Read-only installed-service regression. The override exists only in this
// executable, whose image is outside the installed application directory.
// Diagnostics contain static gate names/Win32 codes, never reply contents.
struct WindowsServiceProbeForTest {
  WindowsServiceReply reply;
  std::string stage;
  DWORD win32_error = ERROR_SUCCESS;
  DWORD service_pid = 0;
  DWORD service_state = 0;
  bool query_limited_attempted = false;
  bool query_limited_opened = false;
  DWORD query_limited_error = ERROR_SUCCESS;
  bool query_limited_image_matches = false;
  DWORD query_limited_image_error = ERROR_SUCCESS;
};
WindowsServiceProbeForTest ProbeInstalledWindowsServiceReadActiveForTest(
    const std::wstring& expected_image);
#endif

#endif
