#import "YTLDownloadManager.h"
#import "YTLM3U8Parser.h"
#import "YTLDownloadProgressHUD.h"
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <ffmpegkit/FFmpegKit.h>
#import <ffmpegkit/ReturnCode.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define LOC(x) [NSBundle.mainBundle localizedStringForKey:(x) value:@"" table:nil]

@implementation YTLDownloadManager

+ (instancetype)sharedManager {
    static YTLDownloadManager *mgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mgr = [[YTLDownloadManager alloc] init];
    });
    return mgr;
}

#pragma mark - Safe Reflection Helpers (Crash Prevention)

static id _Nullable safePerform(id _Nullable target, SEL _Nullable sel) {
    if (!target || !sel) return nil;
    if (![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    if (sig.numberOfArguments > 2) return nil;
    const char *retType = sig.methodReturnType;
    // BẮT BUỘC chỉ gọi khi return type là ObjC object '@' để tránh EXC_BAD_ACCESS trên ARM64
    if (!retType || retType[0] != '@') return nil;

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:sel];
    #pragma clang diagnostic pop
}

static id _Nullable safeValueForKey(id _Nullable target, NSString * _Nullable key) {
    if (!target || !key || key.length == 0) return nil;
    @try {
        return [target valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - UI Helpers

static void showToast(NSString *message) {
    if (!message || message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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
        if (!window) return;

        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.layer.cornerRadius = 18;
        toast.layer.masksToBounds = YES;
        toast.numberOfLines = 0;
        toast.alpha = 0.0;

        CGSize maxSz = CGSizeMake(window.bounds.size.width - 64, 200);
        CGSize sz = [toast sizeThatFits:maxSz];
        CGFloat padH = 24.0;
        CGFloat padV = 16.0;
        CGFloat w = MAX(sz.width + padH, 120.0);
        CGFloat h = MAX(sz.height + padV, 36.0);
        CGFloat y = window.bounds.size.height - 130;
        toast.frame = CGRectMake((window.bounds.size.width - w) / 2.0, y, w, h);

        [window addSubview:toast];
        [UIView animateWithDuration:0.25 animations:^{
            toast.alpha = 1.0;
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{
                    toast.alpha = 0.0;
                } completion:^(BOOL fin) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

static UIViewController * _Nullable getTopViewController(UIViewController * _Nullable root) {
    if (!root) {
        UIWindow *win = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (!win && scene.windows.count > 0) win = scene.windows.firstObject;
            }
            if (win) break;
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        root = win.rootViewController;
    }
    if (!root) return nil;

    if ([root isKindOfClass:[UINavigationController class]]) {
        return getTopViewController([(UINavigationController *)root visibleViewController]);
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return getTopViewController([(UITabBarController *)root selectedViewController]);
    }
    if (root.presentedViewController) {
        NSString *presentedClass = NSStringFromClass([root.presentedViewController class]);
        if ([presentedClass containsString:@"Sheet"] ||
            [presentedClass containsString:@"Alert"] ||
            [presentedClass containsString:@"Dialog"] ||
            [presentedClass containsString:@"Popup"]) {
            return root;
        }
        if (!root.presentedViewController.isBeingDismissed) {
            return getTopViewController(root.presentedViewController);
        }
    }
    return root;
}

static void presentActionSheetSafely(UIViewController * _Nullable topVC, UIViewController *toPresent, id _Nullable sourceView) {
    if (!toPresent) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Class ytUIUtils = NSClassFromString(@"YTUIUtils");
            UIViewController *presenter = topVC;
            if (!presenter && ytUIUtils && [ytUIUtils respondsToSelector:@selector(topViewControllerForPresenting)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                presenter = [ytUIUtils performSelector:@selector(topViewControllerForPresenting)];
                #pragma clang diagnostic pop
            }
            if (!presenter) {
                presenter = [YTLDownloadManager sharedManager].activePlayerViewController;
            }
            if (!presenter) {
                presenter = getTopViewController(nil);
            }
            if (!presenter) return;

            // Nếu presenter đang có modal hiển thị hoặc chính presenter đang trong quá trình chuyển cảnh:
            // TUYỆT ĐỐI KHÔNG GỌI dismissViewControllerAnimated: cưỡng bức lên modal đang đóng/mở!
            // Chỉ cần hoãn 0.25s để UIKit hoàn tất chu kỳ animation tự nhiên của controller cũ.
            if (presenter.presentedViewController != nil || presenter.isBeingDismissed || presenter.isBeingPresented) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    presentActionSheetSafely(nil, toPresent, sourceView);
                });
                return;
            }

            // Đảm bảo presenter view đã gắn vào window
            if (!presenter.view.window) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    presentActionSheetSafely(nil, toPresent, sourceView);
                });
                return;
            }

            if (toPresent.popoverPresentationController) {
                UIView *targetView = nil;
                if ([sourceView isKindOfClass:[UIView class]]) {
                    UIView *candidate = (UIView *)sourceView;
                    if (candidate.window != nil && candidate.bounds.size.width > 1.0 && candidate.bounds.size.height > 1.0) {
                        targetView = candidate;
                    }
                }
                if (!targetView) {
                    targetView = presenter.view;
                }
                toPresent.popoverPresentationController.sourceView = targetView;
                CGRect rect = targetView.bounds;
                if (CGRectIsEmpty(rect) || rect.size.width <= 0 || rect.size.height <= 0) {
                    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
                    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
                    rect = CGRectMake(MAX(1.0, screenW / 2.0), MAX(1.0, screenH / 2.0), 1.0, 1.0);
                } else {
                    rect = CGRectMake(CGRectGetMidX(rect), CGRectGetMidY(rect), 1.0, 1.0);
                }
                toPresent.popoverPresentationController.sourceRect = rect;
            }

            [presenter presentViewController:toPresent animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[YTLite] Exception in presentActionSheetSafely: %@", e);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                presentActionSheetSafely(nil, toPresent, sourceView);
            });
        }
    });
}

static id _Nullable findPlaybackContextFromView(id _Nullable view, id _Nullable * _Nullable outVideo, id _Nullable * _Nullable outPlayerResponse) {
    if (outVideo) *outVideo = nil;
    if (outPlayerResponse) *outPlayerResponse = nil;

    id foundVC = nil;
    if (view) {
        // Bóc tách actual UIView nếu đối tượng đầu vào là Texture ASDisplayNode hoặc ELMNodeController
        UIView *actualView = nil;
        if ([view isKindOfClass:[UIView class]]) {
            actualView = (UIView *)view;
        } else if ([view respondsToSelector:@selector(view)]) {
            id innerView = safePerform(view, @selector(view));
            if ([innerView isKindOfClass:[UIView class]]) {
                actualView = (UIView *)innerView;
            }
        } else if ([view respondsToSelector:@selector(node)]) {
            id node = safePerform(view, @selector(node));
            if ([node respondsToSelector:@selector(view)]) {
                id innerView = safePerform(node, @selector(view));
                if ([innerView isKindOfClass:[UIView class]]) {
                    actualView = (UIView *)innerView;
                }
            }
        }

        UIResponder *resp = [actualView isKindOfClass:[UIResponder class]] ? (UIResponder *)actualView : nil;
        // BẮT BUỘC kiểm tra isKindOfClass:[UIResponder class] trước khi gọi nextResponder để tránh crash ASDisplayNode
        while (resp && [resp isKindOfClass:[UIResponder class]]) {
            NSString *className = NSStringFromClass([resp class]);
            if (!foundVC && ([className containsString:@"PlayerViewController"] ||
                             [className containsString:@"WatchViewController"] ||
                             [className containsString:@"ShortsViewController"] ||
                             [className containsString:@"InlinePlayerViewController"])) {
                foundVC = resp;
            }

            // Trích xuất video object từ responder (LOẠI BỎ selector @"video" vì có thể trả về scalar/struct gây crash EXC_BAD_ACCESS)
            if (outVideo && !*outVideo) {
                NSArray *videoKeys = @[@"activeVideo", @"currentVideo", @"singleVideo"];
                for (NSString *key in videoKeys) {
                    id v = safePerform(resp, NSSelectorFromString(key)) ?: safeValueForKey(resp, key);
                    if (v) { *outVideo = v; break; }
                }
            }

            // Trích xuất playerResponse object từ responder
            if (outPlayerResponse && !*outPlayerResponse) {
                NSArray *prKeys = @[@"playerResponse", @"contentPlayerResponse", @"currentVideoPlayerResponse", @"activePlayerResponse", @"playerData"];
                for (NSString *key in prKeys) {
                    id pr = safePerform(resp, NSSelectorFromString(key)) ?: safeValueForKey(resp, key);
                    if (pr) { *outPlayerResponse = pr; break; }
                }
            }

            // Kiểm tra sub-controllers
            NSArray *controllerKeys = @[@"playbackController", @"inlinePlaybackController", @"singleVideoController", @"playerViewController"];
            for (NSString *cKey in controllerKeys) {
                id subCtrl = safePerform(resp, NSSelectorFromString(cKey)) ?: safeValueForKey(resp, cKey);
                if (subCtrl) {
                    if (!foundVC) foundVC = subCtrl;
                    if (outVideo && !*outVideo) {
                        *outVideo = safeValueForKey(subCtrl, @"activeVideo") ?: safeValueForKey(subCtrl, @"currentVideo");
                    }
                    if (outPlayerResponse && !*outPlayerResponse) {
                        *outPlayerResponse = safeValueForKey(subCtrl, @"playerResponse") ?: safeValueForKey(subCtrl, @"contentPlayerResponse");
                    }
                }
            }

            if ((outVideo && *outVideo) || (outPlayerResponse && *outPlayerResponse)) {
                break;
            }

            resp = [resp nextResponder];
        }
    }

    if (!foundVC) {
        UIViewController *topVC = getTopViewController(nil);
        if (topVC) {
            NSString *topName = NSStringFromClass([topVC class]);
            if ([topName containsString:@"PlayerViewController"] || [topName containsString:@"WatchViewController"]) {
                foundVC = topVC;
            } else {
                for (UIViewController *child in topVC.childViewControllers) {
                    NSString *childName = NSStringFromClass([child class]);
                    if ([childName containsString:@"PlayerViewController"] || [childName containsString:@"WatchViewController"]) {
                        foundVC = child;
                        break;
                    }
                }
            }
        }
    }

    return foundVC;
}

static id _Nullable findPlayerViewController(UIView * _Nullable view) {
    id dummyVideo = nil;
    id dummyPR = nil;
    return findPlaybackContextFromView(view, &dummyVideo, &dummyPR);
}

static NSString *sanitizeFileName(NSString *name) {
    if (!name || name.length == 0) return @"YouTube_Video";
    NSCharacterSet *illegalChars = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\":<>"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:illegalChars] componentsJoinedByString:@"_"];
    if (clean.length > 80) clean = [clean substringToIndex:80];
    return clean;
}

#pragma mark - Context Metadata Extraction

static NSString * _Nullable extractVideoIdFromSingleTargetWithDepth(id target, int depth) {
    if (!target || depth > 2) return nil;

    NSArray *selNames = @[
        @"videoId", @"videoID", @"videoIdString",
        @"offlineVideoId", @"offlineVideoID",
        @"contentId", @"targetId"
    ];

    for (NSString *selName in selNames) {
        id val = safePerform(target, NSSelectorFromString(selName)) ?: safeValueForKey(target, selName);
        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return val;
    }

    // Tra cứu sâu trong message descriptors với depth limit
    NSArray *subSelectors = @[@"offlineVideoEndpoint", @"watchEndpoint", @"offlineEndpoint", @"endpoint"];
    for (NSString *subSel in subSelectors) {
        id sub = safePerform(target, NSSelectorFromString(subSel)) ?: safeValueForKey(target, subSel);
        if (sub && sub != target) {
            NSString *v = extractVideoIdFromSingleTargetWithDepth(sub, depth + 1);
            if (v && v.length > 0) return v;
        }
    }

    NSString *desc = [target description];
    if (desc && desc.length > 0) {
        static NSRegularExpression *re = nil;
        static NSRegularExpression *urlRe = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            re = [NSRegularExpression regularExpressionWithPattern:@"(?:video_id|videoId|videoID)[\":=\\s]+([a-zA-Z0-9_-]{11})" options:NSRegularExpressionCaseInsensitive error:nil];
            urlRe = [NSRegularExpression regularExpressionWithPattern:@"(?:youtu\\.be/|v=|/v/|/embed/)([a-zA-Z0-9_-]{11})" options:NSRegularExpressionCaseInsensitive error:nil];
        });
        NSTextCheckingResult *m = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
        if (m && m.numberOfRanges > 1) {
            return [desc substringWithRange:[m rangeAtIndex:1]];
        }
        NSTextCheckingResult *mUrl = [urlRe firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
        if (mUrl && mUrl.numberOfRanges > 1) {
            return [desc substringWithRange:[mUrl rangeAtIndex:1]];
        }
    }

    return nil;
}

