#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface YTLDownloadManager : NSObject

+ (instancetype)sharedManager;

- (void)handleDownloadButtonTap:(UIGestureRecognizer *)gesture;
- (void)showDownloadMenuFromView:(UIView *)sourceView playerViewController:(id)playerVC;

@end
