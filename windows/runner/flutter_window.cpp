#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>

#include "windows_session_path.h"

namespace {
const flutter::EncodableValue* TrayField(const flutter::EncodableMap& map,
                                       const char* key) {
  const auto field = map.find(flutter::EncodableValue(key));
  return field == map.end() ? nullptr : &field->second;
}

bool TrayBoolean(const flutter::EncodableMap& map, const char* key, bool* output) {
  const auto* field = TrayField(map, key);
  const auto* value = field ? std::get_if<bool>(field) : nullptr;
  if (!value) return false;
  *output = *value;
  return true;
}

bool TrayString(const flutter::EncodableMap& map, const char* key,
                std::string* output, size_t maximum) {
  const auto* field = TrayField(map, key);
  const auto* value = field ? std::get_if<std::string>(field) : nullptr;
  if (!value || value->size() > maximum) return false;
  *output = *value;
  return true;
}

bool OptionalTrayString(const flutter::EncodableMap& map, const char* key,
                        std::optional<std::string>* output, size_t maximum) {
  const auto* field = TrayField(map, key);
  if (!field) return false;
  if (std::holds_alternative<std::monostate>(*field)) {
    output->reset();
    return true;
  }
  const auto* value = std::get_if<std::string>(field);
  if (!value || value->size() > maximum) return false;
  *output = *value;
  return true;
}

std::optional<WindowsTrayState> ParseTrayState(const flutter::EncodableValue* raw) {
  const auto* map = raw ? std::get_if<flutter::EncodableMap>(raw) : nullptr;
  if (!map || map->size() != 8) return std::nullopt;
  WindowsTrayState state;
  if (!TrayString(*map, "locale", &state.locale, 2) ||
      !TrayBoolean(*map, "connected", &state.connected) ||
      !TrayBoolean(*map, "busy", &state.busy) ||
      !TrayBoolean(*map, "tunnel", &state.tunnel) ||
      !TrayBoolean(*map, "canConnect", &state.can_connect) ||
      !OptionalTrayString(*map, "selectedId", &state.selected_id, 128) ||
      !OptionalTrayString(*map, "selectedName", &state.selected_name, 512)) {
    return std::nullopt;
  }
  const auto* servers_raw = TrayField(*map, "servers");
  const auto* servers = servers_raw ? std::get_if<flutter::EncodableList>(servers_raw) : nullptr;
  if (!servers || servers->size() > kMaximumWindowsTrayServers) return std::nullopt;
  state.servers.reserve(servers->size());
  for (const auto& raw_server : *servers) {
    const auto* server_map = std::get_if<flutter::EncodableMap>(&raw_server);
    WindowsTrayServer server;
    if (!server_map || server_map->size() != 5 ||
        !TrayString(*server_map, "id", &server.id, 128) ||
        !TrayString(*server_map, "name", &server.name, 512) ||
        !TrayString(*server_map, "group", &server.group, 256) ||
        !TrayString(*server_map, "groupId", &server.group_id, 128) ||
        !TrayString(*server_map, "countryCode", &server.country_code, 2)) return std::nullopt;
    state.servers.push_back(std::move(server));
  }
  if (!ValidateWindowsTrayState(state)) return std::nullopt;
  return state;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             WindowsDeepLinkBroker* link_broker)
    : link_broker_(link_broker), project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  commands_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ru.honeyvpn.proxy/commands",
      &flutter::StandardMethodCodec::GetInstance());
  commands_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setTrayState") {
          auto state = ParseTrayState(call.arguments());
          if (!state || !tray_ || quit_requested_) {
            result->Error("invalid_tray_state", "Invalid tray presentation state");
            return;
          }
          tray_->SetState(std::move(*state));
          result->Success();
          return;
        }
        if (call.method_name() == "showWindow") {
          if (tray_) tray_->ShowWindow();
          result->Success();
          return;
        }
        if (call.method_name() == "quit") {
          // Dart authorizes exit after confirmed cleanup of a managed VPN,
          // or closing a new UI which failed discovery before managing any VPN.
          // Defer destruction until this method reply is delivered.
          if (!quit_requested_) {
            quit_requested_ = true;
            if (!PostMessageW(GetHandle(), kWindowsTrayQuitMessage, 0, 0)) {
              quit_requested_ = false;
              result->Error("quit_unavailable", "The window could not close");
              return;
            }
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  tray_ = std::make_shared<WindowsTray>(GetHandle(),
      [this](const WindowsTrayAction& action) { DispatchTrayAction(action); });
  deeplink_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ru.honeyvpn.proxy/deeplink",
      &flutter::StandardMethodCodec::GetInstance());
  deeplink_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            deeplink_sink_ = std::move(events);
            DrainDeepLinksUI();
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            deeplink_sink_ = nullptr;
            return nullptr;
          }));
  session_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "ru.honeyvpn.proxy/windows_session",
      &flutter::StandardMethodCodec::GetInstance());
  session_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "isElevated") {
          result->Success(flutter::EncodableValue(IsWindowsSessionProcessElevated()));
          return;
        }
        if (call.method_name() == "ownsInteractiveProxySettings") {
          result->Success(flutter::EncodableValue(OwnsInteractiveWindowsProxySettings()));
          return;
        }
        if (call.method_name() != "isPlainPath") {
          result->NotImplemented();
          return;
        }
        const auto* path = call.arguments()
            ? std::get_if<std::string>(call.arguments()) : nullptr;
        result->Success(flutter::EncodableValue(
            path != nullptr && IsPlainWindowsSessionPath(*path)));
      });
  latency_processes_ = std::make_unique<WindowsLatencyProcessManager>();
  latency_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ru.honeyvpn.proxy/latency",
      &flutter::StandardMethodCodec::GetInstance());
  latency_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* arguments = call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
        if (arguments == nullptr || latency_processes_ == nullptr) {
          result->Error("invalid_probe", "Invalid latency probe request");
          return;
        }
        if (call.method_name() == "start") {
          const auto config = arguments->find(flutter::EncodableValue("configPath"));
          const auto directory = arguments->find(flutter::EncodableValue("directory"));
          const auto* config_value = config != arguments->end()
              ? std::get_if<std::string>(&config->second) : nullptr;
          const auto* directory_value = directory != arguments->end()
              ? std::get_if<std::string>(&directory->second) : nullptr;
          const uint64_t id = config_value && directory_value
              ? latency_processes_->Start(*config_value, *directory_value) : 0;
          if (id == 0) {
            result->Error("probe_start_failed", "Latency probe could not start");
          } else {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(id)));
          }
          return;
        }
        const auto identifier = arguments->find(flutter::EncodableValue("id"));
        const auto* wide_id = identifier != arguments->end()
            ? std::get_if<int64_t>(&identifier->second) : nullptr;
        const auto* small_id = identifier != arguments->end()
            ? std::get_if<int32_t>(&identifier->second) : nullptr;
        const int64_t id = wide_id ? *wide_id : (small_id ? *small_id : 0);
        if (id <= 0) {
          result->Error("invalid_probe", "Invalid latency probe identifier");
          return;
        }
        if (call.method_name() == "status") {
          const auto status = latency_processes_->Status(static_cast<uint64_t>(id));
          if (!status.known) {
            result->Error("unknown_probe", "Latency probe status is unavailable");
          } else {
            result->Success(flutter::EncodableMap{
              {flutter::EncodableValue("exited"), flutter::EncodableValue(status.exited)},
              {flutter::EncodableValue("exitCode"),
                  flutter::EncodableValue(static_cast<int64_t>(status.exit_code))},
            });
          }
          return;
        }
        if (call.method_name() == "stop") {
          result->Success(flutter::EncodableValue(latency_processes_->Stop(static_cast<uint64_t>(id))));
          return;
        }
        result->NotImplemented();
      });
  service_client_ = std::make_unique<WindowsServiceClient>([this]() {
    PostMessage(GetHandle(), kWindowsServiceReplyMessage, 0, 0);
  });
  service_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ru.honeyvpn.proxy/windows_service",
      &flutter::StandardMethodCodec::GetInstance());
  service_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "request") {
          result->NotImplemented();
          return;
        }
        const auto* json = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
        if (json == nullptr || json->empty() || json->size() > 1024 * 1024 ||
            service_client_ == nullptr) {
          result->Error("invalid_service_request", "Invalid VPN service request");
          return;
        }
        auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
        service_client_->Request(*json, [reply](WindowsServiceReply response) {
          if (!response.error.empty()) {
            reply->Error(response.error, "VPN service request could not be completed");
          } else {
            reply->Success(flutter::EncodableValue(response.json));
          }
        });
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (link_broker_ != nullptr) {
    link_broker_->AttachWindow(GetHandle());
    link_broker_attached_ = true;
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    first_frame_shown_ = true;
    DrainDeepLinksUI();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_) tray_->Remove();
  tray_ = nullptr;
  if (commands_channel_) commands_channel_->SetMethodCallHandler(nullptr);
  commands_channel_ = nullptr;
  // CreateWithBounds calls Destroy before its first OnCreate. Only an attached
  // broker belongs to a live GUI; never stop the initial pending-import queue.
  if (link_broker_attached_ && link_broker_ != nullptr) link_broker_->Shutdown();
  link_broker_attached_ = false;
  first_frame_shown_ = false;
  if (deeplink_channel_) deeplink_channel_->SetStreamHandler(nullptr);
  deeplink_sink_ = nullptr;
  deeplink_channel_ = nullptr;
  if (service_client_) service_client_->Shutdown();
  service_channel_ = nullptr;
  service_client_ = nullptr;
  latency_channel_ = nullptr;
  latency_processes_ = nullptr;
  session_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::DispatchTrayAction(const WindowsTrayAction& action) {
  if (!commands_channel_ || quit_requested_) return;
  flutter::EncodableMap arguments;
  const char* name = nullptr;
  switch (action.kind) {
    case WindowsTrayActionKind::kToggleConnection: name = "toggleConnection"; break;
    case WindowsTrayActionKind::kSelectServer:
      name = "selectServer";
      arguments[flutter::EncodableValue("serverId")] = flutter::EncodableValue(action.server_id);
      break;
    case WindowsTrayActionKind::kSetTunnel:
      name = "setTunnel";
      arguments[flutter::EncodableValue("tunnel")] = flutter::EncodableValue(action.tunnel);
      break;
    case WindowsTrayActionKind::kImportClipboard: name = "importClipboard"; break;
    case WindowsTrayActionKind::kShowSettings: name = "showSettings"; break;
    case WindowsTrayActionKind::kQuit: name = "quit"; break;
    case WindowsTrayActionKind::kShowWindow:
      if (tray_) tray_->ShowWindow();
      return;
  }
  arguments[flutter::EncodableValue("action")] = flutter::EncodableValue(name);
  commands_channel_->InvokeMethod("trayAction",
      std::make_unique<flutter::EncodableValue>(std::move(arguments)));
}

