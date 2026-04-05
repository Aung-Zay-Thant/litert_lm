#import "GemmaLiteRTBridge.h"

#import <dlfcn.h>
#import <sys/stat.h>

#import "LiteRTLM/engine.h"

static NSString *const GemmaLiteRTErrorDomain = @"GemmaLiteRTBridge";

@interface GemmaLiteRTBridge ()
- (nullable NSString *)extractTextFromResponseJSONString:(NSString *)jsonString;
@end

@interface LiteRtConversationBox : NSObject {
 @public
  LiteRtLmConversation *conversation;
  NSDictionary *conversationConfig;
  NSDictionary *sessionConfig;
  NSString *activeRequestId;
}
@end

@implementation LiteRtConversationBox
@end

namespace {

struct LiteRtRuntime {
  void *constraintProviderHandle = nullptr;
  void *engineHandle = nullptr;

  void (*setMinLogLevel)(int) = nullptr;
  LiteRtLmEngineSettings *(*engineSettingsCreate)(const char *, const char *, const char *, const char *) = nullptr;
  void (*engineSettingsDelete)(LiteRtLmEngineSettings *) = nullptr;
  void (*engineSettingsSetMaxNumTokens)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsSetCacheDir)(LiteRtLmEngineSettings *, const char *) = nullptr;
  void (*engineSettingsSetActivationDataType)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsSetPrefillChunkSize)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsEnableBenchmark)(LiteRtLmEngineSettings *) = nullptr;
  LiteRtLmEngine *(*engineCreate)(const LiteRtLmEngineSettings *) = nullptr;
  void (*engineDelete)(LiteRtLmEngine *) = nullptr;
  LiteRtLmSessionConfig *(*sessionConfigCreate)() = nullptr;
  void (*sessionConfigSetMaxOutputTokens)(LiteRtLmSessionConfig *, int) = nullptr;
  void (*sessionConfigSetSamplerParams)(LiteRtLmSessionConfig *, const LiteRtLmSamplerParams *) = nullptr;
  void (*sessionConfigDelete)(LiteRtLmSessionConfig *) = nullptr;
  LiteRtLmConversationConfig *(*conversationConfigCreate)(LiteRtLmEngine *, const LiteRtLmSessionConfig *, const char *, const char *, const char *, bool) = nullptr;
  void (*conversationConfigDelete)(LiteRtLmConversationConfig *) = nullptr;
  LiteRtLmConversation *(*conversationCreate)(LiteRtLmEngine *, LiteRtLmConversationConfig *) = nullptr;
  void (*conversationDelete)(LiteRtLmConversation *) = nullptr;
  LiteRtLmJsonResponse *(*conversationSendMessage)(LiteRtLmConversation *, const char *, const char *) = nullptr;
  int (*conversationSendMessageStream)(LiteRtLmConversation *, const char *, const char *, LiteRtLmStreamCallback, void *) = nullptr;
  void (*conversationCancelProcess)(LiteRtLmConversation *) = nullptr;
  const char *(*jsonResponseGetString)(const LiteRtLmJsonResponse *) = nullptr;
  void (*jsonResponseDelete)(LiteRtLmJsonResponse *) = nullptr;
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
  GemmaStreamEventBlock block;
  __unsafe_unretained GemmaLiteRTBridge *bridge;
  __unsafe_unretained LiteRtConversationBox *box;
  NSString *requestId;
};

void streamCallbackTrampoline(void *callbackData, const char *chunk, bool isFinal, const char *errorMsg) {
  StreamContext *ctx = static_cast<StreamContext *>(callbackData);
  NSString *chunkString = chunk ? [NSString stringWithUTF8String:chunk] : nil;
  NSString *errorString = errorMsg ? [NSString stringWithUTF8String:errorMsg] : nil;

  dispatch_async(dispatch_get_main_queue(), ^{
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithObject:ctx->requestId forKey:@"requestId"];
    if (errorString.length > 0) {
      event[@"type"] = @"error";
      event[@"code"] = @"native_failure";
      event[@"message"] = errorString;
    } else if (isFinal) {
      event[@"type"] = @"done";
    } else {
      NSString *plainText = nil;
      if (chunkString.length > 0) {
        plainText = [ctx->bridge extractTextFromResponseJSONString:chunkString];
      }
      event[@"type"] = @"chunk";
      if (plainText.length > 0) {
        event[@"text"] = plainText;
      }
    }
    ctx->box->activeRequestId = nil;
    ctx->block(event);
    if (isFinal || errorString.length > 0) {
      delete ctx;
    }
  });
}

}  // namespace

@implementation GemmaLiteRTBridge {
  LiteRtRuntime _runtime;
  LiteRtLmEngine *_engine;
  NSString *_currentModelPath;
  BOOL _benchmarkEnabled;
  NSMutableDictionary<NSString *, LiteRtConversationBox *> *_conversations;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _conversations = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  [self teardown];
  [self unloadRuntime];
}

