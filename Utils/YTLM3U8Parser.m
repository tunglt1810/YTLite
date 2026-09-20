#import "YTLM3U8Parser.h"

@implementation YTLM3U8Variant
@end

@implementation YTLM3U8Parser

+ (void)parseMasterPlaylistURL:(NSString *)manifestURL completion:(void (^)(NSArray <YTLM3U8Variant *> * _Nullable variants, NSError * _Nullable error))completion {
    if (!manifestURL || manifestURL.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTLM3U8" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"URL rỗng"}]);
        return;
    }

    NSURL *url = [NSURL URLWithString:manifestURL];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTLM3U8" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"URL không hợp lệ"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"com.google.ios.youtube/21.34.3 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    request.timeoutInterval = 15.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, error ?: [NSError errorWithDomain:@"YTLM3U8" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Không có dữ liệu manifest"}]);
            });
            return;
        }

        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content || content.length == 0) {
            content = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        }

        if (!content || ![content containsString:@"#EXTM3U"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, [NSError errorWithDomain:@"YTLM3U8" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Dữ liệu không phải định dạng M3U8"}]);
            });
            return;
        }

        NSArray <YTLM3U8Variant *> *variants = [self parseM3U8Content:content baseURL:manifestURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(variants, nil);
        });
    }];
    [task resume];
}

