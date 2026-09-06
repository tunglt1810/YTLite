#import "YTLDownloadManager.h"
#import "NSBundle+YTLite.h"
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>

#define LOC(key) [NSBundle ytl_localizedStringForKey:key]

@interface YTLDownloadManager ()
@property (nonatomic, weak) id activePlayerVC;
@end

@implementation YTLDownloadManager

+ (instancetype)sharedManager {
    static YTLDownloadManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

static UIWindow *getKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *getTopViewController(UIViewController *rootVC) {
    if (!rootVC) {
        UIWindow *window = getKeyWindow();
        rootVC = window.rootViewController;
    }
    
    if (rootVC.presentedViewController) {
        return getTopViewController(rootVC.presentedViewController);
    }
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        return getTopViewController([(UINavigationController *)rootVC visibleViewController]);
    }
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        return getTopViewController([(UITabBarController *)rootVC selectedViewController]);
    }
    return rootVC;
}

static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = getKeyWindow();
        if (!window) return;

        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 2;
        toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.88];
        toast.layer.cornerRadius = 18;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0.0;

        CGSize maxSz = CGSizeMake(window.bounds.size.width - 40, 60);
        CGSize fitSz = [toast sizeThatFits:maxSz];
        CGFloat width = MAX(fitSz.width + 32, 140);
        CGFloat height = MAX(fitSz.height + 16, 36);
        CGFloat yPos = 60.0;
        toast.frame = CGRectMake((window.bounds.size.width - width) / 2.0, yPos, width, height);

        [window addSubview:toast];

        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 1.0;
            toast.transform = CGAffineTransformMakeTranslation(0, 8);
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{
                    toast.alpha = 0.0;
                    toast.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

static NSString *extractStreamURL(id formatStream) {
    if (!formatStream) return nil;
    if ([formatStream respondsToSelector:@selector(URL)]) {
        id u = [formatStream performSelector:@selector(URL)];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
    }
    if ([formatStream respondsToSelector:@selector(url)]) {
        id u = [formatStream performSelector:@selector(url)];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
    }
    @try {
        id u = [formatStream valueForKey:@"URL"];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
    } @catch (NSException *e) {}
    @try {
        id u = [formatStream valueForKey:@"url"];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
    } @catch (NSException *e) {}
    return nil;
}

static NSString *extractQualityLabel(id formatStream) {
    if (!formatStream) return nil;
    if ([formatStream respondsToSelector:@selector(qualityLabel)]) {
        id q = [formatStream performSelector:@selector(qualityLabel)];
        if ([q isKindOfClass:[NSString class]] && [(NSString *)q length] > 0) return q;
    }
    @try {
        id q = [formatStream valueForKey:@"qualityLabel"];
        if ([q isKindOfClass:[NSString class]] && [(NSString *)q length] > 0) return q;
    } @catch (NSException *e) {}
    return nil;
}

static NSString *extractMimeType(id formatStream) {
    if (!formatStream) return nil;
    if ([formatStream respondsToSelector:@selector(mimeType)]) {
        id m = [formatStream performSelector:@selector(mimeType)];
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return m;
    }
    @try {
        id m = [formatStream valueForKey:@"mimeType"];
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return m;
    } @catch (NSException *e) {}
    return nil;
}

static NSString *sanitizeFileName(NSString *name) {
    if (!name || name.length == 0) return @"video";
    NSCharacterSet *illegalChars = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*:\",|<>"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:illegalChars] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length > 80) {
        clean = [clean substringToIndex:80];
    }
    return clean.length > 0 ? clean : @"video";
}

- (void)handleDownloadButtonTap:(UIGestureRecognizer *)gesture {
    UIView *sourceView = gesture.view;
    [self showDownloadMenuFromView:sourceView playerViewController:nil];
}