- (BOOL)prepareModelAtPath:(NSString *)modelPath
              engineConfig:(nullable NSDictionary *)engineConfig
                     error:(NSError **)error {
  struct stat fileInfo;
  if (stat(modelPath.fileSystemRepresentation, &fileInfo) != 0) {
    [self assignError:error code:@"not_found" message:[NSString stringWithFormat:@"Model file not found at %@.", modelPath]];
    return NO;
  }

  if (fileInfo.st_size < (1024ll * 1024ll * 1024ll)) {
    [self assignError:error code:@"native_failure" message:@"Model file looks incomplete. Delete and re-download."];
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

  NSString *backend = engineConfig[@"backend"] ?: @"cpu";
  NSString *visionBackend = engineConfig[@"visionBackend"];
  NSString *audioBackend = engineConfig[@"audioBackend"];
  int maxNumTokens = [engineConfig[@"maxNumTokens"] intValue] ?: 4096;
  NSNumber *activationType = engineConfig[@"activationType"];
  NSNumber *prefillChunkSize = engineConfig[@"prefillChunkSize"];
  _benchmarkEnabled = [engineConfig[@"enableBenchmark"] boolValue];

  _runtime.setMinLogLevel(1);

  LiteRtLmEngineSettings *settings = _runtime.engineSettingsCreate(
      modelPath.UTF8String,
      backend.UTF8String,
      visionBackend ? visionBackend.UTF8String : nullptr,
      audioBackend ? audioBackend.UTF8String : nullptr);
  if (settings == nullptr) {
    [self assignError:error code:@"native_failure" message:@"Failed to create engine settings."];
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
    [self assignError:error code:@"native_failure" message:@"Failed to create engine."];
    return NO;
  }

  _currentModelPath = [modelPath copy];
  return YES;
}

- (nullable NSString *)createConversationWithConfig:(nullable NSDictionary *)conversationConfig
                                      sessionConfig:(nullable NSDictionary *)sessionConfig
                                              error:(NSError **)error {
  if (_engine == nullptr) {
    [self assignError:error code:@"not_prepared" message:@"Engine is not prepared."];
    return nil;
  }

  LiteRtLmConversation *conversation = [self createConversationPointerWithConversationConfig:conversationConfig
                                                                                sessionConfig:sessionConfig
                                                                                        error:error];
  if (conversation == nullptr) {
    return nil;
  }

  NSString *conversationId = NSUUID.UUID.UUIDString;
  LiteRtConversationBox *box = [LiteRtConversationBox new];
  box->conversation = conversation;
  box->conversationConfig = [conversationConfig copy] ?: @{};
  box->sessionConfig = [sessionConfig copy] ?: @{};
  _conversations[conversationId] = box;
  return conversationId;
}

- (BOOL)generateTextStreamForConversationId:(NSString *)conversationId
                                promptParts:(NSArray<NSDictionary *> *)promptParts
                                  requestId:(NSString *)requestId
                                    onEvent:(GemmaStreamEventBlock)onEvent
                                      error:(NSError **)error {
  LiteRtConversationBox *box = _conversations[conversationId];
  if (box == nil || box->conversation == nullptr) {
    [self assignError:error code:@"not_found" message:@"Conversation not found."];
    return NO;
  }
  if (box->activeRequestId != nil) {
    [self assignError:error code:@"native_failure" message:@"Conversation is already generating."];
    return NO;
  }

  NSString *messageJSON = [self messageJSONStringForPromptParts:promptParts error:error];
  if (messageJSON == nil) {
    return NO;
  }

  box->activeRequestId = requestId;
  GemmaStreamEventBlock eventBlock = [onEvent copy];
  NSString *requestIdCopy = [requestId copy];
  NSString *messageJSONCopy = [messageJSON copy];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    LiteRtLmJsonResponse *response = _runtime.conversationSendMessage(
        box->conversation,
        messageJSONCopy.UTF8String,
        nullptr);
    dispatch_async(dispatch_get_main_queue(), ^{
      box->activeRequestId = nil;

    if (response == nullptr) {
        eventBlock(@{
          @"requestId": requestIdCopy,
          @"type": @"error",
          @"code": @"native_failure",
          @"message": @"Generation failed.",
        });
        return;
      }

      const char *responseCString = _runtime.jsonResponseGetString(response);
      NSString *responseJSONString = responseCString == nullptr ? nil : [NSString stringWithUTF8String:responseCString];
      _runtime.jsonResponseDelete(response);

      NSString *plainText = responseJSONString.length > 0
          ? [self extractTextFromResponseJSONString:responseJSONString]
          : @"";

      if (plainText.length > 0) {
        eventBlock(@{
          @"requestId": requestIdCopy,
          @"type": @"chunk",
          @"text": plainText,
        });
      }
      eventBlock(@{
        @"requestId": requestIdCopy,
        @"type": @"done",
      });
    });
  });

  return YES;
}

