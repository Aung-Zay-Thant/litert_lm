import Flutter
import UIKit

private let backgroundQueue = DispatchQueue(label: "com.litert.lm.engine", qos: .userInitiated)

public final class LiteRtLmPlugin: NSObject, FlutterPlugin {
  private var bridges: [String: GemmaLiteRTBridge] = [:]
  private var conversationOwners: [String: String] = [:]
  private var streamEventSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LiteRtLmPlugin()

    let channel = FlutterMethodChannel(name: "litert_lm/method", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)

    let eventChannel = FlutterEventChannel(name: "litert_lm/stream", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "engineCreate":
      handleEngineCreate(call, result: result)
    case "engineDispose":
      handleEngineDispose(call, result: result)
    case "engineGetCapabilities":
      handleGetCapabilities(call, result: result)
    case "conversationCreate":
      handleConversationCreate(call, result: result)
    case "conversationDispose":
      handleConversationDispose(call, result: result)
    case "conversationGenerate":
      handleConversationGenerate(call, result: result)
    case "conversationSendToolResponse":
      handleConversationSendToolResponse(call, result: result)
    case "conversationCancel":
      handleConversationCancel(call, result: result)
    case "conversationReset":
      handleConversationReset(call, result: result)
    case "conversationGetBenchmarkInfo":
      handleConversationGetBenchmarkInfo(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Engine (runs on background queue to avoid UI freeze)

  private func handleEngineCreate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let modelPath = args["modelPath"] as? String,
      !modelPath.isEmpty
    else {
      result(FlutterError(code: "invalid_argument", message: "modelPath is required.", details: nil))
      return
    }

    let engineConfig = args["engineConfig"] as? [String: Any]

    // Run model loading on a background thread so the UI doesn't freeze.
    backgroundQueue.async { [weak self] in
      let bridge = GemmaLiteRTBridge()
      do {
        try bridge.prepareModel(atPath: modelPath, engineConfig: engineConfig)
        let engineId = UUID().uuidString
        DispatchQueue.main.async {
          self?.bridges[engineId] = bridge
          result(engineId)
        }
      } catch {
        DispatchQueue.main.async {
          result(self?.flutterError(from: error) ?? FlutterError(code: "native_failure", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handleEngineDispose(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let engineId = args["engineId"] as? String else {
      result(FlutterError(code: "invalid_argument", message: "engineId is required.", details: nil))
      return
    }
    bridges.removeValue(forKey: engineId)
    conversationOwners = conversationOwners.filter { $0.value != engineId }
    result(nil)
  }

  private func handleGetCapabilities(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard resolveBridge(call, result: result) != nil else { return }
    result([
      "supportsGpuBackend": true,
      "supportsVisionInput": true,
      "supportsAudioInput": false,
      "supportsSeededSampling": true,
      "supportsBenchmarkInfo": true,
    ])
  }

  // MARK: - Conversation (create on background, others on main)

  private func handleConversationCreate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let engineId = args["engineId"] as? String,
      let bridge = bridges[engineId]
    else {
      result(FlutterError(code: "not_found", message: "Engine not found.", details: nil))
      return
    }

    let conversationConfig = args["conversationConfig"] as? [String: Any]
    let sessionConfig = args["sessionConfig"] as? [String: Any]

    backgroundQueue.async { [weak self] in
      do {
        let conversationId = try bridge.createConversation(
          withConfig: conversationConfig,
          sessionConfig: sessionConfig
        )
        DispatchQueue.main.async {
          self?.conversationOwners[conversationId] = engineId
          result(conversationId)
        }
      } catch {
        DispatchQueue.main.async {
          result(self?.flutterError(from: error) ?? FlutterError(code: "native_failure", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handleConversationDispose(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let bridge = resolveBridge(call, result: result)
    else { return }
    bridge.disposeConversation(withId: conversationId)
    conversationOwners.removeValue(forKey: conversationId)
    result(nil)
  }

  // MARK: - Generation

  private func handleConversationGenerate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let requestId = args["requestId"] as? String,
      let prompt = args["prompt"] as? [[String: Any]],
      let bridge = resolveBridge(call, result: result)
    else { return }
    guard let sink = streamEventSink else {
      result(FlutterError(code: "native_failure", message: "Stream listener not attached.", details: nil))
      return
    }

    do {
      try bridge.generateTextStream(forConversationId: conversationId, promptParts: prompt, requestId: requestId) { event in
        sink(event)
      }
      result(nil)
    } catch {
      result(flutterError(from: error))
    }
  }

  private func handleConversationSendToolResponse(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let requestId = args["requestId"] as? String,
      let toolName = args["toolName"] as? String,
      let toolResult = args["toolResult"] as? String,
      let bridge = resolveBridge(call, result: result)
    else { return }
    guard let sink = streamEventSink else {
      result(FlutterError(code: "native_failure", message: "Stream listener not attached.", details: nil))
      return
    }
    do {
      try bridge.sendToolResponse(forConversationId: conversationId, toolName: toolName, toolResult: toolResult, requestId: requestId) { event in
        sink(event)
      }
      result(nil)
    } catch {
      result(flutterError(from: error))
    }
  }

  private func handleConversationCancel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let bridge = resolveBridge(call, result: result)
    else { return }
    bridge.cancelGeneration(forConversationId: conversationId)
    result(nil)
  }

  private func handleConversationReset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let bridge = resolveBridge(call, result: result)
    else { return }
    do {
      try bridge.resetConversation(withId: conversationId)
      result(nil)
    } catch {
      result(flutterError(from: error))
    }
  }

  private func handleConversationGetBenchmarkInfo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let conversationId = args["conversationId"] as? String,
      let bridge = resolveBridge(call, result: result)
    else { return }
    result(bridge.getBenchmarkInfo(forConversationId: conversationId))
  }

  // MARK: - Helpers

  private func resolveBridge(_ call: FlutterMethodCall, result: FlutterResult) -> GemmaLiteRTBridge? {
    guard
      let args = call.arguments as? [String: Any],
      let engineId = args["engineId"] as? String,
      let bridge = bridges[engineId]
    else {
      result(FlutterError(code: "not_found", message: "Engine not found.", details: nil))
      return nil
    }
    return bridge
  }

  private func flutterError(from error: Error) -> FlutterError {
    let nsError = error as NSError
    let code = (nsError.userInfo["code"] as? String) ?? "native_failure"
    return FlutterError(code: code, message: nsError.localizedDescription, details: nil)
  }
}

extension LiteRtLmPlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    streamEventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    streamEventSink = nil
    return nil
  }
}