- (void)showDownloadMenuFromView:(UIView *)sourceView playerViewController:(id)playerVC {
    if (playerVC) {
        self.activePlayerVC = playerVC;
    }
    id activeVC = self.activePlayerVC;
    if (!activeVC) {
        showToast(@"Không tìm thấy video đang phát");
        return;
    }

    id playerResponse = nil;
    @try {
        playerResponse = [activeVC valueForKey:@"playerResponse"];
    } @catch (NSException *e) {}

    id playerData = nil;
    if ([playerResponse respondsToSelector:@selector(playerData)]) {
        playerData = [playerResponse performSelector:@selector(playerData)];
    } else {
        @try { playerData = [playerResponse valueForKey:@"playerData"]; } @catch (NSException *e) {}
    }

    id videoDetails = nil;
    @try {
        videoDetails = [playerData valueForKey:@"videoDetails"];
    } @catch (NSException *e) {}

    NSString *videoID = nil;
    @try { videoID = [activeVC valueForKey:@"contentVideoID"]; } @catch (NSException *e) {}
    if (!videoID) {
        @try { videoID = [videoDetails valueForKey:@"videoId"]; } @catch (NSException *e) {}
    }
    if (!videoID) videoID = @"";

    NSString *videoTitle = nil;
    @try { videoTitle = [videoDetails valueForKey:@"title"]; } @catch (NSException *e) {}
    if (!videoTitle || videoTitle.length == 0) videoTitle = @"YouTube Video";

    id streamingData = nil;
    if ([playerData respondsToSelector:@selector(streamingData)]) {
        streamingData = [playerData performSelector:@selector(streamingData)];
    } else {
        @try { streamingData = [playerData valueForKey:@"streamingData"]; } @catch (NSException *e) {}
    }

    NSArray *adaptiveFormats = nil;
    if ([streamingData respondsToSelector:@selector(adaptiveFormatsArray)]) {
        adaptiveFormats = [streamingData performSelector:@selector(adaptiveFormatsArray)];
    } else {
        @try { adaptiveFormats = [streamingData valueForKey:@"adaptiveFormatsArray"]; } @catch (NSException *e) {}
    }

    NSArray *muxedFormats = nil;
    if ([streamingData respondsToSelector:@selector(formatsArray)]) {
        muxedFormats = [streamingData performSelector:@selector(formatsArray)];
    } else {
        @try { muxedFormats = [streamingData valueForKey:@"formatsArray"]; } @catch (NSException *e) {}
    }

    // Find best audio stream (MP4 / AAC)
    id bestAudioStream = nil;
    for (id format in adaptiveFormats) {
        NSString *mime = extractMimeType(format);
        if ([mime containsString:@"audio/mp4"]) {
            bestAudioStream = format;
            break;
        }
    }
    if (!bestAudioStream) {
        for (id format in adaptiveFormats) {
            NSString *mime = extractMimeType(format);
            if ([mime containsString:@"audio/"]) {
                bestAudioStream = format;
                break;
            }
        }
    }

    // Collect distinct video qualities (prefer video/mp4)
    NSMutableArray *videoActions = [NSMutableArray array];
    NSMutableSet *seenResolutions = [NSMutableSet set];

    // Priority resolutions
    NSArray *targetResolutions = @[@"1080p", @"720p", @"480p", @"360p", @"240p", @"144p"];

    for (NSString *targetRes in targetResolutions) {
        id matchedFormat = nil;
        BOOL isMuxed = NO;

        // Check adaptive formats first (for highest quality)
        for (id format in adaptiveFormats) {
            NSString *quality = extractQualityLabel(format);
            NSString *mime = extractMimeType(format);
            if ([quality containsString:targetRes] && [mime containsString:@"video/mp4"]) {
                matchedFormat = format;
                break;
            }
        }

        // Fallback to muxed formats if not found in adaptive
        if (!matchedFormat) {
            for (id format in muxedFormats) {
                NSString *quality = extractQualityLabel(format);
                if ([quality containsString:targetRes]) {
                    matchedFormat = format;
                    isMuxed = YES;
                    break;
                }
            }
        }

        if (matchedFormat && ![seenResolutions containsObject:targetRes]) {
            [seenResolutions addObject:targetRes];
            NSString *qualityLabel = extractQualityLabel(matchedFormat) ?: targetRes;
            [videoActions addObject:@{
                @"title": [NSString stringWithFormat:@"📹 Tải Video %@ %@", qualityLabel, ([targetRes isEqualToString:@"1080p"] ? @"(Full HD)" : ([targetRes isEqualToString:@"720p"] ? @"(HD)" : @""))],
                @"format": matchedFormat,
                @"isMuxed": @(isMuxed),
                @"quality": qualityLabel
            }];
        }
    }

    UIViewController *topVC = getTopViewController(nil);
    if (!topVC) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:videoTitle
                                                                   message:@"Chọn chất lượng tải xuống (YouTube Plus)"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Add Video actions
    for (NSDictionary *info in videoActions) {
        id format = info[@"format"];
        BOOL isMuxed = [info[@"isMuxed"] boolValue];
        NSString *quality = info[@"quality"];
        NSString *actionTitle = info[@"title"];

        [sheet addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self downloadVideoFormat:format
                             audioFormat:(isMuxed ? nil : bestAudioStream)
                                   title:videoTitle
                                 quality:quality
                                 isMuxed:isMuxed];
        }]];
    }

    // Add Audio action
    if (bestAudioStream) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"🎵 Tải Âm thanh M4A (Audio HQ)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self downloadAudioFormat:bestAudioStream title:videoTitle];
        }]];
    }

    // Add Thumbnail action
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

    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = sourceView ?: topVC.view;
        sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
    }

    [topVC presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Download Execution

- (void)downloadVideoFormat:(id)videoFormat audioFormat:(id)audioFormat title:(NSString *)title quality:(NSString *)quality isMuxed:(BOOL)isMuxed {
    NSString *videoURLStr = extractStreamURL(videoFormat);
    if (!videoURLStr || videoURLStr.length == 0) {
        showToast(@"Không thể lấy URL luồng video");
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLStr];
    NSString *cleanName = sanitizeFileName(title);
    showToast([NSString stringWithFormat:@"Đang tải: %@ (%@)...", cleanName, quality]);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSString *tmpDir = NSTemporaryDirectory();

    if (isMuxed || !audioFormat) {
        // Direct Muxed download
        NSURL *finalDest = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mp4", cleanName, quality]]];
        [[NSFileManager defaultManager] removeItemAtURL:finalDest error:nil];

        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:videoURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                showToast([NSString stringWithFormat:@"Lỗi tải: %@", error.localizedDescription ?: @"Thất bại"]);
                return;
            }
            NSError *moveErr = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:finalDest error:&moveErr];
            [self finishVideoDownloadAtURL:finalDest];
        }];
        [task resume];
    } else {
        // Parallel Adaptive download (Video + Audio)
        NSString *audioURLStr = extractStreamURL(audioFormat);
        if (!audioURLStr || audioURLStr.length == 0) {
            showToast(@"Không thể lấy URL âm thanh");
            return;
        }
        NSURL *audioURL = [NSURL URLWithString:audioURLStr];

        NSURL *tempVideoFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_temp_v.mp4", [[NSUUID UUID] UUIDString]]]];
        NSURL *tempAudioFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_temp_a.m4a", [[NSUUID UUID] UUIDString]]]];
        NSURL *finalMergedFile = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mp4", cleanName, quality]]];

        dispatch_group_t group = dispatch_group_create();

        __block NSError *vError = nil;
        __block NSError *aError = nil;

        dispatch_group_enter(group);
        NSURLSessionDownloadTask *vTask = [session downloadTaskWithURL:videoURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                vError = error ?: [NSError errorWithDomain:@"YTL" code:-1 userInfo:nil];
            } else {
                [[NSFileManager defaultManager] moveItemAtURL:location toURL:tempVideoFile error:nil];
            }
            dispatch_group_leave(group);
        }];
        [vTask resume];

        dispatch_group_enter(group);
        NSURLSessionDownloadTask *aTask = [session downloadTaskWithURL:audioURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                aError = error ?: [NSError errorWithDomain:@"YTL" code:-1 userInfo:nil];
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
                showToast(@"Tải luồng dữ liệu thất bại");
                return;
            }

            showToast(@"Đang ghép hình ảnh & âm thanh...");
            [self mergeVideoURL:tempVideoFile audioURL:tempAudioFile outputURL:finalMergedFile completion:^(BOOL success, NSError *error) {
                [[NSFileManager defaultManager] removeItemAtURL:tempVideoFile error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:tempAudioFile error:nil];

                if (success) {
                    [self finishVideoDownloadAtURL:finalMergedFile];
                } else {
                    showToast([NSString stringWithFormat:@"Lỗi ghép luồng: %@", error.localizedDescription]);
                }
            }];
        });
    }
}

