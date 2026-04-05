import 'dart:async';

import 'package:flutter/services.dart';

import '../error/litert_lm_error_code.dart';
import '../error/litert_lm_exception.dart';
import '../model/lm_benchmark_info.dart';
import '../model/lm_capabilities.dart';
import '../model/lm_content_part.dart';
import '../model/lm_conversation_config.dart';
import '../model/lm_engine_config.dart';
import '../model/lm_message.dart';
import '../model/lm_sampler_config.dart';
import '../model/lm_session_config.dart';
import 'event_protocol.dart';
import 'litert_lm_platform.dart';

final class MethodChannelLitertLmPlatform implements LitertLmPlatform {
  MethodChannelLitertLmPlatform({
    String methodChannelName = 'litert_lm/method',
    String eventChannelName = 'litert_lm/stream',
  }) : _methodChannel = MethodChannel(methodChannelName),
       _eventChannel = EventChannel(eventChannelName) {
    _subscription = _eventChannel.receiveBroadcastStream().listen(_onEvent);
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  late final StreamSubscription<dynamic> _subscription;
  final Map<String, StreamController<String>> _requests = {};
  int _requestCounter = 0;

  @override
  Future<String> createEngine({
    required String modelPath,
    required LmEngineConfig config,
  }) async {
    _validateModelPath(modelPath);
    final result = await _invoke<String>('engineCreate', {
      'modelPath': modelPath,
      'engineConfig': _serializeEngineConfig(config),
    });
    if (result == null || result.isEmpty) {
      throw const LitertLmException(
        code: LitertLmErrorCode.internalError,
        message: 'Native engine creation returned no identifier.',
      );
    }
    return result;
  }

  @override
  Future<void> disposeEngine({required String engineId}) {
    return _invoke<void>('engineDispose', {'engineId': engineId});
  }

  @override
  Future<LmCapabilities> getCapabilities({required String engineId}) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'engineGetCapabilities',
      {'engineId': engineId},
    );
    if (result == null) {
      throw const LitertLmException(
        code: LitertLmErrorCode.internalError,
        message: 'Native capabilities response was null.',
      );
    }
    return LmCapabilities(
      supportsGpuBackend: result['supportsGpuBackend'] == true,
      supportsVisionInput: result['supportsVisionInput'] == true,
      supportsAudioInput: result['supportsAudioInput'] == true,
      supportsSeededSampling: result['supportsSeededSampling'] == true,
      supportsBenchmarkInfo: result['supportsBenchmarkInfo'] == true,
    );
  }

  @override
  Future<String> createConversation({
    required String engineId,
    required LmConversationConfig conversationConfig,
    required LmSessionConfig sessionConfig,
  }) async {
    final result = await _invoke<String>('conversationCreate', {
      'engineId': engineId,
      'conversationConfig': _serializeConversationConfig(conversationConfig),
      'sessionConfig': _serializeSessionConfig(sessionConfig),
    });
    if (result == null || result.isEmpty) {
      throw const LitertLmException(
        code: LitertLmErrorCode.internalError,
        message: 'Native conversation creation returned no identifier.',
      );
    }
    return result;
  }

  @override
  Future<void> disposeConversation({
    required String engineId,
    required String conversationId,
  }) {
    return _invoke<void>('conversationDispose', {
      'engineId': engineId,
      'conversationId': conversationId,
    });
  }

  @override
  Stream<String> generate({
    required String engineId,
    required String conversationId,
    required List<LmContentPart> prompt,
  }) {
    _validatePrompt(prompt);
    final requestId = 'req_${_requestCounter++}';
    final controller = StreamController<String>();
    _requests[requestId] = controller;

    controller.onCancel = () {
      _requests.remove(requestId);
    };

    scheduleMicrotask(() async {
      try {
        await _invoke<void>('conversationGenerate', {
          'engineId': engineId,
          'conversationId': conversationId,
          'requestId': requestId,
          'prompt': _serializePrompt(prompt),
        });
      } catch (error, stackTrace) {
        _requests.remove(requestId);
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    });

    return controller.stream;
  }

  @override
  Stream<String> sendToolResponse({
    required String engineId,
    required String conversationId,
    required String toolName,
    required String toolResult,
  }) {
    final requestId = 'req_${_requestCounter++}';
    final controller = StreamController<String>();
    _requests[requestId] = controller;

    controller.onCancel = () {
      _requests.remove(requestId);
    };

    scheduleMicrotask(() async {
      try {
        await _invoke<void>('conversationSendToolResponse', {
          'engineId': engineId,
          'conversationId': conversationId,
          'requestId': requestId,
          'toolName': toolName,
          'toolResult': toolResult,
        });
      } catch (error, stackTrace) {
        _requests.remove(requestId);
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    });

    return controller.stream;
  }

  @override
  Future<void> cancelGeneration({
    required String engineId,
    required String conversationId,
  }) {
    return _invoke<void>('conversationCancel', {
      'engineId': engineId,
      'conversationId': conversationId,
    });
  }

  @override
  Future<void> resetConversation({
    required String engineId,
    required String conversationId,
  }) {
    return _invoke<void>('conversationReset', {
      'engineId': engineId,
      'conversationId': conversationId,
    });
  }

  @override
  Future<LmBenchmarkInfo?> getBenchmarkInfo({
    required String engineId,
    required String conversationId,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'conversationGetBenchmarkInfo',
      {'engineId': engineId, 'conversationId': conversationId},
    );
    if (result == null) return null;
    return LmBenchmarkInfo(
      timeToFirstToken: _requireDouble(result, 'timeToFirstToken'),
      initTime: _requireDouble(result, 'initTime'),
      prefillTokensPerSecond: _requireDouble(result, 'prefillTokensPerSecond'),
      decodeTokensPerSecond: _requireDouble(result, 'decodeTokensPerSecond'),
    );
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methodChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw LitertLmException(
        code: _mapErrorCode(error.code),
        message: error.message ?? 'Platform call failed for $method.',
        details: error.details,
      );
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map<Object?, Object?>) {
      return;
    }
    final envelope = EventEnvelope.fromMap(event);
    final controller = _requests[envelope.requestId];
    if (controller == null || controller.isClosed) {
      return;
    }
    switch (envelope.type) {
      case 'chunk':
        if (envelope.text != null && envelope.text!.isNotEmpty) {
          controller.add(envelope.text!);
        }
        return;
      case 'tool_call':
        // Emit tool call as a special prefixed string so Dart can detect it
        if (envelope.toolCalls != null) {
          controller.add('__TOOL_CALL__${envelope.toolCalls}');
        }
        return;
      case 'done':
        _requests.remove(envelope.requestId);
        controller.close();
        return;
      case 'error':
        _requests.remove(envelope.requestId);
        controller.addError(
          LitertLmException(
            code: _mapErrorCode(envelope.code),
            message: envelope.message ?? 'Generation failed.',
          ),
        );
        controller.close();
        return;
      default:
        // Unknown type — log and ignore instead of erroring
        return;
    }
  }

  void dispose() {
    for (final controller in _requests.values) {
      controller.close();
    }
    _requests.clear();
    _subscription.cancel();
  }

  static void _validateModelPath(String modelPath) {
    if (modelPath.isEmpty) {
      throw ArgumentError.value(modelPath, 'modelPath', 'Must not be empty.');
    }
  }

  static void _validatePrompt(List<LmContentPart> prompt) {
    if (prompt.isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'Must not be empty.');
    }
  }

  static double _requireDouble(Map<Object?, Object?> raw, String key) {
    final value = raw[key];
    if (value is num) return value.toDouble();
    throw LitertLmException(
      code: LitertLmErrorCode.internalError,
      message: 'Native benchmark response is missing $key.',
    );
  }

  static LitertLmErrorCode _mapErrorCode(String? rawCode) {
    switch (rawCode) {
      case 'invalid_argument':
      case 'bad_args':
        return LitertLmErrorCode.invalidArgument;
      case 'not_found':
        return LitertLmErrorCode.notFound;
      case 'not_prepared':
        return LitertLmErrorCode.notPrepared;
      case 'unsupported_feature':
        return LitertLmErrorCode.unsupportedFeature;
      case 'generation_cancelled':
        return LitertLmErrorCode.generationCancelled;
      case 'native_failure':
      case 'prepare_failed':
      case 'stream_failed':
      case 'stream_error':
      case 'reset_failed':
        return LitertLmErrorCode.nativeFailure;
      default:
        return LitertLmErrorCode.internalError;
    }
  }

  static Map<String, Object?> _serializeEngineConfig(LmEngineConfig config) => {
    'backend': config.backend.name,
    if (config.visionBackend != null)
      'visionBackend': config.visionBackend!.name,
    if (config.audioBackend != null) 'audioBackend': config.audioBackend!.name,
    'maxNumTokens': config.maxNumTokens,
    if (config.activationType != null)
      'activationType': config.activationType!.index,
    if (config.prefillChunkSize != null)
      'prefillChunkSize': config.prefillChunkSize,
    'enableBenchmark': config.enableBenchmark,
  };

  static Map<String, Object?> _serializeSessionConfig(LmSessionConfig config) =>
      {
        if (config.maxOutputTokens != null)
          'maxOutputTokens': config.maxOutputTokens,
        if (config.sampler != null)
          'sampler': _serializeSamplerConfig(config.sampler!),
      };

  static Map<String, Object?> _serializeSamplerConfig(LmSamplerConfig config) =>
      {
        'topK': config.topK,
        'topP': config.topP,
        'temperature': config.temperature,
        if (config.seed != null) 'seed': config.seed,
      };

  static Map<String, Object?> _serializeConversationConfig(
    LmConversationConfig config,
  ) => {
    if (config.systemPrompt != null) 'systemPrompt': config.systemPrompt,
    if (config.initialMessages.isNotEmpty)
      'initialMessages':
          config.initialMessages.map(_serializeMessage).toList(),
    if (config.tools.isNotEmpty)
      'tools': config.tools.map((t) => t.toJson()).toList(),
    if (config.constrainedDecoding) 'constrainedDecoding': true,
  };

  static Map<String, Object?> _serializeMessage(LmMessage message) => {
    'role': message.role.name,
    'content': _serializePrompt(message.parts),
  };

  static List<Map<String, Object?>> _serializePrompt(
    List<LmContentPart> prompt,
  ) {
    return prompt
        .map((part) {
          switch (part) {
            case LmTextPart(:final text):
              if (text.isEmpty) {
                throw ArgumentError.value(text, 'text', 'Must not be empty.');
              }
              return <String, Object?>{'type': 'text', 'text': text};
            case LmImagePathPart(:final path):
              if (path.isEmpty) {
                throw ArgumentError.value(path, 'path', 'Must not be empty.');
              }
              return <String, Object?>{'type': 'image_path', 'path': path};
          }
        })
        .toList(growable: false);
  }
}
