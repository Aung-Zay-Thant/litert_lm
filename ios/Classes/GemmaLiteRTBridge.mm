#import "GemmaLiteRTBridge.h"

#import <dlfcn.h>
#import <sys/stat.h>

#import "LiteRTLM/engine.h"

static NSString *const GemmaLiteRTErrorDomain = @"GemmaLiteRTBridge";

namespace {

struct LiteRtRuntime {
  void *constraintProviderHandle = nullptr;
  void *engineHandle = nullptr;

  // Logging
  void (*setMinLogLevel)(int) = nullptr;

  // Engine settings
  LiteRtLmEngineSettings *(*engineSettingsCreate)(const char *, const char *, const char *, const char *) = nullptr;
  void (*engineSettingsDelete)(LiteRtLmEngineSettings *) = nullptr;
  void (*engineSettingsSetMaxNumTokens)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsSetCacheDir)(LiteRtLmEngineSettings *, const char *) = nullptr;
  void (*engineSettingsSetActivationDataType)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsSetPrefillChunkSize)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsEnableBenchmark)(LiteRtLmEngineSettings *) = nullptr;

  // Engine lifecycle
  LiteRtLmEngine *(*engineCreate)(const LiteRtLmEngineSettings *) = nullptr;
  void (*engineDelete)(LiteRtLmEngine *) = nullptr;

  // Session config
  LiteRtLmSessionConfig *(*sessionConfigCreate)() = nullptr;
  void (*sessionConfigSetMaxOutputTokens)(LiteRtLmSessionConfig *, int) = nullptr;
  void (*sessionConfigSetSamplerParams)(LiteRtLmSessionConfig *, const LiteRtLmSamplerParams *) = nullptr;
  void (*sessionConfigDelete)(LiteRtLmSessionConfig *) = nullptr;

  // Conversation config + lifecycle
  LiteRtLmConversationConfig *(*conversationConfigCreate)(LiteRtLmEngine *, const LiteRtLmSessionConfig *, const char *, const char *, const char *, bool) = nullptr;
  void (*conversationConfigDelete)(LiteRtLmConversationConfig *) = nullptr;
  LiteRtLmConversation *(*conversationCreate)(LiteRtLmEngine *, LiteRtLmConversationConfig *) = nullptr;
  void (*conversationDelete)(LiteRtLmConversation *) = nullptr;

  // Inference
  int (*conversationSendMessageStream)(LiteRtLmConversation *, const char *, const char *, LiteRtLmStreamCallback, void *) = nullptr;
  void (*conversationCancelProcess)(LiteRtLmConversation *) = nullptr;

  // Response
  const char *(*jsonResponseGetString)(const LiteRtLmJsonResponse *) = nullptr;
  void (*jsonResponseDelete)(LiteRtLmJsonResponse *) = nullptr;

  // Benchmark
  LiteRtLmBenchmarkInfo *(*conversationGetBenchmarkInfo)(LiteRtLmConversation *) = nullptr;
  void (*benchmarkInfoDelete)(LiteRtLmBenchmarkInfo *) = nullptr;
  double (*benchmarkInfoGetTimeToFirstToken)(const LiteRtLmBenchmarkInfo *) = nullptr;
  double (*benchmarkInfoGetTotalInitTime)(const LiteRtLmBenchmarkInfo *) = nullptr;
  int (*benchmarkInfoGetNumPrefillTurns)(const LiteRtLmBenchmarkInfo *) = nullptr;
  int (*benchmarkInfoGetNumDecodeTurns)(const LiteRtLmBenchmarkInfo *) = nullptr;
  double (*benchmarkInfoGetPrefillTokensPerSecAt)(const LiteRtLmBenchmarkInfo *, int) = nullptr;
  double (*benchmarkInfoGetDecodeTokensPerSecAt)(const LiteRtLmBenchmarkInfo *, int) = nullptr;
};

struct StreamContext {
  GemmaStreamChunkBlock block;
  __unsafe_unretained GemmaLiteRTBridge *bridge;
};