- (void)cancelGenerationForConversationId:(NSString *)conversationId {
  LiteRtConversationBox *box = _conversations[conversationId];
  if (box != nil && box->conversation != nullptr) {
    _runtime.conversationCancelProcess(box->conversation);
  }
}

- (BOOL)resetConversationWithId:(NSString *)conversationId error:(NSError **)error {
  LiteRtConversationBox *box = _conversations[conversationId];
  if (box == nil || box->conversation == nullptr) {
    [self assignError:error code:@"not_found" message:@"Conversation not found."];
    return NO;
  }

  LiteRtLmConversation *replacement = [self createConversationPointerWithConversationConfig:box->conversationConfig
                                                                               sessionConfig:box->sessionConfig
                                                                                       error:error];
  if (replacement == nullptr) {
    return NO;
  }

  _runtime.conversationDelete(box->conversation);
  box->conversation = replacement;
  box->activeRequestId = nil;
  return YES;
}

- (void)disposeConversationWithId:(NSString *)conversationId {
  LiteRtConversationBox *box = _conversations[conversationId];
  if (box == nil) {
    return;
  }
  if (box->conversation != nullptr) {
    _runtime.conversationDelete(box->conversation);
    box->conversation = nullptr;
  }
  [_conversations removeObjectForKey:conversationId];
}

- (nullable NSDictionary *)getBenchmarkInfoForConversationId:(NSString *)conversationId {
  LiteRtConversationBox *box = _conversations[conversationId];
  if (box == nil || box->conversation == nullptr || !_benchmarkEnabled) {
    return nil;
  }

  LiteRtLmBenchmarkInfo *info = _runtime.conversationGetBenchmarkInfo(box->conversation);
  if (info == nullptr) {
    return nil;
  }

  double prefillTokensPerSecond = 0;
  int numPrefillTurns = _runtime.benchmarkInfoGetNumPrefillTurns(info);
  if (numPrefillTurns > 0) {
    prefillTokensPerSecond = _runtime.benchmarkInfoGetPrefillTokensPerSecAt(info, numPrefillTurns - 1);
  }

  double decodeTokensPerSecond = 0;
  int numDecodeTurns = _runtime.benchmarkInfoGetNumDecodeTurns(info);
  if (numDecodeTurns > 0) {
    decodeTokensPerSecond = _runtime.benchmarkInfoGetDecodeTokensPerSecAt(info, numDecodeTurns - 1);
  }

  NSDictionary *result = @{
    @"timeToFirstToken": @(_runtime.benchmarkInfoGetTimeToFirstToken(info)),
    @"initTime": @(_runtime.benchmarkInfoGetTotalInitTime(info)),
    @"prefillTokensPerSecond": @(prefillTokensPerSecond),
    @"decodeTokensPerSecond": @(decodeTokensPerSecond),
  };
  _runtime.benchmarkInfoDelete(info);
  return result;
}

- (nullable LiteRtLmConversation *)createConversationPointerWithConversationConfig:(NSDictionary *)conversationConfig
                                                                      sessionConfig:(NSDictionary *)sessionConfig
                                                                              error:(NSError **)error {
  LiteRtLmSessionConfig *session = nullptr;
  LiteRtLmConversationConfig *config = nullptr;

  NSDictionary *sampler = sessionConfig[@"sampler"];
  NSNumber *maxOutputTokens = sessionConfig[@"maxOutputTokens"];
  if (sampler != nil || maxOutputTokens != nil) {
    session = _runtime.sessionConfigCreate();
    if (session == nullptr) {
      [self assignError:error code:@"native_failure" message:@"Failed to create session config."];
      return nullptr;
    }
    if (maxOutputTokens != nil) {
      _runtime.sessionConfigSetMaxOutputTokens(session, maxOutputTokens.intValue);
    }
    if (sampler != nil) {
      LiteRtLmSamplerParams params = {};
      params.type = kTopP;
      params.top_k = [sampler[@"topK"] intValue] ?: 40;
      params.top_p = [sampler[@"topP"] floatValue] ?: 0.95f;
      params.temperature = [sampler[@"temperature"] floatValue] ?: 0.8f;
      params.seed = [sampler[@"seed"] intValue] ?: 0;
      _runtime.sessionConfigSetSamplerParams(session, &params);
    }
  }

  NSString *systemJSON = nil;
  NSString *messagesJSON = nil;
  NSString *systemPrompt = conversationConfig[@"systemPrompt"];
  NSArray *initialMessages = conversationConfig[@"initialMessages"];

  if (systemPrompt.length > 0) {
    NSDictionary *systemMessage = @{
      @"role": @"system",
      @"content": @[@{@"type": @"text", @"text": systemPrompt}],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:systemMessage options:0 error:nil];
    systemJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  }

  if ([initialMessages isKindOfClass:[NSArray class]] && initialMessages.count > 0) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:initialMessages options:0 error:nil];
    messagesJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  }

  config = _runtime.conversationConfigCreate(
      _engine,
      session,
      systemJSON ? systemJSON.UTF8String : nullptr,
      nullptr,
      messagesJSON ? messagesJSON.UTF8String : nullptr,
      false);

  if (session != nullptr) {
    _runtime.sessionConfigDelete(session);
  }

  LiteRtLmConversation *conversation = _runtime.conversationCreate(_engine, config);
  if (config != nullptr) {
    _runtime.conversationConfigDelete(config);
  }

  if (conversation == nullptr) {
    [self assignError:error code:@"native_failure" message:@"Failed to create conversation."];
  }
  return conversation;
}