static NSString * _Nullable extractVideoIdFromSingleTarget(id target) {
    return extractVideoIdFromSingleTargetWithDepth(target, 0);
}

static NSString * _Nullable extractVideoIdFromCommand(id command, id entry) {
    NSString *vid = extractVideoIdFromSingleTarget(command);
    if (vid && vid.length > 0) return vid;
    vid = extractVideoIdFromSingleTarget(entry);
    if (vid && vid.length > 0) return vid;
    return nil;
}

static NSString * _Nullable extractVideoIdFromPlayerVC(id playerVC) {
    if (!playerVC) return nil;

    NSArray *selNames = @[
        @"currentVideoID", @"videoID", @"videoId",
        @"currentVideoId", @"activeVideoID", @"activeVideoId"
    ];
    for (NSString *selName in selNames) {
        id val = safePerform(playerVC, NSSelectorFromString(selName)) ?: safeValueForKey(playerVC, selName);
        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return val;
    }

    id activeVideo = safeValueForKey(playerVC, @"activeVideo") ?: safePerform(playerVC, @selector(activeVideo));
    if (activeVideo) {
        for (NSString *s in selNames) {
            id v = safePerform(activeVideo, NSSelectorFromString(s)) ?: safeValueForKey(activeVideo, s);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }

    return nil;
}

static id _Nullable extractPlayerResponseFromPlayerVC(id playerVC) {
    if (!playerVC) return nil;

    NSArray *selNames = @[
        @"playerResponse", @"contentPlayerResponse",
        @"currentVideoPlayerResponse", @"activePlayerResponse"
    ];
    for (NSString *selName in selNames) {
        id val = safePerform(playerVC, NSSelectorFromString(selName)) ?: safeValueForKey(playerVC, selName);
        if (val) return val;
    }

    id activeVideo = safeValueForKey(playerVC, @"activeVideo") ?: safePerform(playerVC, @selector(activeVideo));
    if (activeVideo) {
        for (NSString *s in selNames) {
            id v = safePerform(activeVideo, NSSelectorFromString(s)) ?: safeValueForKey(activeVideo, s);
            if (v) return v;
        }
    }

    return nil;
}

#pragma mark - Format Extraction

static NSString * _Nullable parseURLFromCipherString(NSString *cipher) {
    if (!cipher || cipher.length == 0) return nil;

    NSArray *pairs = [cipher componentsSeparatedByString:@"&"];
    NSString *rawUrl = nil;
    NSString *sig = nil;
    NSString *sp = @"sig";

    for (NSString *pair in pairs) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count >= 2) {
            NSString *key = kv[0];
            NSString *val = [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="];
            if ([key isEqualToString:@"url"]) {
                rawUrl = [val stringByRemovingPercentEncoding];
            } else if ([key isEqualToString:@"s"]) {
                sig = [val stringByRemovingPercentEncoding];
            } else if ([key isEqualToString:@"sp"]) {
                NSString *spVal = [val stringByRemovingPercentEncoding];
                if (spVal && spVal.length > 0) sp = spVal;
            }
        }
    }

    if (rawUrl && rawUrl.length > 0) {
        if (sig && sig.length > 0) {
            NSString *sep = [rawUrl containsString:@"?"] ? @"&" : @"?";
            NSString *encodedSig = [sig stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            return [NSString stringWithFormat:@"%@%@%@=%@", rawUrl, sep, sp, encodedSig];
        }
        return rawUrl;
    }
    return nil;
}

static id _Nullable unwrapFormatStream(id obj) {
    if (!obj) return nil;
    if ([obj respondsToSelector:@selector(formatStream)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id inner = [obj performSelector:@selector(formatStream)];
        #pragma clang diagnostic pop
        if (inner) return inner;
    }
    @try {
        id inner = [obj valueForKey:@"formatStream"];
        if (inner) return inner;
    } @catch (NSException *e) {}
    return obj;
}

static NSString * _Nullable sanitizeAndValidateURL(id _Nullable rawURLObj) {
    if (!rawURLObj) return nil;

    NSString *urlString = nil;
    if ([rawURLObj isKindOfClass:[NSURL class]]) {
        urlString = [(NSURL *)rawURLObj absoluteString];
    } else if ([rawURLObj isKindOfClass:[NSString class]]) {
        urlString = (NSString *)rawURLObj;
    } else {
        return nil;
    }

    if (!urlString || urlString.length == 0) return nil;

    NSString *trimmed = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    // 1. Sửa protocol-relative URL: //rr---sn-... -> https://rr---sn-...
    if ([trimmed hasPrefix:@"//"]) {
        trimmed = [@"https:" stringByAppendingString:trimmed];
    }
    // 2. Sửa relative host path: /videoplayback?... -> https://www.youtube.com/videoplayback?...
    else if ([trimmed hasPrefix:@"/videoplayback"]) {
        trimmed = [@"https://www.youtube.com" stringByAppendingString:trimmed];
    }
    else if ([trimmed hasPrefix:@"videoplayback"]) {
        trimmed = [@"https://www.youtube.com/" stringByAppendingString:trimmed];
    }
    // 3. Nếu bị bọc bởi custom scheme (như blob:https://... hoặc youtube-stream:https://...)
    else if (![trimmed hasPrefix:@"http://"] && ![trimmed hasPrefix:@"https://"]) {
        NSRange httpsRange = [trimmed rangeOfString:@"https://" options:NSCaseInsensitiveSearch];
        if (httpsRange.location != NSNotFound) {
            trimmed = [trimmed substringFromIndex:httpsRange.location];
        } else {
            NSRange httpRange = [trimmed rangeOfString:@"http://" options:NSCaseInsensitiveSearch];
            if (httpRange.location != NSNotFound) {
                trimmed = [trimmed substringFromIndex:httpRange.location];
            } else {
                return nil;
            }
        }
    }

    // 4. Kiểm tra scheme bắt buộc phải là http hoặc https
    if (![trimmed hasPrefix:@"http://"] && ![trimmed hasPrefix:@"https://"]) {
        return nil;
    }

    // 5. Kiểm tra tính hợp lệ qua NSURL
    NSURL *testURL = [NSURL URLWithString:trimmed];
    if (testURL && testURL.scheme && testURL.host && ([testURL.scheme.lowercaseString isEqualToString:@"https"] || [testURL.scheme.lowercaseString isEqualToString:@"http"])) {
        return trimmed;
    }

    // 6. Cố gắng percent encode query parameters nếu URL chứa ký tự lạ
    NSString *encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (encoded) {
        testURL = [NSURL URLWithString:encoded];
        if (testURL && testURL.scheme && testURL.host && ([testURL.scheme.lowercaseString isEqualToString:@"https"] || [testURL.scheme.lowercaseString isEqualToString:@"http"])) {
            return encoded;
        }
    }

    // 7. Dự phòng: Nếu URL có prefix http(s):// và có host hợp lệ (chứa dấu chấm)
    if (trimmed.length > 10 && ([trimmed hasPrefix:@"https://"] || [trimmed hasPrefix:@"http://"])) {
        NSString *withoutScheme = [trimmed substringFromIndex:[trimmed hasPrefix:@"https://"] ? 8 : 7];
        NSRange slashRange = [withoutScheme rangeOfString:@"/"];
        NSString *host = slashRange.location != NSNotFound ? [withoutScheme substringToIndex:slashRange.location] : withoutScheme;
        if ([host containsString:@"."]) {
            return trimmed;
        }
    }

    return nil;
}

static NSString * _Nullable extractStreamURL(id formatStream) {
    if (!formatStream) return nil;

    NSArray *urlSelectors = @[
        @"streamURL", @"streamUrl",
        @"URL", @"url",
        @"playbackURL", @"playbackUrl",
        @"assetDownloadURL", @"assetDownloadUrl",
        @"streamUrlString",
        @"baseURL", @"baseUrl",
        @"rawURL", @"rawUrl",
        @"directURL", @"directUrl",
        @"downloadURL", @"downloadUrl",
        @"HLSMasterPlaylistURL"
    ];

    // 1. Tra cứu TRỰC TIẾP trên đối tượng (MLFormat hoặc bất kỳ wrapper nào) trước tiên
    for (NSString *selName in urlSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([formatStream respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id u = [formatStream performSelector:sel];
            #pragma clang diagnostic pop
            NSString *valid = sanitizeAndValidateURL(u);
            if (valid) return valid;
        }
        @try {
            id u = [formatStream valueForKey:selName];
            NSString *valid = sanitizeAndValidateURL(u);
            if (valid) return valid;
        } @catch (NSException *e) {}
    }

    // 2. Mở lớp bọc formatStream (YTIFormatStream nằm trong MLFormat)
    id unwrapped = unwrapFormatStream(formatStream);
    if (unwrapped && unwrapped != formatStream) {
        for (NSString *selName in urlSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([unwrapped respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id u = [unwrapped performSelector:sel];
                #pragma clang diagnostic pop
                NSString *valid = sanitizeAndValidateURL(u);
                if (valid) return valid;
            }
            @try {
                id u = [unwrapped valueForKey:selName];
                NSString *valid = sanitizeAndValidateURL(u);
                if (valid) return valid;
            } @catch (NSException *e) {}
        }
    }

    // 3. Nếu là Dictionary (từ JSON InnerTube API)
    id dictObj = [formatStream isKindOfClass:[NSDictionary class]] ? formatStream : ([unwrapped isKindOfClass:[NSDictionary class]] ? unwrapped : nil);
    if (dictObj) {
        NSDictionary *dict = (NSDictionary *)dictObj;
        for (NSString *k in urlSelectors) {
            id u = dict[k];
            NSString *valid = sanitizeAndValidateURL(u);
            if (valid) return valid;
        }
        NSString *cipher = dict[@"signatureCipher"] ?: dict[@"cipher"];
        if ([cipher isKindOfClass:[NSString class]] && cipher.length > 0) {
            NSString *extracted = parseURLFromCipherString(cipher);
            NSString *valid = sanitizeAndValidateURL(extracted);
            if (valid) return valid;
        }
    }

    // 4. Tra cứu cipher trên formatStream và unwrapped
    NSArray *cipherSelectors = @[@"signatureCipher", @"cipher"];
    NSArray *candidates = (unwrapped && unwrapped != formatStream) ? @[formatStream, unwrapped] : @[formatStream];
    for (id obj in candidates) {
        for (NSString *selName in cipherSelectors) {
            SEL sel = NSSelectorFromString(selName);
            id c = nil;
            if ([obj respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                c = [obj performSelector:sel];
                #pragma clang diagnostic pop
            }
            if (!c) {
                @try { c = [obj valueForKey:selName]; } @catch (NSException *e) {}
            }
            if ([c isKindOfClass:[NSString class]] && [(NSString *)c length] > 0) {
                NSString *extracted = parseURLFromCipherString(c);
                NSString *valid = sanitizeAndValidateURL(extracted);
                if (valid) return valid;
            }
        }
    }

    return nil;
}

static int extractItag(id formatStream) {
    formatStream = unwrapFormatStream(formatStream);
    if (!formatStream) return 0;
    if ([formatStream isKindOfClass:[NSDictionary class]]) {
        id it = formatStream[@"itag"];
        if (it) return [it intValue];
    }
    if ([formatStream respondsToSelector:@selector(itag)]) {
        NSMethodSignature *sig = [formatStream methodSignatureForSelector:@selector(itag)];
        if (sig) {
            const char *type = sig.methodReturnType;
            if (strcmp(type, "i") == 0 || strcmp(type, "I") == 0 || strcmp(type, "s") == 0 || strcmp(type, "S") == 0) {
                int val = 0;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(itag)];
                [inv setTarget:formatStream];
                [inv invoke];
                [inv getReturnValue:&val];
                if (val > 0) return val;
            } else if (strcmp(type, "q") == 0 || strcmp(type, "Q") == 0 || strcmp(type, "l") == 0 || strcmp(type, "L") == 0) {
                long long val = 0;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(itag)];
                [inv setTarget:formatStream];
                [inv invoke];
                [inv getReturnValue:&val];
                if (val > 0) return (int)val;
            }
        }
    }
    @try {
        id val = [formatStream valueForKey:@"itag"];
        if (val && [val respondsToSelector:@selector(intValue)]) return [val intValue];
    } @catch (NSException *e) {}

    NSString *url = extractStreamURL(formatStream);
    if (url) {
        NSRange r = [url rangeOfString:@"[?&]itag=(\\d+)" options:NSRegularExpressionSearch];
        if (r.location != NSNotFound) {
            NSString *sub = [url substringWithRange:r];
            NSRange eq = [sub rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                return [[sub substringFromIndex:eq.location + 1] intValue];
            }
        }
    }
    return 0;
}

static int extractHeight(id formatStream) {
    formatStream = unwrapFormatStream(formatStream);
    if (!formatStream) return 0;
    if ([formatStream isKindOfClass:[NSDictionary class]]) {
        id h = formatStream[@"height"];
        if (h) return [h intValue];
    }

    NSArray *heightSelectors = @[@"height", @"singleDimension"];
    for (NSString *selName in heightSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([formatStream respondsToSelector:sel]) {
            NSMethodSignature *sig = [formatStream methodSignatureForSelector:sel];
            if (sig) {
                const char *type = sig.methodReturnType;
                if (strcmp(type, "i") == 0 || strcmp(type, "I") == 0 || strcmp(type, "s") == 0 || strcmp(type, "S") == 0) {
                    int val = 0;
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:sel];
                    [inv setTarget:formatStream];
                    [inv invoke];
                    [inv getReturnValue:&val];
                    if (val > 0) return val;
                } else if (strcmp(type, "q") == 0 || strcmp(type, "Q") == 0 || strcmp(type, "l") == 0 || strcmp(type, "L") == 0) {
                    long long val = 0;
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:sel];
                    [inv setTarget:formatStream];
                    [inv invoke];
                    [inv getReturnValue:&val];
                    if (val > 0) return (int)val;
                }
            }
        }
        @try {
            id val = [formatStream valueForKey:selName];
            if (val && [val respondsToSelector:@selector(intValue)]) {
                int v = [val intValue];
                if (v > 0) return v;
            }
        } @catch (NSException *e) {}
    }

    // Kiểm tra resolution / pixelDimensions (CGSize)
    NSArray *sizeSelectors = @[@"resolution", @"pixelDimensions"];
    for (NSString *selName in sizeSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([formatStream respondsToSelector:sel]) {
            NSMethodSignature *sig = [formatStream methodSignatureForSelector:sel];
            if (sig && strncmp(sig.methodReturnType, "{CGSize", 7) == 0) {
                CGSize sz = CGSizeZero;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:sel];
                [inv setTarget:formatStream];
                [inv invoke];
                [inv getReturnValue:&sz];
                if (sz.height > 0) return (int)sz.height;
            }
        }
        @try {
            NSValue *val = [formatStream valueForKey:selName];
            if ([val isKindOfClass:[NSValue class]]) {
                CGSize sz = [val CGSizeValue];
                if (sz.height > 0) return (int)sz.height;
            }
        } @catch (NSException *e) {}
    }

    // Fallback ánh xạ itag chuẩn YouTube
    int it = extractItag(formatStream);
    if (it == 137 || it == 299 || it == 399 || it == 699) return 1080;
    if (it == 136 || it == 298 || it == 398 || it == 698 || it == 22) return 720;
    if (it == 135 || it == 397 || it == 697) return 480;
    if (it == 134 || it == 18 || it == 396 || it == 696) return 360;
    if (it == 133 || it == 395) return 240;
    if (it == 160 || it == 278) return 144;

    return 0;
}

