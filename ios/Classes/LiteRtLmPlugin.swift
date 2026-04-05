import Flutter
import UIKit

public class LiteRtLmPlugin: NSObject, FlutterPlugin {
  private let bridge = GemmaLiteRTBridge()
  private var streamEventSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LiteRtLmPlugin()

    let channel = FlutterMethodChannel(
      name: "litert_lm/method",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)

    let eventChannel = FlutterEventChannel(
      name: "litert_lm/stream",
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareModel":
      guard
        let args = call.arguments as? [String: Any],
        let path = args["modelPath"] as? String,
        !path.isEmpty
      else {
        result(FlutterError(code: "bad_args", message: "modelPath is required.", details: nil))
        return
      }
      let systemPrompt = args["systemPrompt"] as? String
      do {
        try bridge.prepareModel(atPath: path, systemPrompt: systemPrompt, toolsJSON: nil)
        result(nil)
      } catch {
        result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
      }

    case "generateTextStream":
      guard
        let args = call.arguments as? [String: Any],
        let prompt = args["prompt"] as? String,
        !prompt.isEmpty
      else {
        result(FlutterError(code: "bad_args", message: "prompt is required.", details: nil))
        return
      }
      let imagePath = args["imagePath"] as? String
      guard let sink = streamEventSink else {
        result(FlutterError(code: "no_listener", message: "Stream listener not attached.", details: nil))
        return
      }
      do {
        try bridge.generateTextStream(prompt, imagePath: imagePath) { chunk, isFinal, errorMessage in
          if let errorMessage = errorMessage {
            sink(FlutterError(code: "stream_error", message: errorMessage, details: nil))
            return
          }
          if isFinal {
            sink(FlutterEndOfEventStream)
          } else if let chunk = chunk {
            sink(chunk)
          }
        }
        result(nil)
      } catch {
        result(FlutterError(code: "stream_failed", message: error.localizedDescription, details: nil))
      }

    case "cancelGeneration":
      bridge.cancelGeneration()
      result(nil)

    case "resetConversation":
      bridge.resetConversation()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
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
