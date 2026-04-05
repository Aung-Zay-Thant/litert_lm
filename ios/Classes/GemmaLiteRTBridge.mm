#import "GemmaLiteRTBridge.h"

#import <dlfcn.h>
#import <sys/stat.h>

#import "LiteRTLM/engine.h"

static NSString *const GemmaLiteRTErrorDomain = @"GemmaLiteRTBridge";

namespace {

struct LiteRtRuntime {
  void *constraintProviderHandle = nullptr;
  void *engineHandle = nullptr;

  void (*setMinLogLevel)(int) = nullptr;
  LiteRtLmEngineSettings *(*engineSettingsCreate)(const char *, const char *, const char *, const char *) = nullptr;
  void (*engineSettingsDelete)(LiteRtLmEngineSettings *) = nullptr;
  void (*engineSettingsSetMaxNumTokens)(LiteRtLmEngineSettings *, int) = nullptr;
  void (*engineSettingsSetCacheDir)(LiteRtLmEngineSettings *, const char *) = nullptr;
  LiteRtLmEngine *(*engineCreate)(const LiteRtLmEngineSettings *) = nullptr;
  void (*engineDelete)(LiteRtLmEngine *) = nullptr;
  LiteRtLmConversationConfig *(*conversationConfigCreate)(LiteRtLmEngine *, const LiteRtLmSessionConfig *, const char *, const char *, const char *, bool) = nullptr;
  void (*conversationConfigDelete)(LiteRtLmConversationConfig *) = nullptr;
  LiteRtLmConversation *(*conversationCreate)(LiteRtLmEngine *, LiteRtLmConversationConfig *) = nullptr;
  void (*conversationDelete)(LiteRtLmConversation *) = nullptr;
  LiteRtLmJsonResponse *(*conversationSendMessage)(LiteRtLmConversation *, const char *, const char *) = nullptr;
  int (*conversationSendMessageStream)(LiteRtLmConversation *, const char *, const char *, LiteRtLmStreamCallback, void *) = nullptr;
  void (*conversationCancelProcess)(LiteRtLmConversation *) = nullptr;
  const char *(*jsonResponseGetString)(const LiteRtLmJsonResponse *) = nullptr;
  void (*jsonResponseDelete)(LiteRtLmJsonResponse *) = nullptr;
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