static NSString *extractQualityLabel(id formatStream) {
    formatStream = unwrapFormatStream(formatStream);
    if (!formatStream) return @"";
    if ([formatStream isKindOfClass:[NSDictionary class]]) {
        id q = formatStream[@"qualityLabel"];
        if ([q isKindOfClass:[NSString class]] && [(NSString *)q length] > 0) return q;
        id quality = formatStream[@"quality"];
        if ([quality isKindOfClass:[NSString class]]) {
            NSString *qs = (NSString *)quality;
            if ([qs containsString:@"1080"]) return @"1080p";
            if ([qs containsString:@"720"]) return @"720p";
            if ([qs isEqualToString:@"large"]) return @"480p";
            if ([qs isEqualToString:@"medium"]) return @"360p";
            if ([qs isEqualToString:@"small"]) return @"240p";
            if ([qs isEqualToString:@"tiny"]) return @"144p";
        }
    }
    if ([formatStream respondsToSelector:@selector(qualityLabel)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id q = [formatStream performSelector:@selector(qualityLabel)];
        #pragma clang diagnostic pop
        if ([q isKindOfClass:[NSString class]] && [(NSString *)q length] > 0) return q;
    }
    @try {
        id q = [formatStream valueForKey:@"qualityLabel"];
        if ([q isKindOfClass:[NSString class]] && [(NSString *)q length] > 0) return q;
    } @catch (NSException *e) {}

    // Thử selector quality (hd1080, hd720, large, medium, small)
    if ([formatStream respondsToSelector:@selector(quality)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id q = [formatStream performSelector:@selector(quality)];
        #pragma clang diagnostic pop
        if ([q isKindOfClass:[NSString class]]) {
            NSString *qs = (NSString *)q;
            if ([qs containsString:@"1080"]) return @"1080p";
            if ([qs containsString:@"720"]) return @"720p";
            if ([qs isEqualToString:@"large"]) return @"480p";
            if ([qs isEqualToString:@"medium"]) return @"360p";
            if ([qs isEqualToString:@"small"]) return @"240p";
            if ([qs isEqualToString:@"tiny"]) return @"144p";
        }
    }

    int h = extractHeight(formatStream);
    if (h > 0) return [NSString stringWithFormat:@"%dp", h];

    // Fallback ánh xạ itag chuẩn
    int it = extractItag(formatStream);
    if (it == 137 || it == 299 || it == 399 || it == 699) return @"1080p";
    if (it == 136 || it == 298 || it == 398 || it == 698 || it == 22) return @"720p";
    if (it == 135 || it == 397 || it == 697) return @"480p";
    if (it == 134 || it == 18 || it == 396 || it == 696) return @"360p";
    if (it == 133 || it == 395) return @"240p";
    if (it == 160 || it == 278) return @"144p";

    return @"";
}

static NSString *extractMimeType(id formatStream) {
    formatStream = unwrapFormatStream(formatStream);
    if (!formatStream) return @"";
    if ([formatStream isKindOfClass:[NSDictionary class]]) {
        id m = formatStream[@"mimeType"];
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return m;
    }
    if ([formatStream respondsToSelector:@selector(mimeType)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id m = [formatStream performSelector:@selector(mimeType)];
        #pragma clang diagnostic pop
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return m;
    }
    @try {
        id m = [formatStream valueForKey:@"mimeType"];
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return m;
    } @catch (NSException *e) {}

    // Fallback ánh xạ mimeType theo itag chuẩn
    int it = extractItag(formatStream);
    if (it == 140 || it == 141 || it == 256 || it == 258) return @"audio/mp4; codecs=\"mp4a.40.2\"";
    if (it == 18 || it == 22) return @"video/mp4";
    if (it == 137 || it == 136 || it == 135 || it == 134 || it == 133 || it == 160 || it == 298 || it == 299) {
        return @"video/mp4; codecs=\"avc1\"";
    }
    if (it == 249 || it == 250 || it == 251) return @"audio/webm; codecs=\"opus\"";
    if (it >= 242 && it <= 248) return @"video/webm; codecs=\"vp9\"";

    return @"";
}

#pragma mark - Playback State Tracking

- (void)didActivateVideo:(nullable id)video withPlaybackData:(nullable id)playbackData videoID:(nullable NSString *)videoID playerResponse:(nullable id)playerResponse {
    if (video) self.activeVideo = video;
    [self didActivateVideoWithPlaybackData:playbackData videoID:videoID playerResponse:playerResponse];
}

- (void)didActivateVideoWithPlaybackData:(nullable id)playbackData videoID:(nullable NSString *)videoID playerResponse:(nullable id)playerResponse {
    if (playbackData) self.lastActivePlaybackData = playbackData;
    if (videoID && videoID.length > 0) self.lastActiveVideoID = videoID;

    if (playerResponse) {
        self.lastActivePlayerResponse = playerResponse;
    } else if (playbackData) {
        id pr = nil;
        if ([playbackData respondsToSelector:@selector(contentPlayerResponse)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            pr = [playbackData performSelector:@selector(contentPlayerResponse)];
            #pragma clang diagnostic pop
        }
        if (!pr && [playbackData respondsToSelector:@selector(playerResponse)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            pr = [playbackData performSelector:@selector(playerResponse)];
            #pragma clang diagnostic pop
        }
        if (!pr) {
            @try { pr = [playbackData valueForKey:@"contentPlayerResponse"]; } @catch (NSException *e) {}
        }
        if (!pr) {
            @try { pr = [playbackData valueForKey:@"playerResponse"]; } @catch (NSException *e) {}
        }
        if (pr) self.lastActivePlayerResponse = pr;
    }

    if (!self.lastActiveVideoID && self.lastActivePlayerResponse) {
        @try {
            id pd = [self.lastActivePlayerResponse valueForKey:@"playerData"] ?: self.lastActivePlayerResponse;
            id vd = [pd valueForKey:@"videoDetails"];
            id vid = [vd valueForKey:@"videoId"];
            if ([vid isKindOfClass:[NSString class]] && [(NSString *)vid length] > 0) {
                self.lastActiveVideoID = vid;
            }
        } @catch (NSException *e) {}
    }

    if (self.lastActivePlayerResponse) {
        @try {
            id pd = [self.lastActivePlayerResponse valueForKey:@"playerData"] ?: self.lastActivePlayerResponse;
            id sd = nil;
            if ([pd respondsToSelector:@selector(streamingData)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                sd = [pd performSelector:@selector(streamingData)];
                #pragma clang diagnostic pop
            } else {
                @try { sd = [pd valueForKey:@"streamingData"]; } @catch (NSException *e) {}
            }
            if (sd) self.lastStreamingData = sd;
        } @catch (NSException *e) {}
    }
}

- (void)handleDownloadButtonTap:(UIGestureRecognizer *)gesture {
    UIView *sourceView = gesture.view;
    [self showDownloadMenuFromView:sourceView playerViewController:nil];
}

- (BOOL)handleOfflineEndpointCommand:(nullable id)command fromView:(nullable id)sourceView {
    return [self handleOfflineEndpointCommand:command entry:nil fromView:sourceView];
}

- (BOOL)handleOfflineEndpointCommand:(nullable id)command entry:(nullable id)entry fromView:(nullable id)sourceView {
    NSString *videoId = extractVideoIdFromCommand(command, entry);

    // Bóc tách actual UIView an toàn từ sourceView (hỗ trợ cả Texture ASDisplayNode và ELMNodeController)
    UIView *actualSourceView = nil;
    if ([sourceView isKindOfClass:[UIView class]]) {
        actualSourceView = (UIView *)sourceView;
    } else if (sourceView && [sourceView respondsToSelector:@selector(view)]) {
        id v = safePerform(sourceView, @selector(view));
        if ([v isKindOfClass:[UIView class]]) actualSourceView = (UIView *)v;
    } else if (sourceView && [sourceView respondsToSelector:@selector(node)]) {
        id node = safePerform(sourceView, @selector(node));
        if ([node respondsToSelector:@selector(view)]) {
            id v = safePerform(node, @selector(view));
            if ([v isKindOfClass:[UIView class]]) actualSourceView = (UIView *)v;
        }
    }

    id foundVideo = nil;
    id foundPR = nil;
    id activeVC = findPlayerViewController(actualSourceView);
    if (!activeVC) activeVC = findPlaybackContextFromView(actualSourceView, &foundVideo, &foundPR);
    if (!activeVC) activeVC = self.activePlayerViewController;

    if (activeVC) self.activePlayerViewController = activeVC;
    if (foundVideo) self.activeVideo = foundVideo;
    if (foundPR) self.lastActivePlayerResponse = foundPR;

    if (!videoId || videoId.length == 0) {
        if (foundVideo) {
            @try { videoId = [foundVideo valueForKey:@"videoId"] ?: [foundVideo valueForKey:@"videoID"]; } @catch (NSException *e) {}
        }
        if (!videoId && activeVC) {
            videoId = extractVideoIdFromPlayerVC(activeVC);
        }
        if (!videoId) {
            videoId = self.lastActiveVideoID;
        }
    }

    UIViewController *topVC = getTopViewController(nil);
    NSString *topName = topVC ? NSStringFromClass([topVC class]) : @"";
    BOOL isWatchContext = [topName containsString:@"Watch"] || [topName containsString:@"Player"] || activeVC != nil;

    // Nếu ở Watch Context mà videoId vẫn chưa có, cố gắng lấy lại từ topVC
    if ((!videoId || videoId.length == 0) && isWatchContext && topVC) {
        videoId = extractVideoIdFromPlayerVC(topVC) ?: self.lastActiveVideoID;
    }

    // Nếu hoàn toàn không có video nào và không ở Watch Context (người dùng đang ở tab Downloads trong Thư viện):
    // Cho phép YouTube chạy %orig để load danh sách Downloads bình thường, không bị loading vô tận
    if (!videoId || videoId.length == 0) {
        return NO;
    }

    // Đã có videoId: Dispatch async mở ActionSheet tải của tweak để giải phóng touch stack và CHẶN 100% POPUP YOUTUBE PREMIUM
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleDownloadForVideoId:videoId playerResponse:foundPR sourceView:actualSourceView];
    });
    return YES;
}

- (void)handleDownloadForVideoId:(nullable NSString *)videoId playerResponse:(nullable id)playerResponse sourceView:(nullable id)sourceView {
    id foundVideo = nil;
    id foundPR = playerResponse;
    id activeVC = self.activePlayerViewController;
    if (!activeVC || !foundVideo || !foundPR) {
        id ctxVC = findPlaybackContextFromView(sourceView, &foundVideo, &foundPR);
        if (ctxVC && !activeVC) activeVC = ctxVC;
    }
    if (activeVC) self.activePlayerViewController = activeVC;
    if (foundVideo) self.activeVideo = foundVideo;
    if (foundPR && !playerResponse) playerResponse = foundPR;

    // Kiểm tra xem player trên RAM có đang phát đúng videoId này không
    NSString *currentVid = nil;
    if (foundVideo) {
        @try { currentVid = [foundVideo valueForKey:@"videoId"] ?: [foundVideo valueForKey:@"videoID"]; } @catch (NSException *e) {}
    }
    if (!currentVid && activeVC) currentVid = extractVideoIdFromPlayerVC(activeVC);
    if (!currentVid) currentVid = self.lastActiveVideoID;

    BOOL isSameVideo = (videoId && currentVid && [videoId isEqualToString:currentVid]);

    // 1. Nếu cùng video và có playerResponse từ player
    if (isSameVideo && playerResponse) {
        [self showDownloadMenuWithPlayerData:playerResponse sourceView:sourceView videoID:videoId];
        return;
    }

    // 2. Nếu cùng video và có activeVC / activeVideo -> Dùng formats trực tiếp từ player
    if (isSameVideo) {
        id activeVideo = self.activeVideo ?: foundVideo;
        if (!activeVideo && activeVC) {
            @try { activeVideo = [activeVC valueForKey:@"activeVideo"]; } @catch (NSException *e) {}
        }
        if (activeVideo || activeVC) {
            id pr = extractPlayerResponseFromPlayerVC(activeVC) ?: self.lastActivePlayerResponse;
            if (pr) {
                [self showDownloadMenuWithPlayerData:pr sourceView:sourceView videoID:videoId];
                return;
            }
        }
    }

    // 3. Nếu không cùng video hoặc video ở ngoài Feed chưa phát: fetch từ InnerTube API theo đúng videoId
    if (videoId && videoId.length > 0) {
        showToast(@"Đang lấy dữ liệu video...");
        [self fetchStreamingDataForVideoId:videoId completion:^(NSDictionary *playerData, NSError *err) {
            if (err || !playerData) {
                showToast(@"Không thể lấy dữ liệu video, vui lòng thử lại!");
                return;
            }
            [self showDownloadMenuWithPlayerData:playerData sourceView:sourceView videoID:videoId];
        }];
        return;
    }

    // 4. Fallback cuối cùng
    [self showDownloadMenuFromView:sourceView playerViewController:activeVC];
}

- (void)fetchStreamingDataForVideoId:(NSString *)videoId completion:(void (^)(NSDictionary *playerData, NSError *error))completion {
    if (!videoId || videoId.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTL" code:-1 userInfo:nil]);
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"];

    // 1. Thử Client ANDROID_TESTSUITE (trả về URL trực tiếp không bị mã hóa cipher cho mọi định dạng)
    NSMutableURLRequest *reqTestSuite = [NSMutableURLRequest requestWithURL:url];
    reqTestSuite.HTTPMethod = @"POST";
    [reqTestSuite setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [reqTestSuite setValue:@"com.google.android.youtube/1.9 (Linux; U; Android 11) gzip" forHTTPHeaderField:@"User-Agent"];

    NSDictionary *bodyTestSuite = @{
        @"context": @{
            @"client": @{
                @"clientName": @"ANDROID_TESTSUITE",
                @"clientVersion": @"1.9",
                @"androidSdkVersion": @30,
                @"hl": @"vi",
                @"gl": @"VN"
            }
        },
        @"videoId": videoId,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES
    };
    reqTestSuite.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyTestSuite options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:reqTestSuite completionHandler:^(NSData *tsData, NSURLResponse *tsRes, NSError *tsErr) {
        NSDictionary *tsJson = nil;
        if (tsData && !tsErr) {
            tsJson = [NSJSONSerialization JSONObjectWithData:tsData options:0 error:nil];
        }

        NSDictionary *tsSd = [tsJson isKindOfClass:[NSDictionary class]] ? tsJson[@"streamingData"] : nil;
        NSArray *tsAdaptive = [tsSd isKindOfClass:[NSDictionary class]] ? tsSd[@"adaptiveFormats"] : nil;
        NSArray *tsFormats = [tsSd isKindOfClass:[NSDictionary class]] ? tsSd[@"formats"] : nil;

        if (([tsAdaptive isKindOfClass:[NSArray class]] && tsAdaptive.count > 0) || ([tsFormats isKindOfClass:[NSArray class]] && tsFormats.count > 0)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(tsJson, nil);
            });
            return;
        }

        // 2. Thử TVHTML5_SIMPLY_EMBEDDED (cung cấp direct URL không mã hóa cipher)
        NSMutableURLRequest *reqTV = [NSMutableURLRequest requestWithURL:url];
        reqTV.HTTPMethod = @"POST";
        [reqTV setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [reqTV setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
        [reqTV setValue:@"Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/5.0 TV Safari/538.1" forHTTPHeaderField:@"User-Agent"];

        NSDictionary *bodyTV = @{
            @"context": @{
                @"client": @{
                    @"clientName": @"TVHTML5_SIMPLY_EMBEDDED",
                    @"clientVersion": @"2.0"
                },
                @"thirdParty": @{
                    @"embedUrl": @"https://www.youtube.com"
                }
            },
            @"videoId": videoId
        };
        reqTV.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyTV options:0 error:nil];

        [[[NSURLSession sharedSession] dataTaskWithRequest:reqTV completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
            NSDictionary *json = nil;
            if (data && !err) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }

            NSDictionary *sd = [json isKindOfClass:[NSDictionary class]] ? json[@"streamingData"] : nil;
            NSArray *adaptive = [sd isKindOfClass:[NSDictionary class]] ? sd[@"adaptiveFormats"] : nil;
            NSArray *formats = [sd isKindOfClass:[NSDictionary class]] ? sd[@"formats"] : nil;

            if (([adaptive isKindOfClass:[NSArray class]] && adaptive.count > 0) || ([formats isKindOfClass:[NSArray class]] && formats.count > 0)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(json, nil);
                });
                return;
            }

            // 3. Thử Client ANDROID (cực kỳ ổn định và trả về đầy đủ H.264/AAC formats)
        NSMutableURLRequest *reqAndroid = [NSMutableURLRequest requestWithURL:url];
        reqAndroid.HTTPMethod = @"POST";
        [reqAndroid setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [reqAndroid setValue:@"com.google.android.youtube/19.29.35 (Linux; U; Android 11) gzip" forHTTPHeaderField:@"User-Agent"];

        NSDictionary *bodyAndroid = @{
            @"context": @{
                @"client": @{
                    @"clientName": @"ANDROID",
                    @"clientVersion": @"19.29.35",
                    @"androidSdkVersion": @30,
                    @"hl": @"vi",
                    @"gl": @"VN"
                }
            },
            @"videoId": videoId,
            @"playbackContext": @{
                @"contentPlaybackContext": @{
                    @"html5Preference": @"HTML5_PREF_WANTS"
                }
            }
        };
        reqAndroid.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyAndroid options:0 error:nil];

        [[[NSURLSession sharedSession] dataTaskWithRequest:reqAndroid completionHandler:^(NSData *andData, NSURLResponse *andRes, NSError *andErr) {
            NSDictionary *andJson = nil;
            if (andData && !andErr) {
                andJson = [NSJSONSerialization JSONObjectWithData:andData options:0 error:nil];
            }

            NSDictionary *andSd = [andJson isKindOfClass:[NSDictionary class]] ? andJson[@"streamingData"] : nil;
            NSArray *andAdaptive = [andSd isKindOfClass:[NSDictionary class]] ? andSd[@"adaptiveFormats"] : nil;
            NSArray *andFormats = [andSd isKindOfClass:[NSDictionary class]] ? andSd[@"formats"] : nil;

            if (([andAdaptive isKindOfClass:[NSArray class]] && andAdaptive.count > 0) || ([andFormats isKindOfClass:[NSArray class]] && andFormats.count > 0)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(andJson, nil);
                });
                return;
            }

            // 3. Fallback sang Client IOS chuẩn của app
            NSMutableURLRequest *reqIOS = [NSMutableURLRequest requestWithURL:url];
            reqIOS.HTTPMethod = @"POST";
            [reqIOS setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [reqIOS setValue:@"com.google.ios.youtube/21.34.3 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

            NSDictionary *bodyIOS = @{
                @"context": @{
                    @"client": @{
                        @"clientName": @"IOS",
                        @"clientVersion": @"21.34.3",
                        @"hl": @"vi",
                        @"gl": @"VN"
                    }
                },
                @"videoId": videoId,
                @"playbackContext": @{
                    @"contentPlaybackContext": @{
                        @"html5Preference": @"HTML5_PREF_WANTS"
                    }
                }
            };
            reqIOS.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyIOS options:0 error:nil];

            [[[NSURLSession sharedSession] dataTaskWithRequest:reqIOS completionHandler:^(NSData *fbData, NSURLResponse *fbRes, NSError *fbErr) {
                if (fbErr || !fbData) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil, fbErr ?: [NSError errorWithDomain:@"YTL" code:-1 userInfo:nil]);
                    });
                    return;
                }

                NSError *parseErr = nil;
                NSDictionary *fbJson = [NSJSONSerialization JSONObjectWithData:fbData options:0 error:&parseErr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(fbJson, parseErr);
                });
            }] resume];
        }] resume];
    }] resume];
    }] resume];
}