- (void)downloadAudioFormat:(id)audioFormat title:(NSString *)title {
    NSString *audioURLStr = extractStreamURL(audioFormat);
    if (!audioURLStr || audioURLStr.length == 0) {
        showToast(@"Không thể lấy URL âm thanh");
        return;
    }
    NSURL *audioURL = [NSURL URLWithString:audioURLStr];
    NSString *cleanName = sanitizeFileName(title);
    showToast([NSString stringWithFormat:@"Đang tải âm thanh: %@...", cleanName]);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSString *tmpDir = NSTemporaryDirectory();
    NSURL *destURL = [NSURL fileURLWithPath:[tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", cleanName]]];
    [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];

    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:audioURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            showToast(@"Tải âm thanh thất bại");
            return;
        }
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:destURL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            showToast(@"Tải âm thanh hoàn tất!");
            UIViewController *topVC = getTopViewController(nil);
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[destURL] applicationActivities:nil];
            if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                activity.popoverPresentationController.sourceView = topVC.view;
                activity.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
            }
            [topVC presentViewController:activity animated:YES completion:nil];
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
                showToast(success ? @"Đã lưu ảnh thu nhỏ vào Ảnh!" : @"Lưu ảnh thu nhỏ thất bại");
            }];
        } else {
            showToast(@"Cần cấp quyền truy cập Ảnh");
        }
    }];
}

