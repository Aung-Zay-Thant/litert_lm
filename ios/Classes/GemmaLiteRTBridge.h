#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GemmaStreamChunkBlock)(NSString *_Nullable chunk, BOOL isFinal, NSString *_Nullable errorMessage);

@interface GemmaLiteRTBridge : NSObject

- (BOOL)prepareModelAtPath:(NSString *)modelPath
              systemPrompt:(nullable NSString *)systemPrompt
                 toolsJSON:(nullable NSString *)toolsJSON
                     error:(NSError **)error;
- (nullable NSString *)generateText:(NSString *)prompt
                               imagePath:(nullable NSString *)imagePath
                                  error:(NSError **)error;
- (BOOL)generateTextStream:(NSString *)prompt
                  imagePath:(nullable NSString *)imagePath
                    onChunk:(GemmaStreamChunkBlock)onChunk
                      error:(NSError **)error;
- (void)cancelGeneration;
- (void)resetConversation;
- (nullable NSString *)extractTextFromResponseJSONString:(NSString *)jsonString
                                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