#pragma mark - Menu Presentation

- (void)showDownloadMenuFromView:(nullable id)sourceView playerViewController:(id)playerVC {
    @try {
        if (playerVC) self.activePlayerViewController = playerVC;
        id activeVC = self.activePlayerViewController;
        id foundVideo = nil;
        id foundPR = nil;
        if (!activeVC) {
            activeVC = findPlaybackContextFromView(sourceView, &foundVideo, &foundPR);
            if (activeVC) self.activePlayerViewController = activeVC;
            if (foundVideo) self.activeVideo = foundVideo;
            if (foundPR) self.lastActivePlayerResponse = foundPR;
        }

        NSString *videoID = extractVideoIdFromPlayerVC(activeVC) ?: self.lastActiveVideoID;
        id playerResponse = foundPR ?: extractPlayerResponseFromPlayerVC(activeVC) ?: self.lastActivePlayerResponse;

        id activeVideo = self.activeVideo ?: foundVideo;
        if (!activeVideo && activeVC) {
            activeVideo = safeValueForKey(activeVC, @"activeVideo") ?: safePerform(activeVC, @selector(activeVideo));
        }

        // Nếu có activeVideo hoặc playerResponse: Mở menu ngay!
        if (activeVideo || playerResponse) {
            id playerData = nil;
            if (playerResponse) {
                playerData = safePerform(playerResponse, @selector(playerData)) ?: safeValueForKey(playerResponse, @"playerData");
                if (!playerData) playerData = playerResponse;
            }
            [self showDownloadMenuWithPlayerData:playerData sourceView:sourceView videoID:videoID];
            return;
        }

        if (videoID && videoID.length > 0) {
            showToast(@"Đang lấy dữ liệu video...");
            [self fetchStreamingDataForVideoId:videoID completion:^(NSDictionary *playerData, NSError *err) {
                if (playerData) {
                    [self showDownloadMenuWithPlayerData:playerData sourceView:sourceView videoID:videoID];
                } else {
                    showToast(@"Không thể lấy dữ liệu video, vui lòng thử lại!");
                }
            }];
            return;
        }

        showToast(@"Không tìm thấy video khả dụng");
    } @catch (NSException *e) {
        NSLog(@"[YTLite] Exception in showDownloadMenuFromView: %@", e);
        showToast(@"Lỗi mở menu tải, vui lòng thử lại!");
    }
}