void streamCallbackTrampoline(void *callbackData, const char *chunk, bool isFinal, const char *errorMsg) {
  StreamContext *ctx = static_cast<StreamContext *>(callbackData);
  NSString *chunkString = chunk ? [NSString stringWithUTF8String:chunk] : nil;
  NSString *errorString = errorMsg ? [NSString stringWithUTF8String:errorMsg] : nil;
  BOOL final_ = isFinal ? YES : NO;

  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *plainText = nil;
    if (chunkString.length > 0) {
      NSError *parseError = nil;
      plainText = [ctx->bridge extractTextFromResponseJSONString:chunkString error:&parseError];
      if (plainText == nil) {
        plainText = chunkString;
      }
    }
    ctx->block(plainText, final_, errorString);
    if (final_) {
      delete ctx;
    }
  });
}

}  // namespace

@implementation GemmaLiteRTBridge {
  LiteRtRuntime _runtime;
  LiteRtLmEngine *_engine;
  LiteRtLmConversation *_conversation;
  NSString *_currentModelPath;
  NSDictionary *_conversationConfig;
  BOOL _benchmarkEnabled;
}

- (void)dealloc {
  [self teardown];
  [self unloadRuntime];
}

#pragma mark - Public API

- (BOOL)prepareModelAtPath:(NSString *)modelPath
              engineConfig:(nullable NSDictionary *)engineConfig
        conversationConfig:(nullable NSDictionary *)conversationConfig
                     error:(NSError **)error {
  if (_engine != nullptr && [_currentModelPath isEqualToString:modelPath]) {
    return YES;
  }

  _conversationConfig = [conversationConfig copy];

  struct stat fileInfo;
  if (stat(modelPath.fileSystemRepresentation, &fileInfo) != 0) {
    [self assignError:error message:[NSString stringWithFormat:@"Model file not found at %@.", modelPath]];
    return NO;
  }

  if (fileInfo.st_size < (1024ll * 1024ll * 1024ll)) {
    [self assignError:error message:@"Model file looks incomplete. Delete and re-download."];
    return NO;
  }

  if (![self ensureRuntimeLoaded:error]) {
    return NO;
  }

  [self teardown];

  NSString *cacheDirectory = [self ensureCacheDirectory:error];
  if (cacheDirectory == nil) {
    return NO;
  }

  _runtime.setMinLogLevel(1);  // WARNING+

  // Parse engine config
  NSString *backend = engineConfig[@"backend"] ?: @"cpu";
  NSString *visionBackend = engineConfig[@"visionBackend"];
  NSString *audioBackend = engineConfig[@"audioBackend"];
  int maxNumTokens = [engineConfig[@"maxNumTokens"] intValue] ?: 4096;
  NSNumber *activationType = engineConfig[@"activationType"];
  NSNumber *prefillChunkSize = engineConfig[@"prefillChunkSize"];
  _benchmarkEnabled = [engineConfig[@"enableBenchmark"] boolValue];

  LiteRtLmEngineSettings *settings = _runtime.engineSettingsCreate(
      modelPath.UTF8String,
      backend.UTF8String,
      visionBackend ? visionBackend.UTF8String : nullptr,
      audioBackend ? audioBackend.UTF8String : nullptr);

  if (settings == nullptr) {
    [self assignError:error message:@"Failed to create engine settings."];
    return NO;
  }

  _runtime.engineSettingsSetMaxNumTokens(settings, maxNumTokens);
  _runtime.engineSettingsSetCacheDir(settings, cacheDirectory.fileSystemRepresentation);

  if (activationType != nil) {
    _runtime.engineSettingsSetActivationDataType(settings, activationType.intValue);
  }
  if (prefillChunkSize != nil) {
    _runtime.engineSettingsSetPrefillChunkSize(settings, prefillChunkSize.intValue);
  }
  if (_benchmarkEnabled) {
    _runtime.engineSettingsEnableBenchmark(settings);
  }

  _engine = _runtime.engineCreate(settings);
  _runtime.engineSettingsDelete(settings);

  if (_engine == nullptr) {
    [self assignError:error message:@"Failed to create engine."];
    return NO;
  }

  _conversation = [self createConversationWithError:error];
  if (_conversation == nullptr) {
    [self teardown];
    return NO;
  }

  _currentModelPath = [modelPath copy];
  return YES;
}