  // The callback comes from a background thread; dispatch to main for Flutter.
  dispatch_async(dispatch_get_main_queue(), ^{
    // The chunk is JSON like {"content":"text"} — extract the plain text.
    NSString *plainText = nil;
    if (chunkString.length > 0) {
      NSError *parseError = nil;
      plainText = [ctx->bridge extractTextFromResponseJSONString:chunkString error:&parseError];
      if (plainText == nil) {
        // Fallback: send the raw chunk if parsing fails.
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

@interface GemmaLiteRTBridge ()
@end

@implementation GemmaLiteRTBridge {
  LiteRtRuntime _runtime;
  LiteRtLmEngine *_engine;
  LiteRtLmConversation *_conversation;
  NSString *_currentModelPath;
  NSString *_systemPrompt;
  NSString *_toolsJSON;
}

- (void)dealloc {
  [self teardown];
  [self unloadRuntime];
}

- (BOOL)prepareModelAtPath:(NSString *)modelPath
              systemPrompt:(nullable NSString *)systemPrompt
                 toolsJSON:(nullable NSString *)toolsJSON
                     error:(NSError **)error {
  if (_engine != nullptr && [_currentModelPath isEqualToString:modelPath]) {
    return YES;
  }

  _systemPrompt = [systemPrompt copy];
  _toolsJSON = [toolsJSON copy];

  struct stat fileInfo;
  if (stat(modelPath.fileSystemRepresentation, &fileInfo) != 0) {
    [self assignError:error message:[NSString stringWithFormat:@"Model file not found at %@.", modelPath]];
    return NO;
  }

  if (fileInfo.st_size < (1024ll * 1024ll * 1024ll)) {
    [self assignError:error message:[NSString stringWithFormat:@"Model file looks incomplete (%lld bytes). Delete it and download again.", fileInfo.st_size]];
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

  _runtime.setMinLogLevel(0);

  LiteRtLmEngineSettings *settings = _runtime.engineSettingsCreate(
      modelPath.UTF8String,
      "cpu",
      "cpu",
      nullptr);
  if (settings == nullptr) {
    [self assignError:error message:@"Failed to create LiteRT-LM engine settings."];
    return NO;
  }

  _runtime.engineSettingsSetMaxNumTokens(settings, 4096);
  _runtime.engineSettingsSetCacheDir(settings, cacheDirectory.fileSystemRepresentation);
  _engine = _runtime.engineCreate(settings);
  _runtime.engineSettingsDelete(settings);

  if (_engine == nullptr) {
    [self assignError:error message:[NSString stringWithFormat:@"Failed to create LiteRT-LM engine for %@ (%lld bytes).", modelPath.lastPathComponent, fileInfo.st_size]];
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

- (nullable NSString *)generateText:(NSString *)prompt
                              imagePath:(nullable NSString *)imagePath
                                 error:(NSError **)error {
  if (_conversation == nullptr) {
    [self assignError:error message:@"Model is not prepared."];
    return nil;
  }

  NSString *messageJSONString = [self messageJSONStringForPrompt:prompt imagePath:imagePath error:error];
  if (messageJSONString == nil) {
    return nil;
  }

  LiteRtLmJsonResponse *response = _runtime.conversationSendMessage(
      _conversation,
      messageJSONString.UTF8String,
      nullptr);
  if (response == nullptr) {
    [self assignError:error message:@"LiteRT-LM did not return a response."];
    return nil;
  }

  const char *responseCString = _runtime.jsonResponseGetString(response);
  NSString *responseJSONString = responseCString == nullptr ? nil : [NSString stringWithUTF8String:responseCString];
  _runtime.jsonResponseDelete(response);

  if (responseJSONString.length == 0) {
    [self assignError:error message:@"LiteRT-LM returned an empty response."];
    return nil;
  }

  return [self extractTextFromResponseJSONString:responseJSONString error:error];
}

- (BOOL)generateTextStream:(NSString *)prompt
                  imagePath:(nullable NSString *)imagePath
                    onChunk:(GemmaStreamChunkBlock)onChunk
                      error:(NSError **)error {
  if (_conversation == nullptr) {
    [self assignError:error message:@"Model is not prepared."];
    return NO;
  }

  NSString *messageJSONString = [self messageJSONStringForPrompt:prompt imagePath:imagePath error:error];
  if (messageJSONString == nil) {
    return NO;
  }

  StreamContext *ctx = new StreamContext{[onChunk copy], self};
  int result = _runtime.conversationSendMessageStream(
      _conversation,
      messageJSONString.UTF8String,
      nullptr,
      streamCallbackTrampoline,
      ctx);

  if (result != 0) {
    delete ctx;
    [self assignError:error message:@"Failed to start streaming inference."];
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
  if (_engine == nullptr) {
    return;
  }

  if (_conversation != nullptr) {
    _runtime.conversationDelete(_conversation);
    _conversation = nullptr;
  }

  _conversation = [self createConversationWithError:nil];
}

- (nullable LiteRtLmConversation *)createConversationWithError:(NSError **)error {
  LiteRtLmConversationConfig *config = nullptr;

  BOOL hasSystem = _systemPrompt.length > 0;
  BOOL hasTools = _toolsJSON.length > 0;

  if (hasSystem || hasTools) {
    // Build system message JSON.
    NSString *systemJSON = nil;
    if (hasSystem) {
      NSDictionary *systemMsg = @{
        @"role": @"system",
        @"content": @[@{@"type": @"text", @"text": _systemPrompt}],
      };
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:systemMsg options:0 error:nil];
      systemJSON = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
    }

    config = _runtime.conversationConfigCreate(
        _engine,
        nullptr,                                        // session config
        systemJSON ? systemJSON.UTF8String : nullptr,   // system message JSON
        hasTools ? _toolsJSON.UTF8String : nullptr,     // tools JSON
        nullptr,                                        // messages JSON
        false);                                         // constrained decoding
  }

  LiteRtLmConversation *conversation = _runtime.conversationCreate(_engine, config);

  if (config != nullptr) {
    _runtime.conversationConfigDelete(config);
  }

  if (conversation == nullptr) {
    [self assignError:error message:@"Failed to create LiteRT-LM conversation."];
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
  if (_runtime.engineHandle != nullptr) {
    return YES;
  }

  NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
  NSString *constraintProviderPath = [frameworksPath stringByAppendingPathComponent:@"libGemmaModelConstraintProvider.dylib"];
  NSString *enginePath = [frameworksPath stringByAppendingPathComponent:@"libengine_cpu_shared.dylib"];

  _runtime.constraintProviderHandle = dlopen(constraintProviderPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (_runtime.constraintProviderHandle == nullptr) {
    [self assignDlError:error prefix:@"Failed to load GemmaModelConstraintProvider."];
    return NO;
  }

  _runtime.engineHandle = dlopen(enginePath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (_runtime.engineHandle == nullptr) {
    [self assignDlError:error prefix:@"Failed to load LiteRT-LM engine runtime."];
    [self unloadRuntime];
    return NO;
  }

  if (![self loadSymbol:&_runtime.setMinLogLevel name:"litert_lm_set_min_log_level" error:error] ||
      ![self loadSymbol:&_runtime.engineSettingsCreate name:"litert_lm_engine_settings_create" error:error] ||
      ![self loadSymbol:&_runtime.engineSettingsDelete name:"litert_lm_engine_settings_delete" error:error] ||
      ![self loadSymbol:&_runtime.engineSettingsSetMaxNumTokens name:"litert_lm_engine_settings_set_max_num_tokens" error:error] ||
      ![self loadSymbol:&_runtime.engineSettingsSetCacheDir name:"litert_lm_engine_settings_set_cache_dir" error:error] ||
      ![self loadSymbol:&_runtime.engineCreate name:"litert_lm_engine_create" error:error] ||
      ![self loadSymbol:&_runtime.engineDelete name:"litert_lm_engine_delete" error:error] ||
      ![self loadSymbol:&_runtime.conversationConfigCreate name:"litert_lm_conversation_config_create" error:error] ||
      ![self loadSymbol:&_runtime.conversationConfigDelete name:"litert_lm_conversation_config_delete" error:error] ||
      ![self loadSymbol:&_runtime.conversationCreate name:"litert_lm_conversation_create" error:error] ||
      ![self loadSymbol:&_runtime.conversationDelete name:"litert_lm_conversation_delete" error:error] ||
      ![self loadSymbol:&_runtime.conversationSendMessage name:"litert_lm_conversation_send_message" error:error] ||
      ![self loadSymbol:&_runtime.conversationSendMessageStream name:"litert_lm_conversation_send_message_stream" error:error] ||
      ![self loadSymbol:&_runtime.conversationCancelProcess name:"litert_lm_conversation_cancel_process" error:error] ||
      ![self loadSymbol:&_runtime.jsonResponseGetString name:"litert_lm_json_response_get_string" error:error] ||
      ![self loadSymbol:&_runtime.jsonResponseDelete name:"litert_lm_json_response_delete" error:error]) {
    [self unloadRuntime];
    return NO;
  }

  return YES;
}

- (nullable NSString *)ensureCacheDirectory:(NSError **)error {
  NSURL *cachesDirectory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
  if (cachesDirectory == nil) {
    [self assignError:error message:@"Unable to find the iOS caches directory."];
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
    [self assignDlError:error prefix:[NSString stringWithFormat:@"Missing LiteRT-LM symbol %s.", name]];
    return NO;
  }

  *(void **)symbolStorage = symbol;
  return YES;
}

- (nullable NSString *)messageJSONStringForPrompt:(NSString *)prompt
                                        imagePath:(nullable NSString *)imagePath
                                           error:(NSError **)error {
  NSMutableArray<NSDictionary *> *content = [NSMutableArray arrayWithObject:@{
    @"type": @"text",
    @"text": prompt,
  }];

  if (imagePath.length > 0) {
    [content addObject:@{
      @"type": @"image",
      @"path": imagePath,
    }];
  }

  NSDictionary *message = @{
    @"role": @"user",
    @"content": content,
  };

  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:error];
  if (jsonData == nil) {
    [self assignError:error message:@"Failed to encode prompt payload."];
    return nil;
  }

  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (nullable NSString *)extractTextFromResponseJSONString:(NSString *)jsonString
                                                   error:(NSError **)error {
  NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    [self assignError:error message:@"Failed to decode LiteRT-LM JSON response."];
    return nil;
  }

  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    // Not JSON — return the raw string as-is (plain text chunk).
    return jsonString;
  }

  NSDictionary *dict = (NSDictionary *)parsed;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];

  // Check for tool_calls — serialize them as a marker Dart can parse.
  NSArray *toolCalls = dict[@"tool_calls"];
  if ([toolCalls isKindOfClass:[NSArray class]] && toolCalls.count > 0) {
    for (id tc in toolCalls) {
      if (![tc isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary *fn = tc[@"function"];
      if (![fn isKindOfClass:[NSDictionary class]]) continue;

      NSString *name = fn[@"name"];
      id args = fn[@"arguments"];
      if (name.length == 0) continue;

      // Emit a marker that the Dart parser can detect.
      NSMutableDictionary *callObj = [NSMutableDictionary dictionaryWithDictionary:@{@"name": name}];
      if ([args isKindOfClass:[NSDictionary class]]) {
        callObj[@"arguments"] = args;
      } else if ([args isKindOfClass:[NSString class]]) {
        // Arguments might be a JSON string.
        NSData *argsData = [(NSString *)args dataUsingEncoding:NSUTF8StringEncoding];
        id argsParsed = argsData ? [NSJSONSerialization JSONObjectWithData:argsData options:0 error:nil] : nil;
        callObj[@"arguments"] = [argsParsed isKindOfClass:[NSDictionary class]] ? argsParsed : @{};
      } else {
        callObj[@"arguments"] = @{};
      }

      NSData *callData = [NSJSONSerialization dataWithJSONObject:callObj options:0 error:nil];
      if (callData) {
        NSString *callJSON = [[NSString alloc] initWithData:callData encoding:NSUTF8StringEncoding];
        [parts addObject:[NSString stringWithFormat:@"<tool_call>%@</tool_call>", callJSON]];
      }
    }
  }

  // Extract text content.
  id content = dict[@"content"];
  if ([content isKindOfClass:[NSString class]]) {
    NSString *text = (NSString *)content;
    if (text.length > 0) [parts addObject:text];
  } else if ([content isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray *)content) {
      if (![item isKindOfClass:[NSDictionary class]]) continue;
      NSString *type = item[@"type"];
      NSString *text = item[@"text"];
      if ([type isEqualToString:@"text"] && text.length > 0) {
        [parts addObject:text];
      }
    }
  }

  if (parts.count == 0) {
    // Nothing useful — return empty string instead of error so streaming continues.
    return @"";
  }

  return [parts componentsJoinedByString:@""];
}

- (void)assignDlError:(NSError **)error prefix:(NSString *)prefix {
  const char *dlMessage = dlerror();
  NSString *details = dlMessage == nullptr ? @"Unknown dynamic loader error." : [NSString stringWithUTF8String:dlMessage];
  [self assignError:error message:[NSString stringWithFormat:@"%@ %@", prefix, details]];
}

- (void)assignError:(NSError **)error message:(NSString *)message {
  if (error == nullptr) {
    return;
  }

  *error = [NSError errorWithDomain:GemmaLiteRTErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
