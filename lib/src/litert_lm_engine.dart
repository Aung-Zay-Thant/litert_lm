import 'dart:async';

import 'package:flutter/services.dart';

/// On-device LLM inference engine powered by LiteRT-LM.
///
/// Usage:
/// ```dart
/// final engine = LiteRtLmEngine();
/// await engine.prepare(modelPath: '/path/to/model.litertlm');
///
/// await for (final chunk in engine.generateStream(prompt: 'Hello!')) {
///   print(chunk); // tokens arrive one by one
/// }
/// ```
class LiteRtLmEngine {
  LiteRtLmEngine({
    String methodChannelName = 'litert_lm/method',
    String eventChannelName = 'litert_lm/stream',
  }) : _channel = MethodChannel(methodChannelName),
       _streamChannel = EventChannel(eventChannelName);

  final MethodChannel _channel;
  final EventChannel _streamChannel;

  bool _isPrepared = false;

  /// Whether the engine has been prepared with a model.
  bool get isPrepared => _isPrepared;

  /// Prepares the engine with a model file.
  ///
  /// [modelPath] — absolute path to the `.litertlm` model file.
  /// [systemPrompt] — optional system prompt to set the AI persona.
  ///
  /// This is a no-op if the same model is already loaded.
  Future<void> prepare({
    required String modelPath,
    String? systemPrompt,
  }) async {
    final args = <String, dynamic>{'modelPath': modelPath};
    if (systemPrompt != null) args['systemPrompt'] = systemPrompt;
    await _channel.invokeMethod<void>('prepareModel', args);
    _isPrepared = true;
  }

  /// Generates a streaming response from a text prompt.
  ///
  /// Returns a [Stream] of text chunks. Listen until the stream closes.
  /// Optionally attach an [imagePath] for multimodal (vision) prompts.
  Stream<String> generateStream({required String prompt, String? imagePath}) {
    final controller = StreamController<String>();

    final subscription = _streamChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is String) controller.add(event);
      },
      onError: (Object error) {
        controller.addError(error);
        controller.close();
      },
      onDone: () => controller.close(),
    );

    controller.onCancel = () => subscription.cancel();

    scheduleMicrotask(() async {
      try {
        final args = <String, dynamic>{'prompt': prompt};
        if (imagePath != null) args['imagePath'] = imagePath;
        await _channel.invokeMethod<void>('generateTextStream', args);
      } catch (error) {
        controller.addError(error);
        controller.close();
      }
    });

    return controller.stream;
  }

  /// Cancels the current generation.
  Future<void> cancel() => _channel.invokeMethod<void>('cancelGeneration');

  /// Resets the conversation context. Next prompt starts fresh.
  Future<void> resetConversation() =>
      _channel.invokeMethod<void>('resetConversation');
}