#pragma mark - Passthrough Muxing

- (void)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(void (^)(BOOL success, NSError *error))completion {
    AVMutableComposition *composition = [AVMutableComposition composition];

    AVURLAsset *videoAsset = [AVURLAsset assetWithURL:videoURL];
    AVURLAsset *audioAsset = [AVURLAsset assetWithURL:audioURL];

    dispatch_group_t group = dispatch_group_create();
    __block AVAssetTrack *videoTrackSource = nil;
    __block AVAssetTrack *audioTrackSource = nil;

    dispatch_group_enter(group);
    [videoAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        NSArray *tracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count > 0) videoTrackSource = tracks.firstObject;
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [audioAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        NSArray *tracks = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count > 0) audioTrackSource = tracks.firstObject;
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!videoTrackSource) {
            if (completion) completion(NO, [NSError errorWithDomain:@"YTLDownload" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Không tìm thấy luồng hình ảnh"}]);
            return;
        }

        NSError *trackErr = nil;
        AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTime duration = videoTrackSource.timeRange.duration;
        [compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:videoTrackSource atTime:kCMTimeZero error:&trackErr];

        if (audioTrackSource) {
            AVMutableCompositionTrack *compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime audioDuration = audioTrackSource.timeRange.duration;
            CMTime insertDuration = CMTimeCompare(duration, audioDuration) < 0 ? duration : audioDuration;
            [compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, insertDuration) ofTrack:audioTrackSource atTime:kCMTimeZero error:nil];
        }

        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
        exportSession.outputURL = outputURL;
        exportSession.outputFileType = AVFileTypeMPEG4;
        exportSession.shouldOptimizeForNetworkUse = YES;

        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                if (completion) completion(YES, nil);
            } else {
                if (completion) completion(NO, exportSession.error);
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
                            showToast(@"Tải xong! Đã lưu video vào ứng dụng Ảnh 🎉");
                        } else {
                            showToast(@"Lưu vào Ảnh thất bại, mở bảng chia sẻ...");
                        }
                        UIViewController *topVC = getTopViewController(nil);
                        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[finalURL] applicationActivities:nil];
                        if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                            activity.popoverPresentationController.sourceView = topVC.view;
                            activity.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
                        }
                        [topVC presentViewController:activity animated:YES completion:nil];
                    });
                }];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showToast(@"Tải xong! Mở bảng chia sẻ...");
                    UIViewController *topVC = getTopViewController(nil);
                    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[finalURL] applicationActivities:nil];
                    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                        activity.popoverPresentationController.sourceView = topVC.view;
                        activity.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
                    }
                    [topVC presentViewController:activity animated:YES completion:nil];
                });
            }
        }];
    });
}

@end
