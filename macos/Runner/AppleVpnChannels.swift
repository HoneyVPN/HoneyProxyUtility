import FlutterMacOS
import Foundation

final class AppleVpnChannels: NSObject, FlutterStreamHandler {
  private let controller = AppleVpnController()
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var listeningGeneration = 0

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "ru.honeyvpn.proxy/apple_vpn", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "ru.honeyvpn.proxy/apple_vpn_status", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    events.setStreamHandler(self)
    controller.onEvent = { [weak self] event in
      DispatchQueue.main.async { self?.eventSink?(event) }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize": result(controller.coreReady)
    case "requestPermission":
      controller.requestPermission { value, error in self.complete(result, value: value, error: error) }
    case "checkStatus":
      controller.checkStatus { value, error in self.complete(result, value: value, error: error) }
    case "getStatus":
      controller.getStatus { value, error in self.complete(result, value: value, error: error) }
    case "start":
      guard let arguments = call.arguments as? [String: Any], let config = arguments["config"] as? String,
        let profileId = AppleVpnStatusSnapshot.integer(arguments["profileId"]), profileId > 0,
        let sessionText = arguments["sessionId"] as? String, let sessionId = UUID(uuidString: sessionText) else {
        result(FlutterError(code: "INVALID_CONFIG", message: "Missing configuration", details: nil)); return
      }
      controller.start(config: config, profileId: profileId, sessionId: sessionId) { error in self.complete(result, value: nil, error: error) }
    case "stop": controller.stop { error in self.complete(result, value: nil, error: error) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func complete(_ result: @escaping FlutterResult, value: Any?, error: Error?) {
    DispatchQueue.main.async {
      if let error {
        result(FlutterError(code: "APPLE_VPN_ERROR", message: error.localizedDescription, details: nil))
      } else { result(value) }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    listeningGeneration += 1
    let generation = listeningGeneration
    eventSink = events
    controller.checkStatus { [weak self] _, _ in
      guard let self, self.listeningGeneration == generation, self.eventSink != nil else { return }
      self.controller.setListening(true)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    listeningGeneration += 1
    eventSink = nil
    controller.setListening(false)
    return nil
  }
}
