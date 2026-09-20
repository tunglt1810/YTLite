#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLM3U8Variant : NSObject

@property (nonatomic, copy) NSString *quality;
@property (nonatomic, copy) NSString *resolution;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger bandwidth;
@property (nonatomic, copy) NSString *codecs;
@property (nonatomic, copy) NSString *streamURL;
@property (nonatomic, copy, nullable) NSString *audioURL;
@property (nonatomic, assign) NSInteger variantIndex;

@end

@interface YTLM3U8Parser : NSObject

+ (void)parseMasterPlaylistURL:(NSString *)manifestURL completion:(void (^)(NSArray <YTLM3U8Variant *> * _Nullable variants, NSError * _Nullable error))completion;

+ (NSArray <YTLM3U8Variant *> *)parseM3U8Content:(NSString *)content baseURL:(NSString *)baseURL;

@end

NS_ASSUME_NONNULL_END
