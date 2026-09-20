#import "YTLDownloadProgressHUD.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface YTLDownloadProgressHUD ()

@property (nonatomic, strong, nullable) UIView *containerView;
@property (nonatomic, strong, nullable) UIVisualEffectView *blurView;
@property (nonatomic, strong, nullable) UIActivityIndicatorView *spinner;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UILabel *statusLabel;
@property (nonatomic, strong, nullable) UIProgressView *progressBar;
@property (nonatomic, strong, nullable) UIButton *cancelButton;
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);
@property (nonatomic, assign) BOOL isVisible;

@end

@implementation YTLDownloadProgressHUD

+ (instancetype)sharedHUD {
    static YTLDownloadProgressHUD *hud = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hud = [[YTLDownloadProgressHUD alloc] init];
    });
    return hud;
}

- (UIWindow *)findActiveWindow {
    UIWindow *window = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (!window && scene.windows.count > 0) window = scene.windows.firstObject;
        }
        if (window) break;
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    return window;
}

- (void)showWithTitle:(NSString *)title cancelHandler:(nullable void (^)(void))cancelHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cancelHandler = cancelHandler;

        UIWindow *window = [self findActiveWindow];
        if (!window) return;

        if (self.containerView && self.containerView.superview) {
            [self.containerView removeFromSuperview];
        }

        CGFloat width = MIN(window.bounds.size.width - 40.0, 340.0);
        CGFloat height = 76.0;
        CGFloat topSafe = window.safeAreaInsets.top;
        if (topSafe <= 0) topSafe = 24.0;
        CGFloat y = topSafe + 10.0;
        CGFloat x = (window.bounds.size.width - width) / 2.0;

        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, height)];
        container.backgroundColor = [UIColor clearColor];
        container.layer.cornerRadius = 18.0;
        container.layer.masksToBounds = YES;
        container.layer.borderWidth = 0.5;
        container.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
        container.alpha = 0.0;
        container.transform = CGAffineTransformMakeScale(0.92, 0.92);

        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blur.frame = container.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:blur];

        // Spinner
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        sp.color = [UIColor whiteColor];
        sp.frame = CGRectMake(14.0, 16.0, 24.0, 24.0);
        [sp startAnimating];
        [container addSubview:sp];
        self.spinner = sp;

        // Title Label
        CGFloat labelRight = cancelHandler ? (width - 44.0) : (width - 16.0);
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(46.0, 10.0, labelRight - 46.0, 18.0)];
        tl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        tl.textColor = [UIColor whiteColor];
        tl.text = title ?: @"Đang tải...";
        [container addSubview:tl];
        self.titleLabel = tl;

        // Status Label (MB, tốc độ)
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(46.0, 29.0, labelRight - 46.0, 15.0)];
        sl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        sl.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
        sl.text = @"Chuẩn bị...";
        [container addSubview:sl];
        self.statusLabel = sl;

        // Progress Bar
        UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        pv.frame = CGRectMake(14.0, 52.0, width - 28.0, 4.0);
        pv.progressTintColor = [UIColor colorWithRed:1.0 green:0.22 blue:0.22 alpha:1.0]; // YouTube Red
        pv.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
        pv.progress = 0.0;
        pv.layer.cornerRadius = 2.0;
        pv.clipsToBounds = YES;
        [container addSubview:pv];
        self.progressBar = pv;

        // Cancel Button (nếu có)
        if (cancelHandler) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(width - 38.0, 14.0, 26.0, 26.0);
            [btn setTitle:@"✕" forState:UIControlStateNormal];
            [btn setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.8] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
            btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
            btn.layer.cornerRadius = 13.0;
            [btn addTarget:self action:@selector(handleCancelButton) forControlEvents:UIControlEventTouchUpInside];
            [container addSubview:btn];
            self.cancelButton = btn;
        }

        [window addSubview:container];
        self.containerView = container;
        self.blurView = blur;
        self.isVisible = YES;

        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            container.alpha = 1.0;
            container.transform = CGAffineTransformIdentity;
        } completion:nil];
    });
}

- (void)handleCancelButton {
    if (self.cancelHandler) {
        self.cancelHandler();
    }
    [self dismissWithSuccess:NO message:@"Đã hủy tải"];
}

- (void)updateProgress:(float)progress statusText:(nullable NSString *)statusText {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isVisible || !self.containerView) return;

        float safeProgress = MAX(0.0, MIN(1.0, progress));
        [self.progressBar setProgress:safeProgress animated:YES];

        if (statusText && statusText.length > 0) {
            self.statusLabel.text = statusText;
        } else {
            self.statusLabel.text = [NSString stringWithFormat:@"Đã tải %.0f%%", safeProgress * 100.0];
        }
    });
}

- (void)dismissWithSuccess:(BOOL)success message:(nullable NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isVisible || !self.containerView) return;

        [self.spinner stopAnimating];
        self.spinner.hidden = YES;

        if (success) {
            [self.progressBar setProgress:1.0 animated:NO];
            self.titleLabel.text = message ?: @"Tải video hoàn tất! 🎉";
            self.statusLabel.text = @"Đã lưu thành công";
            self.progressBar.progressTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0];
        } else {
            self.titleLabel.text = message ?: @"Tải video thất bại!";
            self.statusLabel.text = @"Vui lòng thử lại";
            self.progressBar.progressTintColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0];
        }

        if (self.cancelButton) {
            [self.cancelButton removeFromSuperview];
            self.cancelButton = nil;
        }

        self.isVisible = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self.containerView.alpha = 0.0;
                self.containerView.transform = CGAffineTransformMakeTranslation(0, -20.0);
            } completion:^(BOOL finished) {
                [self.containerView removeFromSuperview];
                self.containerView = nil;
                self.cancelHandler = nil;
            }];
        });
    });
}

@end
