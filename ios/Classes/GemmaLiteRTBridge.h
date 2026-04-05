#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GemmaStreamEventBlock)(NSDictionary *event);

@interface GemmaLiteRTBridge : NSObject

- (BOOL)prepareModelAtPath:(NSString *)modelPath
              engineConfig:(nullable NSDictionary *)engineConfig
                     error:(NSError **)error;
- (nullable NSString *)createConversationWithConfig:(nullable NSDictionary *)conversationConfig
                                      sessionConfig:(nullable NSDictionary *)sessionConfig
                                              error:(NSError **)error;
- (BOOL)generateTextStreamForConversationId:(NSString *)conversationId
                                   promptParts:(NSArray<NSDictionary *> *)promptParts
                                    requestId:(NSString *)requestId
                                      onEvent:(GemmaStreamEventBlock)onEvent
                                        error:(NSError **)error;
- (void)cancelGenerationForConversationId:(NSString *)conversationId;
- (BOOL)resetConversationWithId:(NSString *)conversationId error:(NSError **)error;
- (void)disposeConversationWithId:(NSString *)conversationId;
- (nullable NSDictionary *)getBenchmarkInfoForConversationId:(NSString *)conversationId;

@end

NS_ASSUME_NONNULL_END