- (void)showDownloadMenuWithPlayerData:(id)playerData sourceView:(nullable id)sourceView videoID:(NSString *)defaultVideoID {
    @try {
        id activeVC = self.activePlayerViewController ?: findPlayerViewController(sourceView);
        id activeVideo = self.activeVideo;
        if (!activeVideo && activeVC) {
            activeVideo = safeValueForKey(activeVC, @"activeVideo") ?: safePerform(activeVC, @selector(activeVideo));
        }

        NSString *activeVid = nil;
        if (activeVideo) {
            activeVid = safeValueForKey(activeVideo, @"videoId") ?: safeValueForKey(activeVideo, @"videoID") ?: safePerform(activeVideo, @selector(videoId)) ?: safePerform(activeVideo, @selector(videoID));
        }
        if (!activeVid && activeVC) activeVid = extractVideoIdFromPlayerVC(activeVC);
        if (!activeVid) activeVid = self.lastActiveVideoID;

        if (defaultVideoID && defaultVideoID.length > 0 && activeVid && activeVid.length > 0 && ![defaultVideoID isEqualToString:activeVid]) {
            // Không trùng video đang active trong player -> không lấy format của video cũ
            activeVideo = nil;
        }

        if (!playerData && !activeVideo) {
            showToast(@"Không có thông tin luồng video");
            return;
        }

    id videoDetails = nil;
    @try { videoDetails = [playerData valueForKey:@"videoDetails"]; } @catch (NSException *e) {}

    NSString *videoID = defaultVideoID;
    if (!videoID || videoID.length == 0) {
        if (activeVideo) {
            @try { videoID = [activeVideo valueForKey:@"videoId"] ?: [activeVideo valueForKey:@"videoID"]; } @catch (NSException *e) {}
        }
        if (!videoID && activeVC) {
            videoID = extractVideoIdFromPlayerVC(activeVC);
        }
        if (!videoID) {
            @try { videoID = [videoDetails valueForKey:@"videoId"]; } @catch (NSException *e) {}
        }
    }
    if (!videoID || videoID.length == 0) {
        videoID = self.lastActiveVideoID ?: @"";
    }

    NSString *videoTitle = nil;
    if (activeVideo) {
        @try { videoTitle = [activeVideo valueForKey:@"title"]; } @catch (NSException *e) {}
    }
    if (!videoTitle || videoTitle.length == 0) {
        @try { videoTitle = [videoDetails valueForKey:@"title"]; } @catch (NSException *e) {}
    }
    if ((!videoTitle || videoTitle.length == 0) && activeVC) {
        @try { videoTitle = [activeVC title]; } @catch (NSException *e) {}
    }
    if (!videoTitle || videoTitle.length == 0) videoTitle = @"YouTube Video";

    // Trích xuất streamingData đa tầng
    id streamingData = nil;
    if ([playerData isKindOfClass:[NSDictionary class]]) {
        streamingData = ((NSDictionary *)playerData)[@"streamingData"];
    }
    if (!streamingData) {
        streamingData = safePerform(playerData, @selector(streamingData)) ?: safeValueForKey(playerData, @"streamingData");
    }
    if (!streamingData) {
        id pr = safePerform(playerData, @selector(playerResponse)) ?: safeValueForKey(playerData, @"playerResponse");
        if (!pr) {
            pr = safePerform(playerData, @selector(contentPlayerResponse)) ?: safeValueForKey(playerData, @"contentPlayerResponse");
        }
        if (pr) {
            streamingData = safePerform(pr, @selector(streamingData)) ?: safeValueForKey(pr, @"streamingData");
        }
    }
    if (!streamingData && self.lastStreamingData) {
        streamingData = self.lastStreamingData;
    }
    if (streamingData) self.lastStreamingData = streamingData;

    // 1. ƯU TIÊN HÀNG ĐẦU: Bóc tách HLS Master Playlist (Không bao giờ bị chặn 403 BotGuard)
    NSString *hlsUrl = safePerform(streamingData, @selector(hlsManifestURL)) ?: safePerform(streamingData, @selector(hlsManifestUrl)) ?: safeValueForKey(streamingData, @"hlsManifestURL") ?: safeValueForKey(streamingData, @"hlsManifestUrl");
    if (!hlsUrl && [streamingData isKindOfClass:[NSDictionary class]]) {
        hlsUrl = ((NSDictionary *)streamingData)[@"hlsManifestUrl"] ?: ((NSDictionary *)streamingData)[@"hlsManifestURL"];
    }

    if ([hlsUrl isKindOfClass:[NSURL class]]) {
        hlsUrl = [(NSURL *)hlsUrl absoluteString];
    }

    if (hlsUrl && [hlsUrl isKindOfClass:[NSString class]] && hlsUrl.length > 0) {
        showToast(@"Đang phân tích định dạng HLS...");
        [YTLM3U8Parser parseMasterPlaylistURL:hlsUrl completion:^(NSArray<YTLM3U8Variant *> *variants, NSError *error) {
            if (variants.count > 0) {
                [self showHLSDownloadMenuWithVariants:variants title:videoTitle sourceView:sourceView videoID:videoID];
            } else {
                [self showDownloadMenuWithPlayerDataFallback:playerData streamingData:streamingData activeVideo:activeVideo activeVC:activeVC videoTitle:videoTitle videoID:videoID sourceView:sourceView defaultVideoID:defaultVideoID];
            }
        }];
        return;
    }

    // Nếu không có hlsUrl và playerData là đối tượng từ RAM player (không phải JSON InnerTube):
    // Tự động fetch InnerTube API để luôn nhận được HLS Master Playlist (tránh format thiếu URL của player nội bộ)
    if ((!hlsUrl || hlsUrl.length == 0) && videoID && videoID.length > 0 && ![playerData isKindOfClass:[NSDictionary class]]) {
        showToast(@"Đang lấy dữ liệu video...");
        [self fetchStreamingDataForVideoId:videoID completion:^(NSDictionary *fetchedData, NSError *err) {
            if (fetchedData && [fetchedData isKindOfClass:[NSDictionary class]]) {
                [self showDownloadMenuWithPlayerData:fetchedData sourceView:sourceView videoID:videoID];
            } else {
                [self showDownloadMenuWithPlayerDataFallback:playerData streamingData:streamingData activeVideo:activeVideo activeVC:activeVC videoTitle:videoTitle videoID:videoID sourceView:sourceView defaultVideoID:defaultVideoID];
            }
        }];
        return;
    }

    [self showDownloadMenuWithPlayerDataFallback:playerData streamingData:streamingData activeVideo:activeVideo activeVC:activeVC videoTitle:videoTitle videoID:videoID sourceView:sourceView defaultVideoID:defaultVideoID];
    } @catch (NSException *e) {
        NSLog(@"[YTLite] Exception in showDownloadMenuWithPlayerData: %@", e);
        showToast(@"Lỗi phân tích video, vui lòng thử lại!");
    }
}