- (BOOL)generateTextStream:(NSString *)prompt
                  imagePath:(nullable NSString *)imagePath
                    onChunk:(GemmaStreamChunkBlock)onChunk
                      error:(NSError **)error {
  if (_conversation == nullptr) {
    [self assignError:error message:@"Model is not prepared."];
    return NO;
  }

  NSString *messageJSON = [self messageJSONStringForPrompt:prompt imagePath:imagePath error:error];
  if (messageJSON == nil) {
    return NO;
  }

  StreamContext *ctx = new StreamContext{[onChunk copy], self};
  int result = _runtime.conversationSendMessageStream(
      _conversation, messageJSON.UTF8String, nullptr, streamCallbackTrampoline, ctx);

  if (result != 0) {
    delete ctx;
    [self assignError:error message:@"Failed to start streaming."];
    return NO;
  }

  return YES;
}

- (void)cancelGeneration {
  if (_conversation != nullptr) {
    _runtime.conversationCancelProcess(_conversation);
  }
}

- (void)resetConversation {
  if (_engine == nullptr) return;

  if (_conversation != nullptr) {
    _runtime.conversationDelete(_conversation);
    _conversation = nullptr;
  }
  _conversation = [self createConversationWithError:nil];
}

- (nullable NSDictionary *)getBenchmarkInfo {
  if (_conversation == nullptr || !_benchmarkEnabled) return nil;

  LiteRtLmBenchmarkInfo *info = _runtime.conversationGetBenchmarkInfo(_conversation);
  if (info == nullptr) return nil;

  double ttft = _runtime.benchmarkInfoGetTimeToFirstToken(info);
  double initTime = _runtime.benchmarkInfoGetTotalInitTime(info);

  double prefillTPS = 0;
  int numPrefill = _runtime.benchmarkInfoGetNumPrefillTurns(info);
  if (numPrefill > 0) {
    prefillTPS = _runtime.benchmarkInfoGetPrefillTokensPerSecAt(info, numPrefill - 1);
  }

  double decodeTPS = 0;
  int numDecode = _runtime.benchmarkInfoGetNumDecodeTurns(info);
  if (numDecode > 0) {
    decodeTPS = _runtime.benchmarkInfoGetDecodeTokensPerSecAt(info, numDecode - 1);
  }

  _runtime.benchmarkInfoDelete(info);

  return @{
    @"timeToFirstToken": @(ttft),
    @"initTime": @(initTime),
    @"prefillTokensPerSec": @(prefillTPS),
    @"decodeTokensPerSec": @(decodeTPS),
  };
}

#pragma mark - Private

- (nullable LiteRtLmConversation *)createConversationWithError:(NSError **)error {
  LiteRtLmSessionConfig *sessionConfig = nullptr;
  LiteRtLmConversationConfig *convConfig = nullptr;

  NSDictionary *sampler = _conversationConfig[@"sampler"];
  NSNumber *maxOutputTokens = _conversationConfig[@"maxOutputTokens"];

  // Session config (sampler + max output tokens)
  if (sampler != nil || maxOutputTokens != nil) {
    sessionConfig = _runtime.sessionConfigCreate();
    if (sessionConfig != nullptr) {
      if (maxOutputTokens != nil) {
        _runtime.sessionConfigSetMaxOutputTokens(sessionConfig, maxOutputTokens.intValue);
      }
      if (sampler != nil) {
        LiteRtLmSamplerParams params = {};
        params.type = kTopP;
        params.top_k = [sampler[@"topK"] intValue] ?: 40;
        params.top_p = [sampler[@"topP"] floatValue] ?: 0.95f;
        params.temperature = [sampler[@"temperature"] floatValue] ?: 0.8f;
        params.seed = [sampler[@"seed"] intValue] ?: 0;
        _runtime.sessionConfigSetSamplerParams(sessionConfig, &params);
      }
    }
  }

  // System prompt
  NSString *systemPrompt = _conversationConfig[@"systemPrompt"];
  NSString *systemJSON = nil;
  if (systemPrompt.length > 0) {
    NSDictionary *systemMsg = @{
      @"role": @"system",
      @"content": @[@{@"type": @"text", @"text": systemPrompt}],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:systemMsg options:0 error:nil];
    systemJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  }

  // Initial messages
  NSArray *initialMessages = _conversationConfig[@"initialMessages"];
  NSString *messagesJSON = nil;
  if ([initialMessages isKindOfClass:[NSArray class]] && initialMessages.count > 0) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:initialMessages options:0 error:nil];
    messagesJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  }

  convConfig = _runtime.conversationConfigCreate(
      _engine,
      sessionConfig,
      systemJSON ? systemJSON.UTF8String : nullptr,
      nullptr,  // tools JSON
      messagesJSON ? messagesJSON.UTF8String : nullptr,
      false);   // constrained decoding

  if (sessionConfig != nullptr) {
    _runtime.sessionConfigDelete(sessionConfig);
  }

  LiteRtLmConversation *conversation = _runtime.conversationCreate(_engine, convConfig);

  if (convConfig != nullptr) {
    _runtime.conversationConfigDelete(convConfig);
  }

  if (conversation == nullptr) {
    [self assignError:error message:@"Failed to create conversation."];
  }

  return conversation;
}

