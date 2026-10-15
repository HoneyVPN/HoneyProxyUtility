#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>

#include <memory>

#include "win32_window.h"
#include "windows_latency_process.h"
#include "windows_service_client.h"
#include "windows_deeplink.h"
#include "windows_tray.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         WindowsDeepLinkBroker* link_broker = nullptr);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void DrainDeepLinksUI();
  void DispatchTrayAction(const WindowsTrayAction& action);

  WindowsDeepLinkBroker* link_broker_ = nullptr;  // Owned by main, outlives window.
  bool link_broker_attached_ = false;
  bool first_frame_shown_ = false;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> deeplink_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> deeplink_sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> commands_channel_;
  // A popup runs a nested Win32 message loop. Retain it across a concurrent
  // window-destruction message until that popup returns.
  std::shared_ptr<WindowsTray> tray_;
  bool quit_requested_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> session_channel_;
  std::unique_ptr<WindowsLatencyProcessManager> latency_processes_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> latency_channel_;
  std::unique_ptr<WindowsServiceClient> service_client_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> service_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