- (void)showDownloadMenuWithPlayerDataFallback:(id)playerData streamingData:(id)streamingData activeVideo:(id)activeVideo activeVC:(id)activeVC videoTitle:(NSString *)videoTitle videoID:(NSString *)videoID sourceView:(nullable id)sourceView defaultVideoID:(NSString *)defaultVideoID {
    NSArray *adaptiveFormats = safePerform(streamingData, @selector(adaptiveFormatsArray)) ?: safeValueForKey(streamingData, @"adaptiveFormatsArray") ?: safeValueForKey(streamingData, @"adaptiveFormats");
    NSArray *muxedFormats = safePerform(streamingData, @selector(formatsArray)) ?: safeValueForKey(streamingData, @"formatsArray") ?: safeValueForKey(streamingData, @"formats");

    // Thu thập tất cả formats từ player activeVideo và streamingData
    NSMutableArray *allVideoFormats = [NSMutableArray array];
    NSMutableArray *allAudioFormats = [NSMutableArray array];

    if (activeVideo) {
        @try {
            id svf = [activeVideo valueForKey:@"selectableVideoFormats"];
            if ([svf isKindOfClass:[NSArray class]] && [(NSArray *)svf count] > 0) {
                [allVideoFormats addObjectsFromArray:svf];
            }
            id saf = [activeVideo valueForKey:@"selectableAudioFormats"];
            if ([saf isKindOfClass:[NSArray class]] && [(NSArray *)saf count] > 0) {
                [allAudioFormats addObjectsFromArray:saf];
            }
            id singleAudio = [activeVideo valueForKey:@"selectedAudioFormat"];
            if (singleAudio && ![allAudioFormats containsObject:singleAudio]) {
                [allAudioFormats insertObject:singleAudio atIndex:0];
            }
        } @catch (NSException *e) {}
    }

    if ([adaptiveFormats isKindOfClass:[NSArray class]]) {
        [allVideoFormats addObjectsFromArray:adaptiveFormats];
        [allAudioFormats addObjectsFromArray:adaptiveFormats];
    }

    // 1. Tìm luồng âm thanh AAC M4A tốt nhất (itag 140 / 141 hoặc audio/mp4)
    id bestAACAudio = nil;
    for (id format in allAudioFormats) {
        NSString *mime = extractMimeType(format);
        int itag = extractItag(format);
        if ([mime containsString:@"audio/mp4"] || itag == 140 || itag == 141) {
            bestAACAudio = format;
            break;
        }
    }
    if (!bestAACAudio) {
        for (id format in allAudioFormats) {
            NSString *mime = extractMimeType(format);
            if ([mime containsString:@"audio"]) {
                bestAACAudio = format;
                break;
            }
        }
    }

    // 2. Thu thập các luồng video theo độ phân giải (1080p, 720p, 480p, 360p, 240p)
    NSMutableArray *videoActions = [NSMutableArray array];
    NSMutableSet *seenKeys = [NSMutableSet set];

    NSArray *targetResolutions = @[@"1080p", @"720p", @"480p", @"360p", @"240p"];

    for (NSString *targetRes in targetResolutions) {
        id matchedMP4 = nil;

        // Ưu tiên H.264 / AVC1 (itag 137, 299, 136, 298, 135, 134, 160)
        for (id format in allVideoFormats) {
            NSString *q = extractQualityLabel(format);
            if (![q containsString:targetRes]) continue;

            NSString *m = extractMimeType(format);
            int it = extractItag(format);
            BOOL isH264 = [m containsString:@"avc1"] || [m containsString:@"h264"] ||
                          it == 137 || it == 299 || it == 136 || it == 298 || it == 135 || it == 134 || it == 160;
            if (isH264) {
                matchedMP4 = format;
                break;
            }
        }

        // Nếu không có AVC1, tìm MP4 bất kỳ
        if (!matchedMP4) {
            for (id format in allVideoFormats) {
                NSString *q = extractQualityLabel(format);
                if (![q containsString:targetRes]) continue;

                NSString *m = extractMimeType(format);
                if ([m containsString:@"video/mp4"]) {
                    matchedMP4 = format;
                    break;
                }
            }
        }

        // Fallback định dạng bất kỳ khớp resolution
        if (!matchedMP4) {
            for (id format in allVideoFormats) {
                NSString *q = extractQualityLabel(format);
                if ([q containsString:targetRes]) {
                    matchedMP4 = format;
                    break;
                }
            }
        }

        // Fallback muxed format có sẵn audio
        id matchedMuxed = nil;
        if (!matchedMP4 && [muxedFormats isKindOfClass:[NSArray class]]) {
            for (id format in muxedFormats) {
                NSString *q = extractQualityLabel(format);
                if ([q containsString:targetRes]) {
                    matchedMuxed = format;
                    break;
                }
            }
        }

        if (matchedMP4 && ![seenKeys containsObject:targetRes]) {
            [seenKeys addObject:targetRes];
            NSString *badge = [targetRes isEqualToString:@"1080p"] ? @"(Full HD MP4)" : ([targetRes isEqualToString:@"720p"] ? @"(HD MP4)" : @"(MP4)");
            [videoActions addObject:@{
                @"title": [NSString stringWithFormat:@"📹 Tải Video %@ %@", targetRes, badge],
                @"format": matchedMP4,
                @"isMuxed": @NO,
                @"quality": targetRes,
                @"audioStream": (bestAACAudio ?: [NSNull null])
            }];
        } else if (matchedMuxed && ![seenKeys containsObject:targetRes]) {
            [seenKeys addObject:targetRes];
            [videoActions addObject:@{
                @"title": [NSString stringWithFormat:@"📹 Tải Video %@ (Muxed)", targetRes],
                @"format": matchedMuxed,
                @"isMuxed": @YES,
                @"quality": targetRes,
                @"audioStream": [NSNull null]
            }];
        }
    }

    // Quét động các định dạng video thực tế nếu các độ phân giải chuẩn chưa khớp được
    if (videoActions.count == 0) {
        for (id format in allVideoFormats) {
            NSString *m = extractMimeType(format);
            if ([m containsString:@"audio"]) continue;
            NSString *q = extractQualityLabel(format);
            if (q.length == 0) {
                int h = extractHeight(format);
                if (h > 0) q = [NSString stringWithFormat:@"%dp", h];
                else q = @"MP4";
            }
            if (![seenKeys containsObject:q]) {
                [seenKeys addObject:q];
                [videoActions addObject:@{
                    @"title": [NSString stringWithFormat:@"📹 Tải Video %@", q],
                    @"format": format,
                    @"isMuxed": @NO,
                    @"quality": q,
                    @"audioStream": (bestAACAudio ?: [NSNull null])
                }];
            }
        }
        if (videoActions.count == 0 && [muxedFormats isKindOfClass:[NSArray class]]) {
            for (id format in muxedFormats) {
                NSString *q = extractQualityLabel(format);
                if (q.length == 0) q = @"MP4 (Muxed)";
                if (![seenKeys containsObject:q]) {
                    [seenKeys addObject:q];
                    [videoActions addObject:@{
                        @"title": [NSString stringWithFormat:@"📹 Tải Video %@", q],
                        @"format": format,
                        @"isMuxed": @YES,
                        @"quality": q,
                        @"audioStream": [NSNull null]
                    }];
                }
            }
        }
    }

    // TỰ ĐỘNG FALLBACK FETCH: Chỉ fetch nếu chưa tìm thấy format nào và playerData chưa phải là JSON từ InnerTube
    if (videoActions.count == 0 && !bestAACAudio) {
        if (videoID && videoID.length > 0 && ![playerData isKindOfClass:[NSDictionary class]]) {
            showToast(@"Đang tìm kiếm định dạng video...");
            [self fetchStreamingDataForVideoId:videoID completion:^(NSDictionary *fetchedData, NSError *err) {
                if (fetchedData && [fetchedData isKindOfClass:[NSDictionary class]] && fetchedData[@"streamingData"]) {
                    [self showDownloadMenuWithPlayerData:fetchedData sourceView:sourceView videoID:videoID];
                } else {
                    showToast(@"Không tìm thấy định dạng tải khả dụng cho video này!");
                }
            }];
            return;
        }
        showToast(@"Không tìm thấy định dạng tải khả dụng cho video này!");
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:videoTitle
                                                                   message:@"Chọn chất lượng tải xuống (YouTube Plus)"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *info in videoActions) {
        id format = info[@"format"];
        BOOL isMuxed = [info[@"isMuxed"] boolValue];
        NSString *quality = info[@"quality"];
        NSString *actionTitle = info[@"title"];
        id audioStream = info[@"audioStream"];
        if (audioStream == [NSNull null]) audioStream = nil;

        [sheet addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self downloadVideoFormat:format
                          audioFormat:(isMuxed ? nil : audioStream)
                                title:videoTitle
                              quality:quality
                              isMuxed:isMuxed
                              videoID:videoID];
        }]];
    }

    // Tùy chọn Tải riêng Âm thanh M4A HQ
    if (bestAACAudio) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"🎵 Tải Âm thanh M4A (Audio HQ)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self downloadAudioFormat:bestAACAudio title:videoTitle videoID:videoID];
        }]];
    }

    // Thumbnail HD & Sao chép Link
    if (videoID.length > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"🖼️ Tải Ảnh thu nhỏ (Thumbnail HD)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self downloadThumbnailWithVideoID:videoID title:videoTitle];
        }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"📋 Sao chép Liên kết Video" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://youtu.be/%@", videoID];
            showToast(@"Đã sao chép liên kết vào bộ nhớ tạm");
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    presentActionSheetSafely(nil, sheet, sourceView);
}

#pragma mark - HLS Download Menu & Execution (FFmpegKit)

- (void)showHLSDownloadMenuWithVariants:(NSArray<YTLM3U8Variant *> *)variants
                                  title:(NSString *)videoTitle
                             sourceView:(nullable id)sourceView
                                videoID:(nullable NSString *)videoID {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:videoTitle
                                                                       message:@"Chọn chất lượng tải xuống (HLS Stream)"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        // Lọc trùng độ phân giải (ưu tiên bandwidth cao nhất)
        NSMutableArray<YTLM3U8Variant *> *displayVariants = [NSMutableArray array];
        NSMutableSet<NSString *> *seenQualities = [NSMutableSet set];
        for (YTLM3U8Variant *v in variants) {
            NSString *label = v.quality ?: v.resolution;
            if (!label) continue;
            if (![seenQualities containsObject:label]) {
                [seenQualities addObject:label];
                [displayVariants addObject:v];
            }
        }
        if (displayVariants.count == 0) {
            [displayVariants addObjectsFromArray:variants];
        }

        for (YTLM3U8Variant *variant in displayVariants) {
            NSString *label = variant.quality ?: variant.resolution;
            NSString *actionTitle = [NSString stringWithFormat:@"🎬 Tải Video %@", label];
            [sheet addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self downloadHLSVariant:variant title:videoTitle videoID:videoID];
            }]];
        }

        // Tùy chọn Tải Âm thanh M4A từ stream
        if (variants.count > 0) {
            YTLM3U8Variant *bestVariant = variants.firstObject;
            [sheet addAction:[UIAlertAction actionWithTitle:@"🎵 Tải Âm thanh (Audio M4A)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self downloadHLSAudioWithVariant:bestVariant title:videoTitle videoID:videoID];
            }]];
        }

        // Thumbnail HD & Sao chép Link
        if (videoID.length > 0) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"🖼️ Tải Ảnh thu nhỏ (Thumbnail HD)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self downloadThumbnailWithVideoID:videoID title:videoTitle];
            }]];

            [sheet addAction:[UIAlertAction actionWithTitle:@"📋 Sao chép Liên kết Video" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://youtu.be/%@", videoID];
                showToast(@"Đã sao chép liên kết vào bộ nhớ tạm");
            }]];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

        presentActionSheetSafely(nil, sheet, sourceView);
    });
}

- (void)downloadHLSVariant:(YTLM3U8Variant *)variant title:(NSString *)title videoID:(nullable NSString *)videoID {
    if (!variant || !variant.streamURL || variant.streamURL.length == 0) {
        showToast(@"Không có URL phân đoạn hợp lệ để tải");
        return;
    }

    NSString *cleanTitle = sanitizeFileName(title);
    NSString *fileName = [NSString stringWithFormat:@"%@_%@.mp4", cleanTitle, [[NSUUID UUID] UUIDString]];
    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    [[YTLDownloadProgressHUD sharedHUD] showWithTitle:[NSString stringWithFormat:@"Đang tải %@ (%@)", cleanTitle, variant.quality ?: @"HLS"] cancelHandler:^{
        [FFmpegKit cancel];
    }];

    BOOL hasAudioStream = (variant.audioURL && variant.audioURL.length > 0);
    NSArray *arguments = nil;
    if (hasAudioStream) {
        arguments = @[
            @"-y",
            @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
            @"-i", variant.streamURL,
            @"-i", variant.audioURL,
            @"-c:v", @"copy",
            @"-c:a", @"aac",
            @"-bsf:a", @"aac_adtstoasc",
            @"-shortest",
            outputPath
        ];
    } else {
        arguments = @[
            @"-y",
            @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
            @"-i", variant.streamURL,
            @"-c", @"copy",
            @"-bsf:a", @"aac_adtstoasc",
            outputPath
        ];
    }

    [FFmpegKit executeWithArgumentsAsync:arguments withCompleteCallback:^(FFmpegSession *session) {
        ReturnCode *returnCode = [session getReturnCode];
        unsigned long long sz = 0;
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
            sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] fileSize];
        }

        if ([ReturnCode isSuccess:returnCode] && sz > 10240) {
            [self finishVideoDownloadAtURL:outputURL];
        } else {
            // Thử fallback không có bsf nếu stream không cần adtstoasc
            NSArray *fallbackArgs = nil;
            if (hasAudioStream) {
                fallbackArgs = @[
                    @"-y",
                    @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
                    @"-i", variant.streamURL,
                    @"-i", variant.audioURL,
                    @"-c:v", @"copy",
                    @"-c:a", @"aac",
                    @"-shortest",
                    outputPath
                ];
            } else {
                fallbackArgs = @[
                    @"-y",
                    @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
                    @"-i", variant.streamURL,
                    @"-c", @"copy",
                    outputPath
                ];
            }

            [FFmpegKit executeWithArgumentsAsync:fallbackArgs withCompleteCallback:^(FFmpegSession *s2) {
                ReturnCode *rc2 = [s2 getReturnCode];
                unsigned long long sz2 = 0;
                if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
                    sz2 = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] fileSize];
                }

                if ([ReturnCode isSuccess:rc2] && sz2 > 10240) {
                    [self finishVideoDownloadAtURL:outputURL];
                } else {
                    // Fallback cuối: remux audio AAC
                    NSArray *transcodeArgs = @[
                        @"-y",
                        @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
                        @"-i", variant.streamURL,
                        @"-c:v", @"copy",
                        @"-c:a", @"aac",
                        outputPath
                    ];
                    [FFmpegKit executeWithArgumentsAsync:transcodeArgs withCompleteCallback:^(FFmpegSession *s3) {
                        ReturnCode *rc3 = [s3 getReturnCode];
                        unsigned long long sz3 = 0;
                        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
                            sz3 = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] fileSize];
                        }

                        if ([ReturnCode isSuccess:rc3] && sz3 > 10240) {
                            [self finishVideoDownloadAtURL:outputURL];
                        } else {
                            [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:@"Lỗi tải hoặc ghép video HLS"];
                        }
                    } withLogCallback:nil withStatisticsCallback:^(Statistics *stats) {
                        if (stats) {
                            double mb = (double)[stats getSize] / (1024.0 * 1024.0);
                            [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.6 statusText:[NSString stringWithFormat:@"Đang chuyển đổi: %.1f MB", mb]];
                        }
                    }];
                }
            } withLogCallback:nil withStatisticsCallback:^(Statistics *stats) {
                if (stats) {
                    double mb = (double)[stats getSize] / (1024.0 * 1024.0);
                    [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.5 statusText:[NSString stringWithFormat:@"Đang xử lý: %.1f MB", mb]];
                }
            }];
        }
    } withLogCallback:nil withStatisticsCallback:^(Statistics *stats) {
        if (stats) {
            double mb = (double)[stats getSize] / (1024.0 * 1024.0);
            double timeInSec = (double)[stats getTime] / 1000.0;
            NSString *st = [NSString stringWithFormat:@"%.1f MB (%.0fs)", mb, timeInSec];
            [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.4 statusText:st];
        }
    }];
}