- (void)teardown {
  if (_conversation != nullptr) {
    _runtime.conversationDelete(_conversation);
    _conversation = nullptr;
  }
  if (_engine != nullptr) {
    _runtime.engineDelete(_engine);
    _engine = nullptr;
  }
  _currentModelPath = nil;
}

- (BOOL)ensureRuntimeLoaded:(NSError **)error {
  if (_runtime.engineHandle != nullptr) return YES;

  NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
  NSString *constraintProviderPath = [frameworksPath stringByAppendingPathComponent:@"libGemmaModelConstraintProvider.dylib"];
  NSString *enginePath = [frameworksPath stringByAppendingPathComponent:@"libengine_cpu_shared.dylib"];

  _runtime.constraintProviderHandle = dlopen(constraintProviderPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (_runtime.constraintProviderHandle == nullptr) {
    [self assignDlError:error prefix:@"Failed to load constraint provider."];
    return NO;
  }

  _runtime.engineHandle = dlopen(enginePath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (_runtime.engineHandle == nullptr) {
    [self assignDlError:error prefix:@"Failed to load engine runtime."];
    [self unloadRuntime];
    return NO;
  }

  // Load all symbols
  struct SymbolEntry { void *storage; const char *name; };
  SymbolEntry symbols[] = {
    {&_runtime.setMinLogLevel, "litert_lm_set_min_log_level"},
    {&_runtime.engineSettingsCreate, "litert_lm_engine_settings_create"},
    {&_runtime.engineSettingsDelete, "litert_lm_engine_settings_delete"},
    {&_runtime.engineSettingsSetMaxNumTokens, "litert_lm_engine_settings_set_max_num_tokens"},
    {&_runtime.engineSettingsSetCacheDir, "litert_lm_engine_settings_set_cache_dir"},
    {&_runtime.engineSettingsSetActivationDataType, "litert_lm_engine_settings_set_activation_data_type"},
    {&_runtime.engineSettingsSetPrefillChunkSize, "litert_lm_engine_settings_set_prefill_chunk_size"},
    {&_runtime.engineSettingsEnableBenchmark, "litert_lm_engine_settings_enable_benchmark"},
    {&_runtime.engineCreate, "litert_lm_engine_create"},
    {&_runtime.engineDelete, "litert_lm_engine_delete"},
    {&_runtime.sessionConfigCreate, "litert_lm_session_config_create"},
    {&_runtime.sessionConfigSetMaxOutputTokens, "litert_lm_session_config_set_max_output_tokens"},
    {&_runtime.sessionConfigSetSamplerParams, "litert_lm_session_config_set_sampler_params"},
    {&_runtime.sessionConfigDelete, "litert_lm_session_config_delete"},
    {&_runtime.conversationConfigCreate, "litert_lm_conversation_config_create"},
    {&_runtime.conversationConfigDelete, "litert_lm_conversation_config_delete"},
    {&_runtime.conversationCreate, "litert_lm_conversation_create"},
    {&_runtime.conversationDelete, "litert_lm_conversation_delete"},
    {&_runtime.conversationSendMessageStream, "litert_lm_conversation_send_message_stream"},
    {&_runtime.conversationCancelProcess, "litert_lm_conversation_cancel_process"},
    {&_runtime.jsonResponseGetString, "litert_lm_json_response_get_string"},
    {&_runtime.jsonResponseDelete, "litert_lm_json_response_delete"},
    {&_runtime.conversationGetBenchmarkInfo, "litert_lm_conversation_get_benchmark_info"},
    {&_runtime.benchmarkInfoDelete, "litert_lm_benchmark_info_delete"},
    {&_runtime.benchmarkInfoGetTimeToFirstToken, "litert_lm_benchmark_info_get_time_to_first_token"},
    {&_runtime.benchmarkInfoGetTotalInitTime, "litert_lm_benchmark_info_get_total_init_time_in_second"},
    {&_runtime.benchmarkInfoGetNumPrefillTurns, "litert_lm_benchmark_info_get_num_prefill_turns"},
    {&_runtime.benchmarkInfoGetNumDecodeTurns, "litert_lm_benchmark_info_get_num_decode_turns"},
    {&_runtime.benchmarkInfoGetPrefillTokensPerSecAt, "litert_lm_benchmark_info_get_prefill_tokens_per_sec_at"},
    {&_runtime.benchmarkInfoGetDecodeTokensPerSecAt, "litert_lm_benchmark_info_get_decode_tokens_per_sec_at"},
  };

  for (const auto &sym : symbols) {
    if (![self loadSymbol:sym.storage name:sym.name error:error]) {
      [self unloadRuntime];
      return NO;
    }
  }

  return YES;
}

- (nullable NSString *)ensureCacheDirectory:(NSError **)error {
  NSURL *cachesDirectory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
  if (cachesDirectory == nil) {
    [self assignError:error message:@"Unable to find caches directory."];
    return nil;
  }
  NSURL *runtimeDirectory = [cachesDirectory URLByAppendingPathComponent:@"LiteRTLMCache" isDirectory:YES];
  if (![NSFileManager.defaultManager createDirectoryAtURL:runtimeDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
    return nil;
  }
  return runtimeDirectory.path;
}

- (void)unloadRuntime {
  if (_runtime.engineHandle != nullptr) dlclose(_runtime.engineHandle);
  if (_runtime.constraintProviderHandle != nullptr) dlclose(_runtime.constraintProviderHandle);
  _runtime = LiteRtRuntime{};
}

- (BOOL)loadSymbol:(void *)symbolStorage name:(const char *)name error:(NSError **)error {
  void *symbol = dlsym(_runtime.engineHandle, name);
  if (symbol == nullptr) {
    [self assignDlError:error prefix:[NSString stringWithFormat:@"Missing symbol %s.", name]];
    return NO;
  }
  *(void **)symbolStorage = symbol;
  return YES;
}

- (nullable NSString *)messageJSONStringForPrompt:(NSString *)prompt
                                        imagePath:(nullable NSString *)imagePath
                                           error:(NSError **)error {
  NSMutableArray<NSDictionary *> *content = [NSMutableArray arrayWithObject:@{@"type": @"text", @"text": prompt}];
  if (imagePath.length > 0) {
    [content addObject:@{@"type": @"image", @"path": imagePath}];
  }
  NSDictionary *message = @{@"role": @"user", @"content": content};
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:error];
  if (jsonData == nil) {
    [self assignError:error message:@"Failed to encode prompt."];
    return nil;
  }
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (nullable NSString *)extractTextFromResponseJSONString:(NSString *)jsonString
                                                   error:(NSError **)error {
  NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) return jsonString;

  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:[NSDictionary class]]) return jsonString;

  NSDictionary *dict = (NSDictionary *)parsed;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];

  id content = dict[@"content"];
  if ([content isKindOfClass:[NSString class]]) {
    if ([(NSString *)content length] > 0) [parts addObject:content];
  } else if ([content isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray *)content) {
      if (![item isKindOfClass:[NSDictionary class]]) continue;
      if ([item[@"type"] isEqualToString:@"text"] && [item[@"text"] length] > 0) {
        [parts addObject:item[@"text"]];
      }
    }
  }

  return parts.count > 0 ? [parts componentsJoinedByString:@""] : @"";
}

- (void)assignDlError:(NSError **)error prefix:(NSString *)prefix {
  const char *dlMessage = dlerror();
  NSString *details = dlMessage ? [NSString stringWithUTF8String:dlMessage] : @"Unknown error.";
  [self assignError:error message:[NSString stringWithFormat:@"%@ %@", prefix, details]];
}

- (void)assignError:(NSError **)error message:(NSString *)message {
  if (error == nullptr) return;
  *error = [NSError errorWithDomain:GemmaLiteRTErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
