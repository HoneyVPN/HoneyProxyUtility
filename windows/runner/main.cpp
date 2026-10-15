#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "window_placement.h"
#include "windows_deeplink.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  WindowsDeepLinkBroker link_broker;
  const auto launch = link_broker.StartOrForward(GetCommandLineArguments());
  if (launch != WindowsLinkLaunch::kPrimary) {
    return launch == WindowsLinkLaunch::kForwarded ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Imports are delivered only through the validated event channel, never as
  // engine arguments or commands that could be logged by the Flutter runtime.
  FlutterWindow window(project, &link_broker);
  RECT bounds{};
  HMONITOR monitor = honey::StartupWindowMonitor();
  bool placed = honey::QueryStartupPanelBounds(monitor, &bounds);
  if (!placed) {
    monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
    placed = honey::QueryStartupPanelBounds(monitor, &bounds);
  }
  if (!placed ||
      !window.CreateWithBounds(L"HoneyProxyUtility", bounds)) {
    return EXIT_FAILURE;
  }
  // The tray intercepts ordinary close only while its icon is available.
  // Explicit Quit, OS shutdown, and an unavailable tray still end this process.
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