- (void)downloadHLSAudioWithVariant:(YTLM3U8Variant *)variant title:(NSString *)title videoID:(nullable NSString *)videoID {
    NSString *sourceAudioURL = (variant.audioURL && variant.audioURL.length > 0) ? variant.audioURL : variant.streamURL;
    if (!sourceAudioURL || sourceAudioURL.length == 0) {
        showToast(@"Không có URL âm thanh hợp lệ để tải");
        return;
    }

    NSString *cleanTitle = sanitizeFileName(title);
    NSString *fileName = [NSString stringWithFormat:@"%@_%@.m4a", cleanTitle, [[NSUUID UUID] UUIDString]];
    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    [[YTLDownloadProgressHUD sharedHUD] showWithTitle:[NSString stringWithFormat:@"Đang tải âm thanh: %@", cleanTitle] cancelHandler:^{
        [FFmpegKit cancel];
    }];

    NSArray *arguments = @[
        @"-y",
        @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
        @"-i", sourceAudioURL,
        @"-vn",
        @"-c:a", @"copy",
        @"-bsf:a", @"aac_adtstoasc",
        outputPath
    ];

    [FFmpegKit executeWithArgumentsAsync:arguments withCompleteCallback:^(FFmpegSession *session) {
        ReturnCode *returnCode = [session getReturnCode];
        unsigned long long sz = 0;
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
            sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] fileSize];
        }

        if ([ReturnCode isSuccess:returnCode] && sz > 10240) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:YES message:@"Tải âm thanh hoàn tất! 🎵"];
                UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[outputURL] applicationActivities:nil];
                presentActionSheetSafely(nil, activity, nil);
            });
        } else {
            // Fallback transcode AAC nếu copy thất bại
            NSArray *transcodeArgs = @[
                @"-y",
                @"-protocol_whitelist", @"file,http,https,tcp,tls,crypto",
                @"-i", sourceAudioURL,
                @"-vn",
                @"-c:a", @"aac",
                @"-b:a", @"192k",
                outputPath
            ];
            [FFmpegKit executeWithArgumentsAsync:transcodeArgs withCompleteCallback:^(FFmpegSession *s2) {
                ReturnCode *rc2 = [s2 getReturnCode];
                unsigned long long sz2 = 0;
                if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
                    sz2 = [[[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] fileSize];
                }

                if ([ReturnCode isSuccess:rc2] && sz2 > 10240) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:YES message:@"Tải âm thanh hoàn tất! 🎵"];
                        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[outputURL] applicationActivities:nil];
                        presentActionSheetSafely(nil, activity, nil);
                    });
                } else {
                    [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:@"Tải âm thanh thất bại!"];
                }
            } withLogCallback:nil withStatisticsCallback:^(Statistics *stats) {
                if (stats) {
                    double mb = (double)[stats getSize] / (1024.0 * 1024.0);
                    [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.5 statusText:[NSString stringWithFormat:@"%.1f MB", mb]];
                }
            }];
        }
    } withLogCallback:nil withStatisticsCallback:^(Statistics *stats) {
        if (stats) {
            double mb = (double)[stats getSize] / (1024.0 * 1024.0);
            [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.5 statusText:[NSString stringWithFormat:@"%.1f MB", mb]];
        }
    }];
}

static NSMutableURLRequest *createDownloadRequest(NSURL *url) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"com.google.ios.youtube/21.34.3 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    return req;
}

#pragma mark - Download Execution

- (void)downloadVideoFormat:(id)videoFormat audioFormat:(nullable id)audioFormat title:(NSString *)title quality:(NSString *)quality isMuxed:(BOOL)isMuxed {
    [self downloadVideoFormat:videoFormat audioFormat:audioFormat title:title quality:quality isMuxed:isMuxed videoID:self.lastActiveVideoID isRetry:NO];
}

- (void)downloadVideoFormat:(id)videoFormat audioFormat:(nullable id)audioFormat title:(NSString *)title quality:(NSString *)quality isMuxed:(BOOL)isMuxed videoID:(nullable NSString *)videoID {
    [self downloadVideoFormat:videoFormat audioFormat:audioFormat title:title quality:quality isMuxed:isMuxed videoID:videoID isRetry:NO];
}

- (void)downloadVideoFormat:(id)videoFormat audioFormat:(nullable id)audioFormat title:(NSString *)title quality:(NSString *)quality isMuxed:(BOOL)isMuxed videoID:(nullable NSString *)videoID isRetry:(BOOL)isRetry {
    NSString *rawVideoURLStr = extractStreamURL(videoFormat);
    NSString *rawAudioURLStr = (isMuxed || !audioFormat) ? nil : extractStreamURL(audioFormat);

    NSString *videoURLStr = sanitizeAndValidateURL(rawVideoURLStr);
    NSString *audioURLStr = sanitizeAndValidateURL(rawAudioURLStr);

    // NẾU THIẾU URL: Chỉ fetch InnerTube tối đa 1 lần duy nhất khi !isRetry
    if (!videoURLStr || videoURLStr.length == 0 || (!isMuxed && audioFormat && (!audioURLStr || audioURLStr.length == 0))) {
        if (!isRetry) {
            NSString *vid = videoID ?: self.lastActiveVideoID;
            if (vid && vid.length > 0) {
                showToast([NSString stringWithFormat:@"Đang chuẩn bị luồng %@...", quality]);
                [self fetchStreamingDataForVideoId:vid completion:^(NSDictionary *fetchedData, NSError *err) {
                    if (fetchedData && [fetchedData isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *sd = fetchedData[@"streamingData"];
                        NSArray *ad = [sd isKindOfClass:[NSDictionary class]] ? sd[@"adaptiveFormats"] : nil;
                        id newVF = nil;
                        id newAF = nil;
                        if ([ad isKindOfClass:[NSArray class]]) {
                            for (id f in ad) {
                                NSString *q = extractQualityLabel(f);
                                if ([q containsString:quality]) {
                                    newVF = f;
                                    break;
                                }
                            }
                            for (id f in ad) {
                                NSString *m = extractMimeType(f);
                                int it = extractItag(f);
                                if ([m containsString:@"audio/mp4"] || it == 140 || it == 141) {
                                    newAF = f;
                                    break;
                                }
                            }
                        }
                        if (!newVF) {
                            NSArray *fmt = [sd isKindOfClass:[NSDictionary class]] ? sd[@"formats"] : nil;
                            if ([fmt isKindOfClass:[NSArray class]]) {
                                for (id f in fmt) {
                                    NSString *q = extractQualityLabel(f);
                                    if ([q containsString:quality]) {
                                        newVF = f;
                                        break;
                                    }
                                }
                            }
                        }
                        if (newVF) {
                            [self downloadVideoFormat:newVF audioFormat:(isMuxed ? nil : (newAF ?: audioFormat)) title:title quality:quality isMuxed:isMuxed videoID:vid isRetry:YES];
                            return;
                        }
                    }
                    showToast(@"Không thể lấy URL luồng tải video");
                }];
                return;
            }
        }
    }

    if (!videoURLStr || videoURLStr.length == 0) {
        showToast(@"Không tìm thấy URL video khả dụng");
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLStr];
    if (!videoURL || !videoURL.scheme || !videoURL.host) {
        showToast(@"URL video không hợp lệ");
        return;
    }

    NSString *cleanName = sanitizeFileName(title);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 300.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSString *tmpDir = NSTemporaryDirectory();

    if (isMuxed || !audioURLStr || audioURLStr.length == 0) {
        // Direct download (Muxed hoặc Video-only khi không có audio URL hợp lệ)
        NSString *hudTitle = [NSString stringWithFormat:@"Đang tải: %@ (%@)", cleanName, quality];
        __block NSURLSessionDownloadTask *task = nil;
        [[YTLDownloadProgressHUD sharedHUD] showWithTitle:hudTitle cancelHandler:^{
            if (task) [task cancel];
        }];

        NSURL *finalDest = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mp4", cleanName, quality]]];
        [[NSFileManager defaultManager] removeItemAtURL:finalDest error:nil];

        task = [session downloadTaskWithRequest:createDownloadRequest(videoURL) completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || !location || (httpResp && httpResp.statusCode >= 400)) {
                NSString *errText = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)(httpResp ? httpResp.statusCode : 0)];
                [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:[NSString stringWithFormat:@"Lỗi tải: %@", errText]];
                return;
            }
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:finalDest error:nil];
            [self finishVideoDownloadAtURL:finalDest];
        }];
        [task resume];
    } else {
        // Parallel Adaptive download (Video MP4 + Audio M4A)
        NSURL *audioURL = [NSURL URLWithString:audioURLStr];
        if (!audioURL || !audioURL.scheme || !audioURL.host) {
            showToast(@"URL âm thanh không hợp lệ");
            return;
        }

        NSString *hudTitle = [NSString stringWithFormat:@"Đang tải: %@ (%@)", cleanName, quality];
        __block NSURLSessionDownloadTask *vTask = nil;
        __block NSURLSessionDownloadTask *aTask = nil;
        [[YTLDownloadProgressHUD sharedHUD] showWithTitle:hudTitle cancelHandler:^{
            if (vTask) [vTask cancel];
            if (aTask) [aTask cancel];
        }];

        NSURL *tempVideoFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_temp_v.mp4", [[NSUUID UUID] UUIDString]]]];
        NSURL *tempAudioFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_temp_a.m4a", [[NSUUID UUID] UUIDString]]]];
        NSURL *finalMergedFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mp4", cleanName, quality]]];

        dispatch_group_t group = dispatch_group_create();
        __block NSError *vError = nil;
        __block NSError *aError = nil;

        dispatch_group_enter(group);
        vTask = [session downloadTaskWithRequest:createDownloadRequest(videoURL) completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || !location || (httpResp && httpResp.statusCode >= 400)) {
                vError = error ?: [NSError errorWithDomain:@"YTL" code:(httpResp ? httpResp.statusCode : -1) userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Video HTTP lỗi %ld", (long)(httpResp ? httpResp.statusCode : 0)]}];
            } else {
                [[NSFileManager defaultManager] moveItemAtURL:location toURL:tempVideoFile error:nil];
            }
            dispatch_group_leave(group);
        }];
        [vTask resume];

        dispatch_group_enter(group);
        aTask = [session downloadTaskWithRequest:createDownloadRequest(audioURL) completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || !location || (httpResp && httpResp.statusCode >= 400)) {
                aError = error ?: [NSError errorWithDomain:@"YTL" code:(httpResp ? httpResp.statusCode : -1) userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Audio HTTP lỗi %ld", (long)(httpResp ? httpResp.statusCode : 0)]}];
            } else {
                [[NSFileManager defaultManager] moveItemAtURL:location toURL:tempAudioFile error:nil];
            }
            dispatch_group_leave(group);
        }];
        [aTask resume];

        dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (vError || aError) {
                [[NSFileManager defaultManager] removeItemAtURL:tempVideoFile error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:tempAudioFile error:nil];
                NSString *errDesc = vError ? vError.localizedDescription : aError.localizedDescription;
                [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:[NSString stringWithFormat:@"Lỗi tải luồng: %@", errDesc]];
                return;
            }

            [[YTLDownloadProgressHUD sharedHUD] updateProgress:0.7 statusText:@"Đang ghép video & âm thanh..."];
            [self mergeVideoURL:tempVideoFile audioURL:tempAudioFile outputURL:finalMergedFile completion:^(BOOL success, NSError *error) {
                [[NSFileManager defaultManager] removeItemAtURL:tempVideoFile error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:tempAudioFile error:nil];

                if (success) {
                    [self finishVideoDownloadAtURL:finalMergedFile];
                } else {
                    [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:[NSString stringWithFormat:@"Lỗi ghép luồng: %@", error.localizedDescription ?: @"Thất bại"]];
                }
            }];
        });
    }
}