+ (NSArray <YTLM3U8Variant *> *)parseM3U8Content:(NSString *)content baseURL:(NSString *)baseURL {
    NSMutableArray <YTLM3U8Variant *> *results = [NSMutableArray array];
    NSArray <NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSRegularExpression *resRegex = [NSRegularExpression regularExpressionWithPattern:@"RESOLUTION=([0-9]+)x([0-9]+)" options:0 error:nil];
    NSRegularExpression *bwRegex = [NSRegularExpression regularExpressionWithPattern:@"BANDWIDTH=([0-9]+)" options:0 error:nil];
    NSRegularExpression *codecRegex = [NSRegularExpression regularExpressionWithPattern:@"CODECS=\"([^\"]+)\"" options:0 error:nil];
    NSRegularExpression *audioGroupRegex = [NSRegularExpression regularExpressionWithPattern:@"AUDIO=\"([^\"]+)\"" options:0 error:nil];

    // Regex bóc tách #EXT-X-MEDIA:TYPE=AUDIO
    NSRegularExpression *mediaGroupRegex = [NSRegularExpression regularExpressionWithPattern:@"GROUP-ID=\"([^\"]+)\"" options:0 error:nil];
    NSRegularExpression *mediaURIRegex = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:nil];
    NSRegularExpression *mediaDefaultRegex = [NSRegularExpression regularExpressionWithPattern:@"DEFAULT=(YES|NO)" options:NSRegularExpressionCaseInsensitive error:nil];

    NSMutableDictionary <NSString *, NSString *> *audioGroupToURL = [NSMutableDictionary dictionary];
    NSString *defaultAudioURL = nil;

    // Bước 1: Quét bóc tách toàn bộ audio streams từ playlist
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#EXT-X-MEDIA:"] && [line containsString:@"TYPE=AUDIO"]) {
            NSString *groupId = nil;
            NSString *uri = nil;
            BOOL isDefault = NO;

            NSTextCheckingResult *gMatch = [mediaGroupRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (gMatch && gMatch.numberOfRanges >= 2) {
                groupId = [line substringWithRange:[gMatch rangeAtIndex:1]];
            }

            NSTextCheckingResult *uMatch = [mediaURIRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (uMatch && uMatch.numberOfRanges >= 2) {
                uri = [line substringWithRange:[uMatch rangeAtIndex:1]];
            }

            NSTextCheckingResult *dMatch = [mediaDefaultRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (dMatch && dMatch.numberOfRanges >= 2) {
                NSString *dStr = [line substringWithRange:[dMatch rangeAtIndex:1]];
                isDefault = [dStr.uppercaseString isEqualToString:@"YES"];
            }

            if (uri && uri.length > 0) {
                if (![uri hasPrefix:@"http://"] && ![uri hasPrefix:@"https://"] && baseURL.length > 0) {
                    NSURL *base = [NSURL URLWithString:baseURL];
                    NSURL *resolved = [NSURL URLWithString:uri relativeToURL:base];
                    uri = resolved.absoluteString ?: uri;
                }

                if (groupId && groupId.length > 0) {
                    if (isDefault || !audioGroupToURL[groupId]) {
                        audioGroupToURL[groupId] = uri;
                    }
                }
                if (isDefault || !defaultAudioURL) {
                    defaultAudioURL = uri;
                }
            }
        }
    }

    NSInteger currentVariantIndex = 0;

    // Bước 2: Quét bóc tách các stream video và liên kết audio tương ứng
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            NSInteger width = 0;
            NSInteger height = 0;
            NSInteger bandwidth = 0;
            NSString *codecs = nil;
            NSString *audioGroup = nil;

            // Resolution
            NSTextCheckingResult *resMatch = [resRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (resMatch && resMatch.numberOfRanges >= 3) {
                width = [[line substringWithRange:[resMatch rangeAtIndex:1]] integerValue];
                height = [[line substringWithRange:[resMatch rangeAtIndex:2]] integerValue];
            }

            // Bandwidth
            NSTextCheckingResult *bwMatch = [bwRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (bwMatch && bwMatch.numberOfRanges >= 2) {
                bandwidth = [[line substringWithRange:[bwMatch rangeAtIndex:1]] integerValue];
            }

            // Codecs
            NSTextCheckingResult *codecMatch = [codecRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (codecMatch && codecMatch.numberOfRanges >= 2) {
                codecs = [line substringWithRange:[codecMatch rangeAtIndex:1]];
            }

            // Audio Group
            NSTextCheckingResult *agMatch = [audioGroupRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (agMatch && agMatch.numberOfRanges >= 2) {
                audioGroup = [line substringWithRange:[agMatch rangeAtIndex:1]];
            }

            // Dòng tiếp theo chứa URL
            NSString *streamURL = nil;
            for (NSUInteger j = i + 1; j < lines.count; j++) {
                NSString *candidate = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (candidate.length > 0 && ![candidate hasPrefix:@"#"]) {
                    streamURL = candidate;
                    i = j;
                    break;
                }
            }

            if (streamURL && streamURL.length > 0) {
                // Xử lý relative URL nếu cần
                if (![streamURL hasPrefix:@"http://"] && ![streamURL hasPrefix:@"https://"] && baseURL.length > 0) {
                    NSURL *base = [NSURL URLWithString:baseURL];
                    NSURL *resolved = [NSURL URLWithString:streamURL relativeToURL:base];
                    streamURL = resolved.absoluteString ?: streamURL;
                }

                YTLM3U8Variant *variant = [[YTLM3U8Variant alloc] init];
                variant.width = width;
                variant.height = height;
                variant.bandwidth = bandwidth;
                variant.codecs = codecs;
                variant.streamURL = streamURL;
                variant.audioURL = (audioGroup && audioGroupToURL[audioGroup]) ? audioGroupToURL[audioGroup] : defaultAudioURL;
                variant.variantIndex = currentVariantIndex++;

                if (height > 0) {
                    variant.quality = [NSString stringWithFormat:@"%ldp", (long)height];
                    variant.resolution = [NSString stringWithFormat:@"%ldx%ld", (long)width, (long)height];
                } else {
                    variant.quality = @"Auto";
                    variant.resolution = @"Default";
                }

                [results addObject:variant];
            }
        }
    }

    // Bước 3: Sắp xếp theo chiều cao (height) giảm dần, ưu tiên codec avc1 (H.264), sau đó theo bandwidth giảm dần
    [results sortUsingComparator:^NSComparisonResult(YTLM3U8Variant *a, YTLM3U8Variant *b) {
        if (a.height > b.height) return NSOrderedAscending;
        if (a.height < b.height) return NSOrderedDescending;

        BOOL aIsAVC = [a.codecs containsString:@"avc1"] || [a.codecs containsString:@"h264"];
        BOOL bIsAVC = [b.codecs containsString:@"avc1"] || [b.codecs containsString:@"h264"];
        if (aIsAVC && !bIsAVC) return NSOrderedAscending;
        if (!aIsAVC && bIsAVC) return NSOrderedDescending;

        if (a.bandwidth > b.bandwidth) return NSOrderedAscending;
        if (a.bandwidth < b.bandwidth) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // Lọc trùng lặp chất lượng (chỉ giữ định dạng tối ưu nhất cho mỗi độ phân giải: 1080p, 720p, 480p, 360p, 240p)
    NSMutableArray <YTLM3U8Variant *> *uniqueResults = [NSMutableArray array];
    NSMutableSet <NSString *> *seenQualities = [NSMutableSet set];
    for (YTLM3U8Variant *v in results) {
        if (![seenQualities containsObject:v.quality]) {
            [seenQualities addObject:v.quality];
            [uniqueResults addObject:v];
        }
    }

    return uniqueResults;
}

@end
