#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLDownloadManager : NSObject

@property (nonatomic, weak, nullable) id activePlayerViewController;
@property (nonatomic, strong, nullable) id activeVideo;
@property (nonatomic, strong, nullable) id lastActivePlayerResponse;
@property (nonatomic, strong, nullable) id lastActivePlaybackData;
@property (nonatomic, copy, nullable) NSString *lastActiveVideoID;
@property (nonatomic, strong, nullable) id lastStreamingData;

+ (instancetype)sharedManager;

- (void)didActivateVideo:(nullable id)video withPlaybackData:(nullable id)playbackData videoID:(nullable NSString *)videoID playerResponse:(nullable id)playerResponse;
- (void)didActivateVideoWithPlaybackData:(nullable id)playbackData videoID:(nullable NSString *)videoID playerResponse:(nullable id)playerResponse;
- (void)handleDownloadButtonTap:(UIGestureRecognizer *)gesture;
- (void)showDownloadMenuFromView:(nullable id)sourceView playerViewController:(nullable id)playerVC;
- (BOOL)handleOfflineEndpointCommand:(nullable id)command fromView:(nullable id)sourceView;
- (BOOL)handleOfflineEndpointCommand:(nullable id)command entry:(nullable id)entry fromView:(nullable id)sourceView;
- (void)handleDownloadForVideoId:(nullable NSString *)videoId playerResponse:(nullable id)playerResponse sourceView:(nullable id)sourceView;

@end

NS_ASSUME_NONNULL_END