- (void)downloadAudioFormat:(id)audioFormat title:(NSString *)title {
    [self downloadAudioFormat:audioFormat title:title videoID:self.lastActiveVideoID isRetry:NO];
}

- (void)downloadAudioFormat:(id)audioFormat title:(NSString *)title videoID:(nullable NSString *)videoID {
    [self downloadAudioFormat:audioFormat title:title videoID:videoID isRetry:NO];
}

- (void)downloadAudioFormat:(id)audioFormat title:(NSString *)title videoID:(nullable NSString *)videoID isRetry:(BOOL)isRetry {
    NSString *rawAudioURLStr = extractStreamURL(audioFormat);
    NSString *audioURLStr = sanitizeAndValidateURL(rawAudioURLStr);

    // NẾU THIẾU URL: Chỉ fetch InnerTube tối đa 1 lần duy nhất khi !isRetry
    if (!audioURLStr || audioURLStr.length == 0) {
        if (!isRetry) {
            NSString *vid = videoID ?: self.lastActiveVideoID;
            if (vid && vid.length > 0) {
                showToast(@"Đang chuẩn bị luồng âm thanh...");
                [self fetchStreamingDataForVideoId:vid completion:^(NSDictionary *fetchedData, NSError *err) {
                    if (fetchedData && [fetchedData isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *sd = fetchedData[@"streamingData"];
                        NSArray *ad = [sd isKindOfClass:[NSDictionary class]] ? sd[@"adaptiveFormats"] : nil;
                        id newAF = nil;
                        if ([ad isKindOfClass:[NSArray class]]) {
                            for (id f in ad) {
                                NSString *m = extractMimeType(f);
                                int it = extractItag(f);
                                if ([m containsString:@"audio/mp4"] || it == 140 || it == 141) {
                                    newAF = f;
                                    break;
                                }
                            }
                        }
                        if (newAF) {
                            [self downloadAudioFormat:newAF title:title videoID:vid isRetry:YES];
                            return;
                        }
                    }
                    showToast(@"Không tìm thấy URL âm thanh khả dụng");
                }];
                return;
            }
        }
    }

    if (!audioURLStr || audioURLStr.length == 0) {
        showToast(@"Không tìm thấy URL âm thanh khả dụng");
        return;
    }

    NSURL *audioURL = [NSURL URLWithString:audioURLStr];
    if (!audioURL || !audioURL.scheme || !audioURL.host) {
        showToast(@"URL âm thanh không hợp lệ");
        return;
    }

    NSString *cleanName = sanitizeFileName(title);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 300.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSString *tmpDir = NSTemporaryDirectory();
    NSURL *destURL = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", cleanName]]];
    [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];

    __block NSURLSessionDownloadTask *task = nil;
    [[YTLDownloadProgressHUD sharedHUD] showWithTitle:[NSString stringWithFormat:@"Đang tải âm thanh: %@", cleanName] cancelHandler:^{
        if (task) [task cancel];
    }];

    task = [session downloadTaskWithRequest:createDownloadRequest(audioURL) completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:@"Tải âm thanh thất bại!"];
            return;
        }
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:destURL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:YES message:@"Tải âm thanh hoàn tất! 🎵"];
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[destURL] applicationActivities:nil];
            presentActionSheetSafely(nil, activity, nil);
        });
    }];
    [task resume];
}

- (void)downloadThumbnailWithVideoID:(NSString *)videoID title:(NSString *)title {
    NSString *maxResURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID];
    NSString *hqURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
    showToast(@"Đang tải ảnh thu nhỏ...");

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithURL:[NSURL URLWithString:maxResURL] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *img = [UIImage imageWithData:data];
        if (img) {
            [self saveImageToPhotos:img];
        } else {
            [[session dataTaskWithURL:[NSURL URLWithString:hqURL] completionHandler:^(NSData *data2, NSURLResponse *response2, NSError *error2) {
                UIImage *img2 = [UIImage imageWithData:data2];
                if (img2) {
                    [self saveImageToPhotos:img2];
                } else {
                    showToast(@"Không thể tải ảnh thu nhỏ");
                }
            }] resume];
        }
    }] resume];
}

- (void)saveImageToPhotos:(UIImage *)image {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            } completionHandler:^(BOOL success, NSError *error) {
                showToast(success ? @"Đã lưu ảnh thu nhỏ vào ứng dụng Ảnh!" : @"Lưu ảnh thu nhỏ thất bại");
            }];
        } else {
            showToast(@"Cần cấp quyền truy cập Ảnh");
        }
    }];
}

#pragma mark - Passthrough Muxing (AVFoundation Native)

- (void)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSDictionary *assetOptions = @{AVURLAssetPreferPreciseDurationAndTimingKey: @YES};
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:assetOptions];
    AVURLAsset *audioAsset = audioURL ? [AVURLAsset URLAssetWithURL:audioURL options:assetOptions] : nil;

    dispatch_group_t group = dispatch_group_create();
    __block AVAssetTrack *videoTrackSource = nil;
    __block AVAssetTrack *audioTrackSource = nil;

    dispatch_group_enter(group);
    [videoAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        NSArray *tracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count > 0) videoTrackSource = tracks.firstObject;
        dispatch_group_leave(group);
    }];

    if (audioAsset) {
        dispatch_group_enter(group);
        [audioAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
            NSArray *tracks = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
            if (tracks.count > 0) audioTrackSource = tracks.firstObject;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!videoTrackSource) {
            if (completion) completion(NO, [NSError errorWithDomain:@"YTLDownload" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Không tìm thấy luồng hình ảnh trong tệp video"}]);
            return;
        }

        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];

        CMTime videoDur = videoTrackSource.timeRange.duration;
        if (CMTIME_IS_INDEFINITE(videoDur) || CMTIME_IS_INVALID(videoDur) || videoDur.value <= 0) {
            videoDur = videoAsset.duration;
        }
        CMTimeRange videoRange = CMTimeRangeMake(kCMTimeZero, videoDur);
        if (CMTIME_IS_INDEFINITE(videoDur) || CMTIME_IS_INVALID(videoDur) || videoDur.value <= 0) {
            videoRange = videoTrackSource.timeRange;
        }
        [compositionVideoTrack insertTimeRange:videoRange ofTrack:videoTrackSource atTime:kCMTimeZero error:nil];

        if (audioTrackSource) {
            AVMutableCompositionTrack *compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime audioDur = audioTrackSource.timeRange.duration;
            if (CMTIME_IS_INDEFINITE(audioDur) || CMTIME_IS_INVALID(audioDur) || audioDur.value <= 0) {
                audioDur = audioAsset.duration;
            }

            CMTime finalDur = videoDur;
            if (CMTIME_IS_VALID(videoDur) && !CMTIME_IS_INDEFINITE(videoDur) &&
                CMTIME_IS_VALID(audioDur) && !CMTIME_IS_INDEFINITE(audioDur) &&
                videoDur.value > 0 && audioDur.value > 0) {
                finalDur = CMTimeCompare(videoDur, audioDur) < 0 ? videoDur : audioDur;
            }
            [compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, finalDur) ofTrack:audioTrackSource atTime:kCMTimeZero error:nil];
        }

        NSString *tmpDir = NSTemporaryDirectory();
        NSString *safeName = [NSString stringWithFormat:@"ytl_mux_%@.mp4", [[NSUUID UUID] UUIDString]];
        NSURL *tempOutputURL = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:safeName]];
        [[NSFileManager defaultManager] removeItemAtURL:tempOutputURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

        void (^finishExport)(NSURL *resultURL) = ^(NSURL *resultURL) {
            NSError *moveErr = nil;
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:resultURL toURL:outputURL error:&moveErr];
            if (moved || [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
                if (completion) completion(YES, nil);
            } else {
                if (completion) completion(YES, nil);
            }
        };

        // Tầng 1: AVAssetExportPresetPassthrough (siêu tốc 0.5s, giữ nguyên gốc 100%)
        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
        exportSession.outputURL = tempOutputURL;
        exportSession.outputFileType = AVFileTypeMPEG4;
        exportSession.shouldOptimizeForNetworkUse = YES;

        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                finishExport(tempOutputURL);
            } else {
                // Tầng 2: Apple Hardware Encoder (AVAssetExportPresetHighestQuality)
                [[NSFileManager defaultManager] removeItemAtURL:tempOutputURL error:nil];
                AVAssetExportSession *fallbackSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
                fallbackSession.outputURL = tempOutputURL;
                fallbackSession.outputFileType = AVFileTypeMPEG4;
                fallbackSession.shouldOptimizeForNetworkUse = YES;

                [fallbackSession exportAsynchronouslyWithCompletionHandler:^{
                    if (fallbackSession.status == AVAssetExportSessionStatusCompleted) {
                        finishExport(tempOutputURL);
                    } else {
                        // Tầng cứu nguy: Lưu video gốc
                        [[NSFileManager defaultManager] removeItemAtURL:tempOutputURL error:nil];
                        NSError *copyErr = nil;
                        [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:outputURL error:&copyErr];
                        if (!copyErr && [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                showToast(@"Đã lưu tệp video MP4 gốc!");
                            });
                            if (completion) completion(YES, nil);
                        } else {
                            NSError *finalErr = fallbackSession.error ?: exportSession.error;
                            if (completion) completion(NO, finalErr);
                        }
                    }
                }];
            }
        }];
    });
}

- (void)finishVideoDownloadAtURL:(NSURL *)finalURL {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:finalURL];
                } completionHandler:^(BOOL success, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:YES message:@"Đã lưu video vào Ảnh 🎉"];
                        } else {
                            [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:NO message:@"Lưu vào Ảnh thất bại, mở bảng chia sẻ"];
                        }
                        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[finalURL] applicationActivities:nil];
                        presentActionSheetSafely(nil, activity, nil);
                    });
                }];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[YTLDownloadProgressHUD sharedHUD] dismissWithSuccess:YES message:@"Tải xong! Mở bảng chia sẻ"];
                    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[finalURL] applicationActivities:nil];
                    presentActionSheetSafely(nil, activity, nil);
                });
            }
        }];
    });
}

@end