- (void)teardown {
  for (NSString *conversationId in _conversations.allKeys) {
    LiteRtConversationBox *box = _conversations[conversationId];
    if (box->conversation != nullptr) {
      _runtime.conversationDelete(box->conversation);
      box->conversation = nullptr;
    }
  }
  [_conversations removeAllObjects];
  if (_engine != nullptr) {
    _runtime.engineDelete(_engine);
    _engine = nullptr;
  }
  _currentModelPath = nil;
}

- (BOOL)ensureRuntimeLoaded:(NSError **)error {
  if (_runtime.engineHandle != nullptr) {
    return YES;
  }

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
    {&_runtime.conversationSendMessage, "litert_lm_conversation_send_message"},
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

  for (const auto &symbol : symbols) {
    if (![self loadSymbol:symbol.storage name:symbol.name error:error]) {
      [self unloadRuntime];
      return NO;
    }
  }

  return YES;
}

- (nullable NSString *)ensureCacheDirectory:(NSError **)error {
  NSURL *cachesDirectory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
  if (cachesDirectory == nil) {
    [self assignError:error code:@"native_failure" message:@"Unable to find caches directory."];
    return nil;
  }
  NSURL *runtimeDirectory = [cachesDirectory URLByAppendingPathComponent:@"LiteRTLMCache" isDirectory:YES];
  if (![NSFileManager.defaultManager createDirectoryAtURL:runtimeDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
    return nil;
  }
  return runtimeDirectory.path;
}

- (void)unloadRuntime {
  if (_runtime.engineHandle != nullptr) {
    dlclose(_runtime.engineHandle);
  }
  if (_runtime.constraintProviderHandle != nullptr) {
    dlclose(_runtime.constraintProviderHandle);
  }
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

- (nullable NSString *)messageJSONStringForPromptParts:(NSArray<NSDictionary *> *)promptParts error:(NSError **)error {
  NSMutableArray<NSDictionary *> *normalizedParts = [NSMutableArray arrayWithCapacity:promptParts.count];
  for (id rawPart in promptParts) {
    if (![rawPart isKindOfClass:[NSDictionary class]]) {
      continue;
    }

    NSDictionary *part = (NSDictionary *)rawPart;
    NSString *type = part[@"type"];
    if ([type isEqualToString:@"image_path"]) {
      NSString *path = part[@"path"];
      if (path.length == 0) {
        [self assignError:error code:@"invalid_argument" message:@"Image prompt part is missing path."];
        return nil;
      }
      [normalizedParts addObject:@{
        @"type": @"image",
        @"path": path,
      }];
      continue;
    }

    [normalizedParts addObject:part];
  }

  NSDictionary *message = @{
    @"role": @"user",
    @"content": normalizedParts,
  };
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:error];
  if (jsonData == nil) {
    [self assignError:error code:@"invalid_argument" message:@"Failed to encode prompt."];
    return nil;
  }
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (nullable NSString *)extractTextFromResponseJSONString:(NSString *)jsonString {
  NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    return jsonString;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return jsonString;
  }
  NSDictionary *dict = (NSDictionary *)parsed;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  id content = dict[@"content"];
  if ([content isKindOfClass:[NSString class]]) {
    if ([(NSString *)content length] > 0) {
      [parts addObject:content];
    }
  } else if ([content isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray *)content) {
      if (![item isKindOfClass:[NSDictionary class]]) {
        continue;
      }
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
  [self assignError:error code:@"native_failure" message:[NSString stringWithFormat:@"%@ %@", prefix, details]];
}

- (void)assignError:(NSError **)error code:(NSString *)code message:(NSString *)message {
  if (error == nullptr) {
    return;
  }
  *error = [NSError errorWithDomain:GemmaLiteRTErrorDomain
                               code:1
                           userInfo:@{
                             NSLocalizedDescriptionKey: message,
                             @"code": code,
                           }];
}

@end
