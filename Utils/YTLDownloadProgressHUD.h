#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLDownloadProgressHUD : NSObject

+ (instancetype)sharedHUD;

- (void)showWithTitle:(NSString *)title cancelHandler:(nullable void (^)(void))cancelHandler;
- (void)updateProgress:(float)progress statusText:(nullable NSString *)statusText;
- (void)dismissWithSuccess:(BOOL)success message:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