void FlutterWindow::DrainDeepLinksUI() {
  if (!first_frame_shown_ || link_broker_ == nullptr) return;
  if (link_broker_->TakeActivation()) {
    HWND window = GetHandle();
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    if (!SetForegroundWindow(window)) {
      FLASHWINFO flash{sizeof(flash), window, FLASHW_TRAY, 3, 0};
      FlashWindowEx(&flash);
    }
  }
  // Cold-start links stay in native memory until Dart is listening and the
  // first frame has appeared. Cancelling the stream never discards imports.
  if (deeplink_sink_ == nullptr) return;
  for (const auto& link : link_broker_->TakeLinks()) {
    deeplink_sink_->Success(flutter::EncodableValue(link));
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kWindowsTrayQuitMessage) {
    DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_CLOSE && !quit_requested_ && tray_ && tray_->HideWindow()) {
    return 0;
  }
  if (message == WM_ENDSESSION && wparam != 0) {
    DestroyWindow(hwnd);
    return 0;
  }
  const auto tray = tray_;
  if (tray && tray->HandleMessage(message, wparam, lparam)) return 0;
  if (message == kWindowsServiceReplyMessage) {
    if (service_client_) service_client_->DrainRepliesUI();
    return 0;
  }
  if (message == kWindowsDeepLinkMessage) {
    DrainDeepLinksUI();
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
