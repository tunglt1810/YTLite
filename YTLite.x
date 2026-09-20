#import "YTLite.h"

static UIImage *YTImageNamed(NSString *imageName) {
    return [UIImage imageNamed:imageName inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil];
}

static __weak YTPlayerViewController *gCurrentPlayerVC = nil;

// YouTube-X (https://github.com/PoomSmart/YouTube-X/)
// Background Playback
%hook YTIPlayabilityStatus
- (BOOL)isPlayableInBackground { return ytlBool(@"backgroundPlayback") ? YES : NO; }
%end

%hook MLVideo
- (BOOL)playableInBackground { return ytlBool(@"backgroundPlayback") ? YES : NO; }
%end

%hook YTColdConfig
- (BOOL)isBackgroundPlaybackEnabled { return ytlBool(@"backgroundPlayback") ? YES : %orig; }
- (BOOL)isBackgroundPlaybackAllowed { return ytlBool(@"backgroundPlayback") ? YES : %orig; }
- (BOOL)enableBackgroundable { return ytlBool(@"backgroundPlayback") ? YES : %orig; }
- (BOOL)mainAppCoreClientEnableCairoSettings { return NO; }
%end

%hook YTPlaybackData
- (BOOL)isPlayableInBackground { return ytlBool(@"backgroundPlayback") ? YES : %orig; }
%end

%hook YTSingleVideoController
- (void)playerStatusDidChange:(id)arg1 {
    %orig;
    if (ytlBool(@"backgroundPlayback")) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    if (ytlBool(@"downloadManager")) {
        @try {
            id pr = nil;
            if ([self respondsToSelector:@selector(playerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [self performSelector:@selector(playerResponse)];
                #pragma clang diagnostic pop
            } else if ([self respondsToSelector:@selector(contentPlayerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [self performSelector:@selector(contentPlayerResponse)];
                #pragma clang diagnostic pop
            }
            if (!pr) pr = [self valueForKey:@"playerResponse"] ?: [self valueForKey:@"contentPlayerResponse"];

            id pd = nil;
            if ([self respondsToSelector:@selector(playbackData)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pd = [self performSelector:@selector(playbackData)];
                #pragma clang diagnostic pop
            } else if ([self respondsToSelector:@selector(videoData)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pd = [self performSelector:@selector(videoData)];
                #pragma clang diagnostic pop
            }
            if (!pd) pd = [self valueForKey:@"playbackData"] ?: [self valueForKey:@"videoData"];

            NSString *vid = nil;
            if ([self respondsToSelector:@selector(videoID)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [self performSelector:@selector(videoID)];
                #pragma clang diagnostic pop
            } else if ([self respondsToSelector:@selector(videoId)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [self performSelector:@selector(videoId)];
                #pragma clang diagnostic pop
            }
            if (!vid) vid = [self valueForKey:@"videoID"] ?: [self valueForKey:@"videoId"];

            id v = nil;
            if ([self respondsToSelector:@selector(singleVideo)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                v = [self performSelector:@selector(singleVideo)];
                #pragma clang diagnostic pop
            }
            if (!v) v = [self valueForKey:@"singleVideo"] ?: [self valueForKey:@"activeVideo"];

            if (pr || pd || vid || v) {
                [[%c(YTLDownloadManager) sharedManager] didActivateVideo:v withPlaybackData:pd videoID:vid playerResponse:pr];
            }
        } @catch (NSException *e) {}
    }
}
%end

// Disable Ads
%hook YTIPlayerResponse
- (BOOL)isMonetized { return ytlBool(@"noAds") ? NO : YES; }
- (id)adPlacements { return ytlBool(@"noAds") ? nil : %orig; }
- (id)playerAds { return ytlBool(@"noAds") ? nil : %orig; }
%end

%hook YTDataUtils
+ (id)spamSignalsDictionary { return ytlBool(@"noAds") ? nil : %orig; }
+ (id)spamSignalsDictionaryWithoutIDFA { return ytlBool(@"noAds") ? nil : %orig; }
%end

%hook YTAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!ytlBool(@"noAds")) %orig; }
%end

%hook YTAccountScopedAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!ytlBool(@"noAds")) %orig; }
%end

static BOOL isAdItemSectionSupportedRenderer(id renderer) {
    if (!renderer) return NO;
    if (([renderer respondsToSelector:@selector(hasPromotedVideoRenderer)] && [renderer hasPromotedVideoRenderer]) ||
        ([renderer respondsToSelector:@selector(hasCompactPromotedVideoRenderer)] && [renderer hasCompactPromotedVideoRenderer]) ||
        ([renderer respondsToSelector:@selector(hasPromotedVideoInlineMutedRenderer)] && [renderer hasPromotedVideoInlineMutedRenderer])) {
        return YES;
    }
    if ([renderer respondsToSelector:@selector(elementRenderer)]) {
        id elementRenderer = [renderer elementRenderer];
        if (elementRenderer) {
            if ([elementRenderer respondsToSelector:@selector(hasCompatibilityOptions)] && [elementRenderer hasCompatibilityOptions]) {
                id compOptions = [elementRenderer respondsToSelector:@selector(compatibilityOptions)] ? [elementRenderer compatibilityOptions] : nil;
                if ([compOptions respondsToSelector:@selector(hasAdLoggingData)] && [compOptions hasAdLoggingData]) {
                    return YES;
                }
            }
            NSString *desc = [elementRenderer description];
            static NSArray *adKeywords = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                adKeywords = @[
                    @"brand_promo", @"product_carousel", @"product_engagement_panel",
                    @"product_item", @"text_search_ad", @"text_image_button_layout",
                    @"carousel_headered_layout", @"carousel_footered_layout", @"square_image_layout",
                    @"landscape_image_wide_button_layout", @"feed_ad_metadata", @"promoted_sparkles",
                    @"statement_banner", @"ad_placement", @"shelf_ad", @"inline_ad",
                    @"banner_ad", @"prime_info", @"ad_layout", @"brand_promo_cell"
                ];
            });
            for (NSString *ad in adKeywords) {
                if ([desc containsString:ad]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static char kYTLItemSectionFilteredKey;

%hook YTIItemSectionRenderer
- (NSMutableArray *)contentsArray {
    NSMutableArray *contents = %orig;
    if (ytlBool(@"noAds") && [contents isKindOfClass:[NSMutableArray class]] && contents.count > 0) {
        if (!objc_getAssociatedObject(self, &kYTLItemSectionFilteredKey)) {
            objc_setAssociatedObject(self, &kYTLItemSectionFilteredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSIndexSet *removeIndexes = [contents indexesOfObjectsPassingTest:^BOOL(id renderer, NSUInteger idx, BOOL *stop) {
                return isAdItemSectionSupportedRenderer(renderer);
            }];
            if (removeIndexes.count > 0) {
                [contents removeObjectsAtIndexes:removeIndexes];
            }
        }
    }
    return contents;
}
%end

%hook YTIElementRenderer
- (NSData *)elementData {
    if (ytlBool(@"noAds")) {
        if ([self respondsToSelector:@selector(hasCompatibilityOptions)] && [self hasCompatibilityOptions]) {
            id compOptions = [self respondsToSelector:@selector(compatibilityOptions)] ? [self compatibilityOptions] : nil;
            if ([compOptions respondsToSelector:@selector(hasAdLoggingData)] && [compOptions hasAdLoggingData]) {
                return nil;
            }
        }
    }

    BOOL hideShorts = ytlBool(@"hideShorts");
    BOOL noAds = ytlBool(@"noAds");

    if (noAds || hideShorts) {
        NSString *description = nil;

        if (noAds) {
            description = [self description];
            static NSArray *ads = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                ads = @[@"brand_promo", @"product_carousel", @"product_engagement_panel", @"product_item", @"text_search_ad", @"text_image_button_layout", @"carousel_headered_layout", @"carousel_footered_layout", @"square_image_layout", @"landscape_image_wide_button_layout", @"feed_ad_metadata", @"promoted_sparkles", @"statement_banner", @"ad_placement", @"shelf_ad", @"inline_ad", @"banner_ad", @"prime_info", @"ad_layout", @"brand_promo_cell"];
            });
            for (NSString *ad in ads) {
                if ([description containsString:ad]) {
                    return nil;
                }
            }
        }

        if (hideShorts) {
            if (!description) description = [self description];
            static NSArray *shortsToRemove = nil;
            static dispatch_once_t shortsToken;
            dispatch_once(&shortsToken, ^{
                shortsToRemove = @[@"shorts_shelf.eml", @"shorts_video_cell.eml", @"6Shorts"];
            });
            for (NSString *shorts in shortsToRemove) {
                if ([description containsString:shorts] && ![description containsString:@"history*"]) {
                    return nil;
                }
            }
        }
    }

    return %orig;
}
%end

%hook YTSectionListViewController
- (void)loadWithModel:(YTISectionListRenderer *)model {
    if (ytlBool(@"noAds")) {
        NSMutableArray <YTISectionListSupportedRenderers *> *contentsArray = model.contentsArray;
        NSIndexSet *removeIndexes = [contentsArray indexesOfObjectsPassingTest:^BOOL(YTISectionListSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
            YTIItemSectionRenderer *sectionRenderer = renderers.itemSectionRenderer;
            if (!sectionRenderer) return NO;
            NSMutableArray *items = sectionRenderer.contentsArray;
            if ([items isKindOfClass:[NSMutableArray class]] && items.count > 0) {
                NSIndexSet *adIndexes = [items indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger i, BOOL *s) {
                    return isAdItemSectionSupportedRenderer(item);
                }];
                if (adIndexes.count > 0) {
                    [items removeObjectsAtIndexes:adIndexes];
                }
            }
            NSString *desc = [sectionRenderer description];
            if ([desc containsString:@"ad_placement"] || [desc containsString:@"Promoted"] || [desc containsString:@"promoted"] || [desc containsString:@"BrandPromo"]) {
                return YES;
            }
            return (items.count == 0);
        }];
        [contentsArray removeObjectsAtIndexes:removeIndexes];
    } %orig;
}
%end

// NOYTPremium (https://github.com/PoomSmart/NoYTPremium)
// Alert
%hook YTCommerceEventGroupHandler
- (void)addEventHandlers {}
%end

// Full-screen
%hook YTInterstitialPromoEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromosheetEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromoThrottleController
- (BOOL)canShowThrottledPromo { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 { return NO; }
%end

%hook YTIShowFullscreenInterstitialCommand
- (BOOL)shouldThrottleInterstitial { return YES; }
%end

// "Try new features" in settings
%hook YTSettingsSectionItemManager
- (void)updatePremiumEarlyAccessSectionWithEntry:(id)arg1 {}
%end

// Survey
%hook YTSurveyController
- (void)showSurveyWithRenderer:(id)arg1 surveyParentResponder:(id)arg2 {}
%end

// Navbar Stuff
// Disable Cast
%hook MDXPlaybackRouteButtonController
- (BOOL)isPersistentCastIconEnabled { return ytlBool(@"noCast") ? NO : YES; }
- (void)updateRouteButton:(id)arg1 { if (!ytlBool(@"noCast")) %orig; }
- (void)updateAllRouteButtons { if (!ytlBool(@"noCast")) %orig; }
%end

%hook YTSettings
- (void)setDisableMDXDeviceDiscovery:(BOOL)arg1 { %orig(ytlBool(@"noCast")); }
%end

// Hide Navigation Bar Buttons
%hook YTRightNavigationButtons
- (void)layoutSubviews {
    %orig;

    if (ytlBool(@"noNotifsButton")) self.notificationButton.hidden = YES;
    if (ytlBool(@"noSearchButton")) self.searchButton.hidden = YES;

    for (UIView *subview in self.subviews) {
        if (ytlBool(@"noVoiceSearchButton") && [subview.accessibilityLabel isEqualToString:NSLocalizedString(@"search.voice.access", nil)]) subview.hidden = YES;
        if (ytlBool(@"noCast") && [subview.accessibilityIdentifier isEqualToString:@"id.mdx.playbackroute.button"]) subview.hidden = YES;
    }
}
%end

%hook YTSearchViewController
- (void)viewDidLoad {
    %orig;

    if (ytlBool(@"noVoiceSearchButton")) [self setValue:@(NO) forKey:@"_isVoiceSearchAllowed"];
}

- (void)setSuggestions:(id)arg1 { if (!ytlBool(@"noSearchHistory")) %orig; }
%end

%hook YTPersonalizedSuggestionsCacheProvider
- (id)activeCache { return ytlBool(@"noSearchHistory") ? nil : %orig; }
%end

// Remove Videos Section Under Player
%hook YTWatchNextResultsViewController
- (void)setVisibleSections:(NSInteger)arg1 {
    arg1 = (ytlBool(@"noRelatedWatchNexts")) ? 1 : arg1;
    %orig(arg1);
}
%end

%hook YTHeaderView
// Stick Navigation bar
- (BOOL)stickyNavHeaderEnabled { return ytlBool(@"stickyNavbar") ? YES : %orig; }

// Hide YouTube Logo
- (void)setCustomTitleView:(UIView *)customTitleView { if (!ytlBool(@"noYTLogo")) %orig; }
- (void)setTitle:(NSString *)title { ytlBool(@"noYTLogo") ? %orig(@"") : %orig; }
%end

// Premium logo
%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (!ytlBool(@"premiumYTLogo")) return %orig;

    NSString *resourcesPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Frameworks/Module_Framework.framework/Innertube_Resources.bundle"];
    NSBundle *frameworkBundle = [NSBundle bundleWithPath:resourcesPath];

    if ([[image description] containsString:@"Resources: youtube_logo)"]) {
        image = [UIImage imageNamed:@"youtube_premium_logo" inBundle:frameworkBundle compatibleWithTraitCollection:nil];
    }

    else if ([[image description] containsString:@"Resources: youtube_logo_dark)"]) {
        image = [UIImage imageNamed:@"youtube_premium_logo_white" inBundle:frameworkBundle compatibleWithTraitCollection:nil];
    }

    %orig(image);
}
%end

// Remove Subbar
%hook YTMySubsFilterHeaderView
- (void)setChipFilterView:(id)arg1 { if (!ytlBool(@"noSubbar")) %orig; }
%end

%hook YTHeaderContentComboView
- (void)enableSubheaderBarWithView:(id)arg1 { if (!ytlBool(@"noSubbar")) %orig; }
- (void)setFeedHeaderScrollMode:(int)arg1 { ytlBool(@"noSubbar") ? %orig(0) : %orig; }
%end

%hook YTChipCloudCell
- (void)layoutSubviews {
    if (self.superview && ytlBool(@"noSubbar")) {
        [self removeFromSuperview];
    } %orig;
}
%end

%hook YTMainAppControlsOverlayView
// Hide Autoplay Switch
- (void)setAutoplaySwitchButtonRenderer:(id)arg1 { if (!ytlBool(@"hideAutoplay")) %orig; }

// Hide Subs Button
- (void)setClosedCaptionsOrSubtitlesButtonAvailable:(BOOL)arg1 { ytlBool(@"hideSubs") ? %orig(NO) : %orig; }

// Pause On Overlay
- (void)setOverlayVisible:(BOOL)visible {
    %orig;

    if (!ytlBool(@"pauseOnOverlay")) return;

    visible ? [self.playerViewController pause] : [self.playerViewController play];
}
%end

// Remove HUD Messages
%hook YTHUDMessageView
- (id)initWithMessage:(id)arg1 dismissHandler:(id)arg2 { return ytlBool(@"noHUDMsgs") ? nil : %orig; }
%end

%hook YTColdConfig
// Hide Next & Previous buttons
- (BOOL)removeNextPaddleForSingletonVideos { return ytlBool(@"hidePrevNext") ? YES : %orig; }
- (BOOL)removePreviousPaddleForSingletonVideos { return ytlBool(@"hidePrevNext") ? YES : %orig; }
// Replace Next & Previous with Fast Forward & Rewind buttons
- (BOOL)replaceNextPaddleWithFastForwardButtonForSingletonVods { return ytlBool(@"replacePrevNext") ? YES : %orig; }
- (BOOL)replacePreviousPaddleWithRewindButtonForSingletonVods { return ytlBool(@"replacePrevNext") ? YES : %orig; }
// Disable Free Zoom
- (BOOL)videoZoomFreeZoomEnabledGlobalConfig { return ytlBool(@"noFreeZoom") ? NO : %orig; }
// Stick Sort Buttons in Comments Section
- (BOOL)enableHideChipsInTheCommentsHeaderOnScrollIos { return ytlBool(@"stickSortComments") ? NO : %orig; }
// Hide Sort Buttons in Comments Section
- (BOOL)enableChipsInTheCommentsHeaderIos { return ytlBool(@"hideSortComments") ? NO : %orig; }
// Use System Theme
- (BOOL)shouldUseAppThemeSetting { return YES; }
// Dismiss Panel By Swiping in Fullscreen Mode
- (BOOL)isLandscapeEngagementPanelSwipeRightToDismissEnabled { return YES; }
// Remove Video in Playlist By Swiping To The Right
- (BOOL)enableSwipeToRemoveInPlaylistWatchEp { return YES; }
// Enable Old-style Minibar For Playlist Panel
- (BOOL)queueClientGlobalConfigEnableFloatingPlaylistMinibar { return ytlBool(@"playlistOldMinibar") ? NO : %orig; }
%end

// Remove Dark Background in Overlay
%hook YTMainAppVideoPlayerOverlayView
- (void)setBackgroundVisible:(BOOL)arg1 isGradientBackground:(BOOL)arg2 { ytlBool(@"noDarkBg") ? %orig(NO, arg2) : %orig; }
%end

// No Endscreen Cards
%hook YTCreatorEndscreenView
- (void)setHidden:(BOOL)arg1 { ytlBool(@"endScreenCards") ? %orig(YES) : %orig; }
%end

// Disable Fullscreen Actions
%hook YTFullscreenActionsView
- (BOOL)enabled { return ytlBool(@"noFullscreenActions") ? NO : YES; }
- (void)setEnabled:(BOOL)arg1 { ytlBool(@"noFullscreenActions") ? %orig(NO) : %orig; }
%end

// Dont Show Related Videos on Finish
%hook YTFullscreenEngagementOverlayController
- (void)setRelatedVideosVisible:(BOOL)arg1 { ytlBool(@"noRelatedVids") ? %orig(NO) : %orig; }
%end

// Hide Paid Promotion Cards
%hook YTMainAppVideoPlayerOverlayViewController
- (void)setPaidContentWithPlayerData:(id)data { if (!ytlBool(@"noPromotionCards")) %orig; }
- (void)playerOverlayProvider:(YTPlayerOverlayProvider *)provider didInsertPlayerOverlay:(YTPlayerOverlay *)overlay {
    if ([[overlay overlayIdentifier] isEqualToString:@"player_overlay_paid_content"] && ytlBool(@"noPromotionCards")) return;
    %orig;
}
%end

%hook YTInlineMutedPlaybackPlayerOverlayViewController
- (void)setPaidContentWithPlayerData:(id)data { if (!ytlBool(@"noPromotionCards")) %orig; }
%end

%hook YTInlinePlayerBarContainerView
- (void)setPlayerBarAlpha:(CGFloat)alpha { ytlBool(@"persistentProgressBar") ? %orig(1.0) : %orig; }
%end

// Remove Watermarks
%hook YTAnnotationsViewController
- (void)loadFeaturedChannelWatermark { if (!ytlBool(@"noWatermarks")) %orig; }
%end

%hook YTMainAppVideoPlayerOverlayView
- (BOOL)isWatermarkEnabled { return ytlBool(@"noWatermarks") ? NO : %orig; }
%end

// Forcibly Enable Miniplayer
%hook YTWatchMiniBarViewController
- (void)updateMiniBarPlayerStateFromRenderer { if (!ytlBool(@"miniplayer")) %orig; }
%end

// Portrait Fullscreen
%hook YTWatchViewController
- (unsigned long long)allowedFullScreenOrientations { return ytlBool(@"portraitFullscreen") ? UIInterfaceOrientationMaskAllButUpsideDown : %orig; }
%end

// Disable Autoplay
%hook YTPlaybackConfig
- (void)setStartPlayback:(BOOL)arg1 { ytlBool(@"disableAutoplay") ? %orig(NO) : %orig; }
%end

// Skip Content Warning (https://github.com/qnblackcat/uYouPlus/blob/main/uYouPlus.xm#L452-L454)
%hook YTPlayabilityResolutionUserActionUIController
- (void)showConfirmAlert { ytlBool(@"noContentWarning") ? [self confirmAlertDidPressConfirm] : %orig; }
%end

// Classic Video Quality (https://github.com/PoomSmart/YTClassicVideoQuality)
%hook YTVideoQualitySwitchControllerFactory
- (id)videoQualitySwitchControllerWithParentResponder:(id)responder {
    Class originalClass = %c(YTVideoQualitySwitchOriginalController);
    return ytlBool(@"classicQuality") && originalClass ? [[originalClass alloc] initWithParentResponder:responder] : %orig;
}
%end

// Extra Speed Options
%hook YTVarispeedSwitchController
- (void)setDelegate:(id)arg1 {
    NSMutableArray *optionsCopy = [[self valueForKey:@"_options"] mutableCopy];
    NSArray *speedOptions = @[@"2.5", @"3", @"3.5", @"4", @"5"];

    for (NSString *title in speedOptions) {
        float rate = [title floatValue];
        YTVarispeedSwitchControllerOption *option = [[%c(YTVarispeedSwitchControllerOption) alloc] initWithTitle:title rate:rate];
        [optionsCopy addObject:option];
    }

    if (ytlBool(@"extraSpeedOptions")) [self setValue:[optionsCopy copy] forKey:@"_options"];

    return %orig;
}
%end

// Temprorary Fix For 'Classic Video Quality' and 'Extra Speed Options'
%hook YTVersionUtils
+ (NSString *)appVersion {
    NSString *originalVersion = %orig;
    NSString *fakeVersion = @"18.18.2";

    return (!ytlBool(@"classicQuality") && !ytlBool(@"extraSpeedOptions") && [originalVersion compare:fakeVersion options:NSNumericSearch] == NSOrderedDescending) ? originalVersion : fakeVersion;
}
%end

// Show real version in YT Settings
%hook YTSettingsCell
- (void)setDetailText:(id)arg1 {
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *appVersion = infoDictionary[@"CFBundleShortVersionString"];

    if ([arg1 isEqualToString:@"18.18.2"]) {
        arg1 = appVersion;
    } %orig(arg1);
}
%end

// Disable Snap To Chapter (https://github.com/qnblackcat/uYouPlus/blob/main/uYouPlus.xm#L457-464)
%hook YTSegmentableInlinePlayerBarView
- (void)didMoveToWindow { %orig; if (ytlBool(@"dontSnapToChapter")) self.enableSnapToChapter = NO; }
%end

// Red Progress Bar and Gray Buffer Progress
%hook YTInlinePlayerBarContainerView
- (id)quietProgressBarColor { return ytlBool(@"redProgressBar") ? [UIColor redColor] : %orig; }
%end

%hook YTSegmentableInlinePlayerBarView
- (void)setBufferedProgressBarColor:(id)arg1 { if (ytlBool(@"redProgressBar")) %orig([UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:0.60]); }
%end

// Disable Hints
%hook YTSettings
- (BOOL)areHintsDisabled { return ytlBool(@"noHints") ? YES : NO; }
- (void)setHintsDisabled:(BOOL)arg1 { ytlBool(@"noHints") ? %orig(YES) : %orig; }
%end

%hook YTUserDefaults
- (BOOL)areHintsDisabled { return ytlBool(@"noHints") ? YES : NO; }
- (void)setHintsDisabled:(BOOL)arg1 { ytlBool(@"noHints") ? %orig(YES) : %orig; }
%end

void addEndTime(YTPlayerViewController *self, YTSingleVideoController *video, YTSingleVideoTime *time) {
    if (!ytlBool(@"videoEndTime")) return;

    CGFloat rate = video.playbackRate != 0 ? video.playbackRate : 1.0;
    NSTimeInterval remainingTime = (lround(video.totalMediaTime) - lround(time.time)) / rate;

    NSDate *estimatedEndTime = [NSDate dateWithTimeIntervalSinceNow:remainingTime];

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [dateFormatter setDateFormat:ytlBool(@"24hrFormat") ? @"HH:mm" : @"h:mm a"];

    NSString *formattedEndTime = [dateFormatter stringFromDate:estimatedEndTime];

    YTPlayerView *playerView = (YTPlayerView *)self.view;
    if (![playerView.overlayView isKindOfClass:%c(YTMainAppVideoPlayerOverlayView)]) return;

    YTMainAppVideoPlayerOverlayView *overlay = (YTMainAppVideoPlayerOverlayView*)playerView.overlayView;
    YTLabel *durationLabel = overlay.playerBar.durationLabel;
    overlay.playerBar.endTimeString = formattedEndTime;

    if (![durationLabel.text containsString:formattedEndTime]) {
        durationLabel.text = [durationLabel.text stringByAppendingString:[NSString stringWithFormat:@" • %@", formattedEndTime]];
        [durationLabel sizeToFit];
    }
}

void autoSkipShorts(YTPlayerViewController *self, YTSingleVideoController *video, YTSingleVideoTime *time) {
    if (!ytlBool(@"autoSkipShorts")) return;

    if (floor(time.time) >= floor(video.totalMediaTime)) {
        if ([self.parentViewController isKindOfClass:%c(YTShortsPlayerViewController)]) {
            YTShortsPlayerViewController *shortsVC = (YTShortsPlayerViewController *)self.parentViewController;

            if ([shortsVC respondsToSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)]) {
                [shortsVC performSelector:@selector(reelContentViewRequestsAdvanceToNextVideo:)];
            }
        }
    }
}

%hook YTPlayerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gCurrentPlayerVC = self;
    [[%c(YTLDownloadManager) sharedManager] setActivePlayerViewController:self];
    id v = nil;
    @try { v = [self valueForKey:@"activeVideo"]; } @catch (NSException *e) {}
    if (v) [[%c(YTLDownloadManager) sharedManager] setActiveVideo:v];
}

- (void)loadWithPlayerTransition:(id)arg1 playbackConfig:(id)arg2 {
    %orig;
    gCurrentPlayerVC = self;
    [[%c(YTLDownloadManager) sharedManager] setActivePlayerViewController:self];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id v = nil;
        @try { v = [self valueForKey:@"activeVideo"]; } @catch (NSException *e) {}
        if (v) [[%c(YTLDownloadManager) sharedManager] setActiveVideo:v];
    });

    if (ytlInt(@"wiFiQualityIndex") != 0 || ytlInt(@"cellQualityIndex") != 0) [self performSelector:@selector(autoQuality) withObject:nil afterDelay:1.0];
    if (ytlBool(@"autoFullscreen")) [self performSelector:@selector(autoFullscreen) withObject:nil afterDelay:0.75];
    if (ytlBool(@"shortsToRegular")) [self performSelector:@selector(shortsToRegular) withObject:nil afterDelay:0.75];
    if (ytlInt(@"autoSpeedIndex") != 3) [self performSelector:@selector(setAutoSpeed) withObject:nil afterDelay:0.75];
    if (ytlBool(@"disableAutoCaptions")) [self performSelector:@selector(turnOffCaptions) withObject:nil afterDelay:1.0];
}

- (void)setCurrentVideo:(id)arg1 {
    %orig;
    gCurrentPlayerVC = self;
    [[%c(YTLDownloadManager) sharedManager] setActivePlayerViewController:self];
    if (arg1) [[%c(YTLDownloadManager) sharedManager] setActiveVideo:arg1];
}

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    gCurrentPlayerVC = self;
    [[%c(YTLDownloadManager) sharedManager] setActivePlayerViewController:self];
    NSString *vid = nil;
    if ([self respondsToSelector:@selector(contentVideoID)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        vid = [self performSelector:@selector(contentVideoID)];
        #pragma clang diagnostic pop
    }
    if (!vid && [self respondsToSelector:@selector(currentVideoID)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        vid = [self performSelector:@selector(currentVideoID)];
        #pragma clang diagnostic pop
    }
    id pr = nil;
    if ([self respondsToSelector:@selector(contentPlayerResponse)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        pr = [self performSelector:@selector(contentPlayerResponse)];
        #pragma clang diagnostic pop
    }
    if (!pr && [self respondsToSelector:@selector(playerResponse)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        pr = [self performSelector:@selector(playerResponse)];
        #pragma clang diagnostic pop
    }
    if ([[%c(YTLDownloadManager) sharedManager] respondsToSelector:@selector(didActivateVideo:withPlaybackData:videoID:playerResponse:)]) {
        [[%c(YTLDownloadManager) sharedManager] didActivateVideo:video withPlaybackData:playbackData videoID:vid playerResponse:pr];
    } else {
        [[%c(YTLDownloadManager) sharedManager] didActivateVideoWithPlaybackData:playbackData videoID:vid playerResponse:pr];
    }
}

- (void)playbackControllerDidActivateVideo:(id)video withPlayerResponse:(id)playerResponse {
    %orig;
    gCurrentPlayerVC = self;
    [[%c(YTLDownloadManager) sharedManager] setActivePlayerViewController:self];
    NSString *vid = nil;
    if ([self respondsToSelector:@selector(contentVideoID)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        vid = [self performSelector:@selector(contentVideoID)];
        #pragma clang diagnostic pop
    }
    if (!vid && [self respondsToSelector:@selector(currentVideoID)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        vid = [self performSelector:@selector(currentVideoID)];
        #pragma clang diagnostic pop
    }
    if ([[%c(YTLDownloadManager) sharedManager] respondsToSelector:@selector(didActivateVideo:withPlaybackData:videoID:playerResponse:)]) {
        [[%c(YTLDownloadManager) sharedManager] didActivateVideo:video withPlaybackData:nil videoID:vid playerResponse:playerResponse];
    } else {
        [[%c(YTLDownloadManager) sharedManager] didActivateVideoWithPlaybackData:nil videoID:vid playerResponse:playerResponse];
    }
}

%new
- (void)autoFullscreen {
    YTWatchController *watchController = [self valueForKey:@"_UIDelegate"];
    [watchController showFullScreen];
}

%new
- (void)shortsToRegular {
    if (self.contentVideoID != nil && [self.parentViewController isKindOfClass:NSClassFromString(@"YTShortsPlayerViewController")]) {
        NSString *vidLink = [NSString stringWithFormat:@"vnd.youtube://%@", self.contentVideoID];
        if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:vidLink]]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:vidLink] options:@{} completionHandler:nil];
        }
    }
}

%new
- (void)turnOffCaptions {
    if ([self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        [self setActiveCaptionTrack:nil];
    }
}

%new
- (void)setAutoSpeed {
    if ([self.activeVideoPlayerOverlay isKindOfClass:NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController")]
        && [self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        YTMainAppVideoPlayerOverlayViewController *overlayVC = (YTMainAppVideoPlayerOverlayViewController *)self.activeVideoPlayerOverlay;

        NSArray *speedLabels = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];
        [overlayVC setPlaybackRate:[speedLabels[ytlInt(@"autoSpeedIndex")] floatValue]];
    }
}

%new
- (void)autoQuality {
    if (![self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        return;
    }

    NetworkStatus status = [[Reachability reachabilityForInternetConnection] currentReachabilityStatus];
    NSInteger kQualityIndex = status == ReachableViaWiFi ? ytlInt(@"wiFiQualityIndex") : ytlInt(@"cellQualityIndex");

    NSString *bestQualityLabel;
    int highestResolution = 0;
    for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
        int reso = format.singleDimensionResolution;
        if (reso > highestResolution) {
            highestResolution = reso;
            bestQualityLabel = format.qualityLabel;
        }
    }

    NSArray *qualityLabels = @[@"Default", bestQualityLabel, @"2160p60", @"2160p", @"1440p60", @"1440p", @"1080p60", @"1080p", @"720p60", @"720p", @"480p", @"360p"];
    NSString *qualityLabel = qualityLabels[kQualityIndex];

    if (![qualityLabel isEqualToString:bestQualityLabel]) {
        BOOL exactMatch = NO;
        NSString *closestQualityLabel = qualityLabel;

        for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
            if ([format.qualityLabel isEqualToString:qualityLabel]) {
                exactMatch = YES;
                break;
            }
        }

        if (!exactMatch) {
            NSInteger bestQualityDifference = NSIntegerMax;

            for (MLFormat *format in self.activeVideo.selectableVideoFormats) {
                NSArray *formatСomponents = [format.qualityLabel componentsSeparatedByString:@"p"];
                NSArray *targetComponents = [qualityLabel componentsSeparatedByString:@"p"];
                if (formatСomponents.count == 2) {
                    NSInteger formatQuality = [formatСomponents.firstObject integerValue];
                    NSInteger targetQuality = [targetComponents.firstObject integerValue];
                    NSInteger difference = labs(formatQuality - targetQuality);
                    if (difference < bestQualityDifference) {
                        bestQualityDifference = difference;
                        closestQualityLabel = format.qualityLabel;
                    }
                }
            }

            qualityLabel = closestQualityLabel;
        }
    }

    MLQuickMenuVideoQualitySettingFormatConstraint *fc = [[%c(MLQuickMenuVideoQualitySettingFormatConstraint) alloc] init];
    if ([fc respondsToSelector:@selector(initWithVideoQualitySetting:formatSelectionReason:qualityLabel:)]) {
        [self.activeVideo setVideoFormatConstraint:[fc initWithVideoQualitySetting:3 formatSelectionReason:2 qualityLabel:qualityLabel]];
    }
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;

    addEndTime(self, video, time);
    autoSkipShorts(self, video, time);
}

- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;

    addEndTime(self, video, time);
    autoSkipShorts(self, video, time);
}
%end

%hook YTInlinePlayerBarContainerView
%property (nonatomic, strong) NSString *endTimeString;
- (void)setPeekableViewVisible:(BOOL)visible {
    %orig;

    if (!ytlBool(@"videoEndTime")) return;

    if (self.endTimeString && ![self.durationLabel.text containsString:self.endTimeString]) {
        self.durationLabel.text = [self.durationLabel.text stringByAppendingString:[NSString stringWithFormat:@" • %@", self.endTimeString]];
        [self.durationLabel sizeToFit];
    }
}
%end

// Exit Fullscreen on Finish
%hook YTWatchFlowController
- (BOOL)shouldExitFullScreenOnFinish { return ytlBool(@"exitFullscreen") ? YES : NO; }
%end

%hook YTMainAppVideoPlayerOverlayViewController
// Disable Double Tap To Seek
- (BOOL)allowDoubleTapToSeekGestureRecognizer { return ytlBool(@"noDoubleTapToSeek") ? NO : %orig; }

// Disable Two Finger Double Tap
- (BOOL)allowTwoFingerDoubleTapGestureRecognizer { return ytlBool(@"noTwoFingerSnapToChapter") ? NO : %orig; }

// Copy Timestamped Link by Pressing On Pause
- (void)didPressPause:(id)arg1 {
    %orig;

    if (ytlBool(@"copyWithTimestamp")) {
        NSInteger mediaTimeInteger = (NSInteger)self.mediaTime;
        NSString *currentTimeLink = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&t=%lds", self.videoID, mediaTimeInteger];

        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = currentTimeLink;
    }
}
%end

// Fit 'Play All' Buttons Text For Localizations
%hook YTQTMButton
- (UILabel *)titleLabel {
    UILabel *label = %orig;

    if ([self.accessibilityIdentifier isEqualToString:@"id.playlist.playall.button"]) {
        label.adjustsFontSizeToFitWidth = YES;
    }

    return label;
}

- (void)layoutSubviews {
    %orig;

    BOOL isDlBtn = [objc_getAssociatedObject(self, "ytl_is_download_button") boolValue];
    if (!isDlBtn) {
        NSString *t = self.currentTitle ?: self.titleLabel.text;
        if (t && ([t isEqualToString:LOC(@"DownloadVideo")] || [t isEqualToString:@"Download video"] || [t isEqualToString:@"Tải video"] || [t isEqualToString:@"Tải xuống video"])) {
            isDlBtn = YES;
        }
    }

    if (isDlBtn) {
        UIButton *sample = objc_getAssociatedObject(self, "ytl_sample_button");
        if (!sample && self.superview) {
            for (UIView *sub in self.superview.subviews) {
                if ([sub isKindOfClass:[UIButton class]] && sub != self) {
                    UIButton *other = (UIButton *)sub;
                    if (other.titleLabel && other.titleLabel.frame.origin.x > 0) {
                        sample = other;
                        break;
                    }
                }
            }
        }
        if (sample) {
            if (sample.imageView && self.imageView && sample.imageView.frame.origin.x > 0) {
                CGRect imgF = self.imageView.frame;
                if (fabs(imgF.origin.x - sample.imageView.frame.origin.x) > 0.5) {
                    imgF.origin.x = sample.imageView.frame.origin.x;
                    self.imageView.frame = imgF;
                }
            }
            if (sample.titleLabel && self.titleLabel && sample.titleLabel.frame.origin.x > 0) {
                CGFloat targetX = sample.titleLabel.frame.origin.x;
                CGRect f = self.titleLabel.frame;
                if (fabs(f.origin.x - targetX) > 0.5) {
                    f.origin.x = targetX;
                    self.titleLabel.frame = f;
                }
            }
        }
    }
}
%end

// Fit Shorts Button Labels For Localizations
%hook YTReelPlayerButton
- (UILabel *)titleLabel {
    UILabel *label = %orig;
    label.adjustsFontSizeToFitWidth = YES;

    return label;
}
%end

// Fix Playlist Mini-bar Height For Small Screens
%hook YTPlaylistMiniBarView
- (void)setFrame:(CGRect)frame {
    if (frame.size.height < 54.0) frame.size.height = 54.0;
    %orig(frame);
}
%end

// Remove "Play next in queue" from the menu @PoomSmart (https://github.com/qnblackcat/uYouPlus/issues/1138#issuecomment-1606415080)
%hook YTMenuItemVisibilityHandler
- (BOOL)shouldShowServiceItemRenderer:(YTIMenuConditionalServiceItemRenderer *)renderer {
    if (ytlBool(@"removePlayNext") && renderer.icon.iconType == 251) {
        return NO;
    } return %orig;
}
%end

static UIImage *gCachedDownloadIcon = nil;

static UIImage *normalizeIcon24(UIImage *img) {
    if (!img) return nil;
    CGSize targetSize = CGSizeMake(24.0, 24.0);
    if (CGSizeEqualToSize(img.size, targetSize)) {
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = img.scale > 0 ? img.scale : [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    UIImage *normalized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat w = img.size.width;
        CGFloat h = img.size.height;
        if (w <= 0 || h <= 0) return;
        CGFloat scale = MIN(24.0 / w, 24.0 / h);
        if (scale > 1.0) scale = 1.0;
        CGFloat drawW = w * scale;
        CGFloat drawH = h * scale;
        CGFloat x = (24.0 - drawW) / 2.0;
        CGFloat y = (24.0 - drawH) / 2.0;
        [img drawInRect:CGRectMake(x, y, drawW, drawH)];
    }];
    return [normalized imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}


static NSString *extractStringFromTitle(id titleObj) {
    if (!titleObj) return nil;
    if ([titleObj isKindOfClass:[NSString class]]) return (NSString *)titleObj;
    if ([titleObj isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)titleObj string];
    if ([titleObj respondsToSelector:@selector(stringWithFormattingRemoved)]) {
        @try {
            NSString *s = [titleObj performSelector:@selector(stringWithFormattingRemoved)];
            if ([s isKindOfClass:[NSString class]] && s.length > 0) return s;
        } @catch (NSException *e) {}
    }
    if ([titleObj respondsToSelector:@selector(runsArray)]) {
        @try {
            id runs = [titleObj performSelector:@selector(runsArray)];
            if ([runs isKindOfClass:[NSArray class]]) {
                NSMutableString *combined = [NSMutableString string];
                for (id run in runs) {
                    id text = [run valueForKey:@"text"];
                    if ([text isKindOfClass:[NSString class]]) [combined appendString:text];
                }
                if (combined.length > 0) return combined;
            }
        } @catch (NSException *e) {}
    }
    if ([titleObj respondsToSelector:@selector(string)]) {
        @try {
            NSString *s = [titleObj performSelector:@selector(string)];
            if ([s isKindOfClass:[NSString class]]) return s;
        } @catch (NSException *e) {}
    }
    if ([titleObj respondsToSelector:@selector(simpleText)]) {
        @try {
            NSString *s = [titleObj performSelector:@selector(simpleText)];
            if ([s isKindOfClass:[NSString class]]) return s;
        } @catch (NSException *e) {}
    }
    @try {
        NSString *s = [titleObj description];
        if ([s isKindOfClass:[NSString class]] && ![s hasPrefix:@"<"]) return s;
    } @catch (NSException *e) {}
    return nil;
}

static UIButton *getActionButton(id action) {
    if (!action) return nil;
    if ([action respondsToSelector:@selector(button)]) {
        @try {
            id btn = [action performSelector:@selector(button)];
            if ([btn isKindOfClass:[UIButton class]]) return (UIButton *)btn;
        } @catch (NSException *e) {}
    }
    @try {
        id btn = [action valueForKey:@"button"] ?: [action valueForKey:@"_button"];
        if ([btn isKindOfClass:[UIButton class]]) return (UIButton *)btn;
    } @catch (NSException *e) {}
    return nil;
}

static NSString *getActionIdentifier(id action) {
    if (!action) return nil;
    if ([action respondsToSelector:@selector(accessibilityIdentifier)]) {
        @try {
            id ident = [action performSelector:@selector(accessibilityIdentifier)];
            if ([ident isKindOfClass:[NSString class]]) return (NSString *)ident;
            if (ident) return [ident description];
        } @catch (NSException *e) {}
    }
    @try {
        id ident = [action valueForKey:@"_accessibilityIdentifier"] ?: [action valueForKey:@"accessibilityIdentifier"];
        if ([ident isKindOfClass:[NSString class]]) return (NSString *)ident;
        if (ident) return [ident description];
    } @catch (NSException *e) {}
    UIButton *btn = getActionButton(action);
    if (btn && btn.accessibilityIdentifier) return btn.accessibilityIdentifier;
    return nil;
}

static BOOL isDownloadKeyword(NSString *str) {
    if (!str || str.length == 0) return NO;
    NSString *folded = [[str stringByFoldingWithOptions:kCFCompareCaseInsensitive | kCFCompareDiacriticInsensitive locale:[NSLocale currentLocale]] lowercaseString];
    if ([folded containsString:@"download"] ||
        [folded containsString:@"tai xuong"] ||
        [folded containsString:@"tai video"] ||
        [folded containsString:@"offline"] ||
        [folded containsString:@"ngoai tuyen"] ||
        [folded containsString:@"descargar"] ||
        [folded containsString:@"telecharger"] ||
        [folded containsString:@"herunterladen"] ||
        [folded containsString:@"scarica"] ||
        [folded containsString:@"скачать"] ||
        [folded containsString:@"다운로드"] ||
        [folded containsString:@"ダウンロード"] ||
        [folded containsString:@"下载"] ||
        [folded containsString:@"下載"] ||
        [folded containsString:@"unduh"] ||
        [folded containsString:@"indir"]) {
        return YES;
    }
    return NO;
}

static void extractAllStringsFromButton(UIButton *btn, NSMutableArray<NSString *> *outStrings) {
    if (!btn || ![btn isKindOfClass:[UIButton class]]) return;
    if (btn.currentTitle.length > 0) [outStrings addObject:btn.currentTitle];
    if (btn.currentAttributedTitle.string.length > 0) [outStrings addObject:btn.currentAttributedTitle.string];

    UIControlState states[] = {UIControlStateNormal, UIControlStateHighlighted, UIControlStateDisabled, UIControlStateSelected};
    for (int i = 0; i < 4; i++) {
        @try {
            NSString *t = [btn titleForState:states[i]];
            if (t.length > 0) [outStrings addObject:t];
            NSAttributedString *at = [btn attributedTitleForState:states[i]];
            if (at.string.length > 0) [outStrings addObject:at.string];
        } @catch (NSException *e) {}
    }
    @try {
        if (btn.titleLabel.text.length > 0) [outStrings addObject:btn.titleLabel.text];
        if (btn.titleLabel.attributedText.string.length > 0) [outStrings addObject:btn.titleLabel.attributedText.string];
    } @catch (NSException *e) {}
    if (btn.accessibilityLabel.length > 0) [outStrings addObject:btn.accessibilityLabel];
    if (btn.accessibilityIdentifier.length > 0) [outStrings addObject:btn.accessibilityIdentifier];

    for (UIView *sub in btn.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)sub;
            if (lbl.text.length > 0) [outStrings addObject:lbl.text];
            if (lbl.attributedText.string.length > 0) [outStrings addObject:lbl.attributedText.string];
        }
    }
}

static void extractAllStringsFromAction(id action, NSMutableArray<NSString *> *outStrings) {
    if (!action) return;

    @try {
        id ident = [action valueForKey:@"_accessibilityIdentifier"] ?: [action valueForKey:@"accessibilityIdentifier"];
        if (ident) [outStrings addObject:[ident description]];
    } @catch (NSException *e) {}
    @try {
        id lbl = [action valueForKey:@"_accessibilityLabel"] ?: [action valueForKey:@"accessibilityLabel"];
        if (lbl) [outStrings addObject:[lbl description]];
    } @catch (NSException *e) {}

    NSArray *selectors = @[@"title", @"text", @"accessibilityLabel", @"accessibilityIdentifier", @"actionTitle"];
    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([action respondsToSelector:sel]) {
            @try {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id val = [action performSelector:sel];
                #pragma clang diagnostic pop
                if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) [outStrings addObject:(NSString *)val];
                else if ([val isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)val string].length > 0) [outStrings addObject:[(NSAttributedString *)val string]];
                else {
                    NSString *s = extractStringFromTitle(val);
                    if (s.length > 0) [outStrings addObject:s];
                }
            } @catch (NSException *e) {}
        }
    }

    NSArray *keys = @[@"title", @"_title", @"text", @"_text", @"titleText", @"_titleText", @"formattedTitle", @"_formattedTitle"];
    for (NSString *key in keys) {
        @try {
            id val = [action valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) [outStrings addObject:(NSString *)val];
            else if ([val isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)val string].length > 0) [outStrings addObject:[(NSAttributedString *)val string]];
            else if (val) {
                NSString *s = extractStringFromTitle(val);
                if (s.length > 0) [outStrings addObject:s];
            }
        } @catch (NSException *e) {}
    }

    UIButton *btn = getActionButton(action);
    if (btn) {
        extractAllStringsFromButton(btn, outStrings);
    }

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([action class], &count);
    if (ivars) {
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                @try {
                    id val = object_getIvar(action, ivars[i]);
                    if (val) {
                        if ([val isKindOfClass:[NSString class]]) {
                            if ([(NSString *)val length] > 0) [outStrings addObject:(NSString *)val];
                        } else if ([val isKindOfClass:[NSAttributedString class]]) {
                            if ([(NSAttributedString *)val string].length > 0) [outStrings addObject:[(NSAttributedString *)val string]];
                        } else if ([val isKindOfClass:[UIButton class]]) {
                            extractAllStringsFromButton((UIButton *)val, outStrings);
                        } else {
                            NSString *s = extractStringFromTitle(val);
                            if (s.length > 0) [outStrings addObject:s];
                            NSString *desc = [val description];
                            if (desc.length > 0 && desc.length < 500 && ![desc hasPrefix:@"<"]) {
                                [outStrings addObject:desc];
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
        free(ivars);
    }

    @try {
        NSString *desc = [action description];
        if (desc.length > 0 && desc.length < 500) [outStrings addObject:desc];
    } @catch (NSException *e) {}
}

static BOOL isDownloadAction(YTActionSheetAction *action) {
    if (!action) return NO;
    if ([objc_getAssociatedObject(action, "ytl_is_safe_download") boolValue]) return NO;

    NSString *ident = getActionIdentifier(action);
    if ([ident isEqualToString:@"7"]) return YES;

    NSMutableArray<NSString *> *allStrings = [NSMutableArray array];
    extractAllStringsFromAction(action, allStrings);

    for (NSString *str in allStrings) {
        if (![str isKindOfClass:[NSString class]] || str.length == 0) continue;
        NSString *lower = [str lowercaseString];
        if ([lower isEqualToString:@"7"] ||
            [lower containsString:@"download"] ||
            [lower containsString:@"offline"] ||
            [lower containsString:@"add_to_offline"] ||
            [lower containsString:@"add_to.offline"] ||
            [lower containsString:@"add.to.offline"] ||
            isDownloadKeyword(str)) {
            return YES;
        }
    }

    UIImage *icon = nil;
    @try { icon = [action valueForKey:@"iconImage"] ?: [action valueForKey:@"_iconImage"]; } @catch (NSException *e) {}
    UIButton *btn = getActionButton(action);
    if (!icon && btn) icon = [btn imageForState:UIControlStateNormal] ?: btn.currentImage ?: btn.imageView.image;
    if (icon && icon.accessibilityIdentifier) {
        NSString *iconIdent = [icon.accessibilityIdentifier lowercaseString];
        if ([iconIdent containsString:@"download"] || [iconIdent containsString:@"offline"]) return YES;
    }

    // Check endpoint/command object — nút download gốc luôn chứa offlineVideoEndpoint
    @try {
        id ep = [action valueForKey:@"serviceEndpoint"] ?: [action valueForKey:@"_serviceEndpoint"] ?: [action valueForKey:@"command"] ?: [action valueForKey:@"_command"];
        if (ep) {
            id dlEp = nil;
            @try { dlEp = [ep valueForKey:@"offlineVideoEndpoint"]; } @catch (NSException *e) {}
            if (!dlEp) @try { dlEp = [ep valueForKey:@"downloadVideoEndpoint"]; } @catch (NSException *e) {}
            if (dlEp) return YES;

            NSString *epClass = NSStringFromClass([ep class]);
            if ([epClass containsString:@"Offline"] || [epClass containsString:@"Download"]) return YES;
        }
    } @catch (NSException *e) {}

    return NO;
}


%hook YTDefaultSheetController
- (void)setActions:(NSMutableArray *)actions {
    if ([actions isKindOfClass:[NSArray class]] && ytlBool(@"removeDownloadMenu")) {
        NSMutableArray *filtered = [actions mutableCopy];
        BOOL removed = NO;
        for (NSInteger i = (NSInteger)filtered.count - 1; i >= 0; i--) {
            id act = filtered[i];
            if (isDownloadAction(act)) {
                [filtered removeObjectAtIndex:i];
                removed = YES;
            }
        }
        if (removed) {
            %orig(filtered);
            return;
        }
    }
    %orig(actions);
}

- (void)addAction:(YTActionSheetAction *)action {
    if (!action) {
        %orig(action);
        return;
    }

    if ([objc_getAssociatedObject(action, "ytl_is_safe_download") boolValue]) {
        %orig(action);
        return;
    }

    NSString *identifier = getActionIdentifier(action);

    BOOL isDownload = isDownloadAction(action);

    // Người dùng chọn tắt menu tải xuống
    if (isDownload && ytlBool(@"removeDownloadMenu")) {
        return;
    }

    NSDictionary *actionsToRemove = @{
        @"1": @(ytlBool(@"removeWatchLaterMenu")),
        @"3": @(ytlBool(@"removeSaveToPlaylistMenu")),
        @"5": @(ytlBool(@"removeShareMenu")),
        @"12": @(ytlBool(@"removeNotInterestedMenu")),
        @"31": @(ytlBool(@"removeDontRecommendMenu")),
        @"58": @(ytlBool(@"removeReportMenu"))
    };

    if (identifier && [actionsToRemove[identifier] boolValue]) {
        return;
    }

    // Nếu tính năng Download Manager bật và đây là action Tải xuống gốc của YouTube:
    // Giữ nút gốc — khi bấm sẽ trigger offline endpoint → hook redirect sang YTLDownloadManager
    if (isDownload && ytlBool(@"downloadManager")) {
        // Trích xuất icon gốc để cache
        UIButton *btn = getActionButton(action);
        UIImage *nativeIcon = nil;
        @try { nativeIcon = [action valueForKey:@"iconImage"] ?: [action valueForKey:@"_iconImage"]; } @catch (NSException *e) {}
        if (!nativeIcon && btn) nativeIcon = btn.currentImage ?: btn.imageView.image;
        if (nativeIcon) {
            gCachedDownloadIcon = normalizeIcon24(nativeIcon);
        }

        // Trích xuất videoId nếu action gốc chứa endpoint/command
        NSString *extractedVid = nil;
        @try {
            id ep = [action valueForKey:@"serviceEndpoint"] ?: [action valueForKey:@"_serviceEndpoint"] ?: [action valueForKey:@"command"] ?: [action valueForKey:@"_command"];
            if (ep) {
                id dlEp = [ep valueForKey:@"offlineVideoEndpoint"] ?: [ep valueForKey:@"downloadVideoEndpoint"] ?: ep;
                extractedVid = [dlEp valueForKey:@"videoId"] ?: [dlEp valueForKey:@"videoID"];
            }
        } @catch (NSException *e) {}
        if (extractedVid && extractedVid.length > 0) {
            [[%c(YTLDownloadManager) sharedManager] setLastActiveVideoID:extractedVid];
        }

        // Cho nút gốc pass through — offline endpoint hook sẽ xử lý khi user bấm
        %orig(action);
        return;
    }

    %orig(action);
}

- (void)presentFromView:(UIView *)view animated:(BOOL)animated completion:(void(^)(void))completion {
    %orig;
}

- (void)presentFromViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void(^)(void))completion {
    %orig;
}
%end

// Hide buttons under the video player (@PoomSmart)
static BOOL findCell(ASNodeController *nodeController, NSArray <NSString *> *identifiers) {
    for (id child in [nodeController children]) {
        if ([child isKindOfClass:%c(ELMNodeController)]) {
            NSArray <ELMComponent *> *elmChildren = [(ELMNodeController *)child children];
            for (ELMComponent *elmChild in elmChildren) {
                for (NSString *identifier in identifiers) {
                    if ([[elmChild description] containsString:identifier])
                        return YES;
                }
            }
        }

        if ([child isKindOfClass:%c(ASNodeController)]) {
            ASDisplayNode *childNode = ((ASNodeController *)child).node; // ELMContainerNode
            NSArray *yogaChildren = childNode.yogaChildren;
            for (ASDisplayNode *displayNode in yogaChildren) {
                if ([identifiers containsObject:displayNode.accessibilityIdentifier])
                    return YES;
            }

            return findCell(child, identifiers);
        }

        return NO;
    }
    return NO;
}

%hook ASCollectionView
- (CGSize)sizeForElement:(ASCollectionElement *)element {
    if ([self.accessibilityIdentifier isEqualToString:@"id.video.scrollable_action_bar"]) {
        ASCellNode *node = [element node];
        ASNodeController *nodeController = [node controller];

        if (ytlBool(@"noPlayerRemixButton") && findCell(nodeController, @[@"id.video.remix.button"])) {
            return CGSizeZero;
        }

        if (ytlBool(@"noPlayerClipButton") && findCell(nodeController, @[@"clip_button.eml"])) {
            return CGSizeZero;
        }

        if (ytlBool(@"noPlayerDownloadButton") && findCell(nodeController, @[@"id.ui.add_to.offline.button"])) {
            return CGSizeZero;
        }
    }

    return %orig;
}
%end

// Remove Premium Pop-up, Horizontal Video Carousel and Shorts (https://github.com/MiRO92/YTNoShorts)
%hook YTAsyncCollectionView
- (id)cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = %orig;

    if ([cell isKindOfClass:objc_lookUpClass("_ASCollectionViewCell")]) {
        _ASCollectionViewCell *cell = %orig;
        if ([cell respondsToSelector:@selector(node)]) {
            NSString *idToRemove = [[cell node] accessibilityIdentifier];
            if ([idToRemove isEqualToString:@"statement_banner.view"] ||
                (([idToRemove isEqualToString:@"eml.shorts-grid"] || [idToRemove isEqualToString:@"eml.shorts-shelf"]) && ytlBool(@"hideShorts"))) {
                [self removeCellsAtIndexPath:indexPath];
            }
        }
    } else if (([cell isKindOfClass:objc_lookUpClass("YTReelShelfCell")] && ytlBool(@"hideShorts")) ||
        ([cell isKindOfClass:objc_lookUpClass("YTHorizontalCardListCell")] && ytlBool(@"noContinueWatching"))) {
        [self removeCellsAtIndexPath:indexPath];
    } return %orig;
}

%new
- (void)removeCellsAtIndexPath:(NSIndexPath *)indexPath {
    [self deleteItemsAtIndexPaths:@[indexPath]];
}
%end

// Shorts Progress Bar (https://github.com/PoomSmart/YTShortsProgress)
%hook YTReelPlayerViewController
- (BOOL)shouldEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTReelPlayerViewControllerSub
- (BOOL)shouldEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTShortsPlayerViewController
- (BOOL)shouldAlwaysEnablePlayerBar { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)shouldEnablePlayerBarOnlyOnPause { return ytlBool(@"shortsProgress") ? NO : YES; }
%end

%hook YTColdConfig
- (BOOL)iosEnableVideoPlayerScrubber { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)mobileShortsTabInlined { return ytlBool(@"shortsProgress") ? YES : NO; }
- (BOOL)iosUseSystemVolumeControlInFullscreen { return ytlBool(@"stockVolumeHUD") ? YES : NO; }
%end

%hook YTHotConfig
- (BOOL)enablePlayerBarForVerticalVideoWhenControlsHiddenInFullscreen { return ytlBool(@"shortsProgress") ? YES : NO; }
%end

// Dont Startup Shorts
%hook YTShortsStartupCoordinator
- (id)evaluateResumeToShorts { return ytlBool(@"resumeShorts") ? nil : %orig; }
%end

// Hide Shorts Elements
%hook YTReelPausedStateCarouselView
- (void)setPausedStateCarouselVisible:(BOOL)arg1 animated:(BOOL)arg2 { ytlBool(@"hideShortsSubscriptions") ? %orig(arg1 = NO, arg2) : %orig; }
%end

%hook YTReelWatchPlaybackOverlayView
- (void)setReelLikeButton:(id)arg1 { if (!ytlBool(@"hideShortsLike")) %orig; }
- (void)setReelDislikeButton:(id)arg1 { if (!ytlBool(@"hideShortsDislike")) %orig; }
- (void)setViewCommentButton:(id)arg1 { if (!ytlBool(@"hideShortsComments")) %orig; }
- (void)setRemixButton:(id)arg1 { if (!ytlBool(@"hideShortsRemix")) %orig; }
- (void)setShareButton:(id)arg1 { if (!ytlBool(@"hideShortsShare")) %orig; }
- (void)setNativePivotButton:(id)arg1 { if (!ytlBool(@"hideShortsAvatars")) %orig; }
- (void)setPivotButtonElementRenderer:(id)arg1 { if (!ytlBool(@"hideShortsAvatars")) %orig; }
%end

%hook YTReelHeaderView
- (void)setTitleLabelVisible:(BOOL)arg1 animated:(BOOL)arg2 { ytlBool(@"hideShortsLogo") ? %orig(arg1 = NO, arg2) : %orig; }
%end

%hook YTReelTransparentStackView
- (void)layoutSubviews {
    %orig;

    for (YTQTMButton *button in self.subviews) {
        if ([button respondsToSelector:@selector(buttonRenderer)]) {
            if (ytlBool(@"hideShortsSearch") && button.buttonRenderer.icon.iconType == 1045) button.hidden = YES;
            if (ytlBool(@"hideShortsCamera") && button.buttonRenderer.icon.iconType == 1046) button.hidden = YES;
            if (ytlBool(@"hideShortsMore") && button.buttonRenderer.icon.iconType == 1047) button.hidden = YES;
        }
    }
}
%end

%hook YTReelWatchHeaderView
- (void)setChannelBarElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsChannelName")) %orig; }
- (void)setHeaderRenderer:(id)renderer { if (!ytlBool(@"hideShortsDescription")) %orig; }
- (void)setShortsVideoTitleElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsDescription")) %orig; }
- (void)setSoundMetadataElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsAudioTrack")) %orig; }
- (void)setActionElement:(id)renderer { if (!ytlBool(@"hideShortsPromoCards")) %orig; }
- (void)setBadgeRenderer:(id)renderer { if (!ytlBool(@"hideShortsThanks")) %orig; }
- (void)setMultiFormatLinkElementRenderer:(id)renderer { if (!ytlBool(@"hideShortsSource")) %orig; }
%end

static BOOL isOverlayShown = YES;

%hook YTPlayerView
- (void)didPinch:(UIPinchGestureRecognizer *)gesture {
    %orig;

    if (ytlBool(@"pinchToFullscreenShorts") && [self.playerViewDelegate.parentViewController isKindOfClass:NSClassFromString(@"YTShortsPlayerViewController")]) {
        YTShortsPlayerViewController *shortsPlayerVC = (YTShortsPlayerViewController *)self.playerViewDelegate.parentViewController;
        YTReelContentView *contentView = (YTReelContentView *)shortsPlayerVC.view;
        UIWindow *mainWindow = [[[UIApplication sharedApplication] delegate] window];
        YTAppViewController *appVC = (YTAppViewController *)mainWindow.rootViewController;

        if (gesture.scale > 1) {
            if (!ytlBool(@"shortsOnlyMode")) [appVC hidePivotBar];

            [UIView animateWithDuration:0.3 animations:^{
                contentView.playbackOverlay.alpha = 0;
                isOverlayShown = contentView.playbackOverlay.alpha;
            }];
        } else {
            if (!ytlBool(@"shortsOnlyMode")) [appVC showPivotBar];

            [UIView animateWithDuration:0.3 animations:^{
                contentView.playbackOverlay.alpha = 1;
                isOverlayShown = contentView.playbackOverlay.alpha;
            }];
        }
    }
}
%end

%hook YTReelContentView
- (void)setPlaybackView:(id)arg1 {
    %orig;

    self.playbackOverlay.alpha = isOverlayShown;

    if (ytlBool(@"shortsOnlyMode")) {
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(turnShortsOnlyModeOff:)];
        longPressGesture.numberOfTouchesRequired = 2;
        longPressGesture.minimumPressDuration = 0.5;

        [self addGestureRecognizer:longPressGesture];
    }
}

%new
- (void)turnShortsOnlyModeOff:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ytlSetBool(NO, @"shortsOnlyMode");

        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"ShortsModeTurnedOff") firstResponder:[%c(YTUIUtils) topViewControllerForPresenting]] send];

        UIWindow *mainWindow = [[[UIApplication sharedApplication] delegate] window];
        YTAppViewController *appVC = (YTAppViewController *)mainWindow.rootViewController;
        [appVC performSelector:@selector(showPivotBar) withObject:nil afterDelay:1.0];
    }
}
%end

static void downloadImageFromURL(UIResponder *responder, NSURL *URL, BOOL download) {
    NSString *URLString = URL.absoluteString;

    if (ytlBool(@"fixAlbums") && [URLString hasPrefix:@"https://yt3."]) {
        URLString = [URLString stringByReplacingOccurrencesOfString:@"https://yt3." withString:@"https://yt4."];
    }

    NSURL *downloadURL = nil;
    if ([URLString containsString:@"c-fcrop"]) {
        NSRange croppedURL = [URLString rangeOfString:@"c-fcrop"];
        if (croppedURL.location != NSNotFound) {
            NSString *newURL = [URLString stringByReplacingOccurrencesOfString:[URLString substringFromIndex:croppedURL.location] withString:@"nd-v1"];
            downloadURL = [NSURL URLWithString:newURL];
        }
    } else {
        downloadURL = URL;
    }

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithURL:downloadURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            if (download) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                    [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
                } completionHandler:^(BOOL success, NSError *error) {
                    [[%c(YTToastResponderEvent) eventWithMessage:success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription] firstResponder:responder] send];
                }];
            } else {
                [UIPasteboard generalPasteboard].image = [UIImage imageWithData:data];
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:responder] send];
            }
        } else {
            [[%c(YTToastResponderEvent) eventWithMessage:[NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription] firstResponder:responder] send];
        }
    }] resume];
}

static void genImageFromLayer(CALayer *layer, UIColor *backgroundColor, void (^completionHandler)(UIImage *)) {
    UIGraphicsBeginImageContextWithOptions(layer.frame.size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, backgroundColor.CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, layer.frame.size.width, layer.frame.size.height));
    [layer renderInContext:context];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (completionHandler) {
        completionHandler(image);
    }
}

%hook ELMContainerNode
%property (nonatomic, strong) NSString *copiedComment;
%property (nonatomic, strong) NSURL *copiedURL;
%end

%hook ASDisplayNode

- (void)setFrame:(CGRect)frame {
    %orig;

    if (ytlBool(@"commentManager") && [[self valueForKey:@"_accessibilityIdentifier"] isEqualToString:@"id.comment.content.label"]) {
        if ([self isKindOfClass:NSClassFromString(@"ASTextNode")]) {
            ASTextNode *textNode = (ASTextNode *)self;

            NSString *comment;
            if ([textNode respondsToSelector:@selector(attributedText)]) {
                if (textNode.attributedText) comment = textNode.attributedText.string;
            }

            NSMutableArray *allObjects = self.supernodes.allObjects;
            for (ELMContainerNode *containerNode in allObjects) {
                if ([containerNode.description containsString:@"id.ui.comment_cell"] && comment) {
                    containerNode.copiedComment = comment;
                    break;
                }
            }
        }
    }

    if (ytlBool(@"postManager") && [self isKindOfClass:NSClassFromString(@"ELMExpandableTextNode")]) {
        ELMExpandableTextNode *expandableTextNode = (ELMExpandableTextNode *)self;

        if ([expandableTextNode.currentTextNode isKindOfClass:NSClassFromString(@"ASTextNode")]) {
            ASTextNode *textNode = (ASTextNode *)expandableTextNode.currentTextNode;

            NSString *text;
            if ([textNode respondsToSelector:@selector(attributedText)]) {
                if (textNode.attributedText) text = textNode.attributedText.string;
            }

            NSMutableArray *allObjects = self.supernodes.allObjects;
            for (ELMContainerNode *containerNode in allObjects) {
                if ([containerNode.description containsString:@"id.ui.backstage.original_post"] && text) {
                    containerNode.copiedComment = text;
                    break;
                }
            }
        }
    }
}
%end

%hook YTImageZoomNode
- (BOOL)gestureRecognizer:(id)arg1 shouldRecognizeSimultaneouslyWithGestureRecognizer:(id)arg2 {
    BOOL isImageLoaded = [self valueForKey:@"_didLoadImage"];
    if (ytlBool(@"postManager") && isImageLoaded) {
        ASDisplayNode *displayNode = (ASDisplayNode *)self;
        ASNetworkImageNode *imageNode = (ASNetworkImageNode *)self;
        NSURL *URL = imageNode.URL;

        NSMutableArray *allObjects = displayNode.supernodes.allObjects;
        for (ELMContainerNode *containerNode in allObjects) {
            if ([containerNode.description containsString:@"id.ui.backstage.original_post"]) {
                containerNode.copiedURL = URL;
                break;
            }
        }
    }

    return %orig;
}
%end

%hook _ASDisplayView
- (void)setKeepalive_node:(id)arg1 {
    %orig;

    NSArray *gesturesInfo = @[
        @{@"selector": @"postManager:", @"text": @"id.ui.backstage.original_post", @"key": @(ytlBool(@"postManager"))},
        @{@"selector": @"savePFP:", @"text": @"ELMImageNode-View", @"key": @(ytlBool(@"saveProfilePhoto"))},
        @{@"selector": @"commentManager:", @"text": @"id.ui.comment_cell", @"key": @(ytlBool(@"commentManager"))}
    ];

    for (NSDictionary *gestureInfo in gesturesInfo) {
        SEL selector = NSSelectorFromString(gestureInfo[@"selector"]);

        if ([gestureInfo[@"key"] boolValue] && [[self description] containsString:gestureInfo[@"text"]]) {
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:selector];
            longPress.minimumPressDuration = 0.3;
            [self addGestureRecognizer:longPress];
            break;
        }
    }
}

%new
- (void)savePFP:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {

        ASNetworkImageNode *imageNode = (ASNetworkImageNode *)self.keepalive_node;
        NSString *URLString = imageNode.URL.absoluteString;
        if (URLString) {
            NSRange sizeRange = [URLString rangeOfString:@"=s"];
            if (sizeRange.location != NSNotFound) {
                NSRange dashRange = [URLString rangeOfString:@"-" options:0 range:NSMakeRange(sizeRange.location, URLString.length - sizeRange.location)];
                if (dashRange.location != NSNotFound) {
                    NSString *newURLString = [URLString stringByReplacingCharactersInRange:NSMakeRange(sizeRange.location + 2, dashRange.location - sizeRange.location - 2) withString:@"1024"];
                    NSURL *PFPURL = [NSURL URLWithString:newURLString];

                    UIImage *image = [UIImage imageWithData:[NSData dataWithContentsOfURL:PFPURL]];
                    if (image) {
                        YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];
    
                        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveProfilePicture") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);

                            [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Saved") firstResponder:self.keepalive_node.closestViewController] send];
                        }]];

                        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyProfilePicture") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
                            [UIPasteboard generalPasteboard].image = image;
                            [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.keepalive_node.closestViewController] send];
                        }]];

                        [sheetController presentFromViewController:self.keepalive_node.closestViewController animated:YES completion:nil];
                    }
                }
            }
        }
    }
}

%new
- (void)postManager:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {
        ELMContainerNode *nodeForLayer = (ELMContainerNode *)self.keepalive_node.yogaChildren[0];
        ELMContainerNode *containerNode = (ELMContainerNode *)self.keepalive_node;
        NSString *text = containerNode.copiedComment;
        NSURL *URL = containerNode.copiedURL;
        CALayer *layer = nodeForLayer.layer;
        UIColor *backgroundColor = containerNode.closestViewController.view.backgroundColor;

        YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];
        
        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyPostText") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
            if (text) {
                [UIPasteboard generalPasteboard].string = text;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            }
        }]];

        if (URL) {
            [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveCurrentImage") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
                downloadImageFromURL(containerNode.closestViewController, URL, YES);
            }]];

            [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCurrentImage") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
                downloadImageFromURL(containerNode.closestViewController, URL, NO);
            }]];
        }

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SavePostAsImage") titleColor:[UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0] iconImage:YTImageNamed(@"yt_outline_image_24pt") iconColor:[UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0] disableAutomaticButtonColor:YES accessibilityIdentifier:nil handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAssetFromImage:image];
                    request.creationDate = [NSDate date];
                } completionHandler:^(BOOL success, NSError *error) {
                    NSString *message = success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription];
                    [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:containerNode.closestViewController] send];
                }];
            });
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyPostAsImage") titleColor:[UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0] iconImage:YTImageNamed(@"yt_outline_library_image_24pt") iconColor:[UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0] disableAutomaticButtonColor:YES accessibilityIdentifier:nil handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [UIPasteboard generalPasteboard].image = image;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            });
        }]];

        [sheetController presentFromViewController:containerNode.closestViewController animated:YES completion:nil];
    }
}

%new
- (void)commentManager:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {
        ELMContainerNode *containerNode = (ELMContainerNode *)self.keepalive_node;
        NSString *comment = containerNode.copiedComment;

        CALayer *layer = self.layer;
        UIColor *backgroundColor = containerNode.closestViewController.view.backgroundColor;

        YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCommentText") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
            if (comment) {
                [UIPasteboard generalPasteboard].string = comment;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            }
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"SaveCommentAsImage") iconImage:YTImageNamed(@"yt_outline_image_24pt") style:0 handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAssetFromImage:image];
                    request.creationDate = [NSDate date];
                } completionHandler:^(BOOL success, NSError *error) {
                    NSString *message = success ? LOC(@"Saved") : [NSString stringWithFormat:LOC(@"%@: %@"), LOC(@"Error"), error.localizedDescription];
                    [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:containerNode.closestViewController] send];
                }];
            });
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyCommentAsImage") iconImage:YTImageNamed(@"yt_outline_library_image_24pt") style:0 handler:^ {
            genImageFromLayer(layer, backgroundColor, ^(UIImage *image) {
                [UIPasteboard generalPasteboard].image = image;
                [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:containerNode.closestViewController] send];
            });
        }]];

        [sheetController presentFromViewController:containerNode.closestViewController animated:YES completion:nil];
    }
}
%end

// Remove Tabs
%hook YTPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    NSMutableArray <YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];

    NSDictionary *identifiersToRemove = @{
        @"FEshorts": @[@(ytlBool(@"removeShorts")), @(ytlBool(@"reExplore"))],
        @"FEsubscriptions": @[@(ytlBool(@"removeSubscriptions"))],
        @"FEuploads": @[@(ytlBool(@"removeUploads"))],
        @"FElibrary": @[@(ytlBool(@"removeLibrary"))]
    };

    for (NSString *identifier in identifiersToRemove) {
        NSArray *removeValues = identifiersToRemove[identifier];
        BOOL shouldRemoveItem = [removeValues containsObject:@(YES)];

        NSUInteger index = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderer, NSUInteger idx, BOOL *stop) {
            if ([identifier isEqualToString:@"FEuploads"]) {
                return shouldRemoveItem && [[[renderer pivotBarIconOnlyItemRenderer] pivotIdentifier] isEqualToString:identifier];
            } else {
                return shouldRemoveItem && [[[renderer pivotBarItemRenderer] pivotIdentifier] isEqualToString:identifier];
            }
        }];

        if (index != NSNotFound) {
            [items removeObjectAtIndex:index];
        }
    }
    
    NSUInteger exploreIndex = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
        return [[[renderers pivotBarItemRenderer] pivotIdentifier] isEqualToString:[%c(YTIBrowseRequest) browseIDForExploreTab]];
    }];

    if (exploreIndex == NSNotFound && (ytlBool(@"reExplore") || ytlBool(@"addExplore"))) {
        YTIPivotBarSupportedRenderers *exploreTab = [%c(YTIPivotBarRenderer) pivotSupportedRenderersWithBrowseId:[%c(YTIBrowseRequest) browseIDForExploreTab] title:LOC(@"Explore") iconType:292];
        [items insertObject:exploreTab atIndex:1];
    }

    %orig;
}
%end

// Hide Tab Bar Indicators
%hook YTPivotBarIndicatorView
- (void)setFillColor:(id)arg1 { %orig(ytlBool(@"removeIndicators") ? [UIColor clearColor] : arg1); }
- (void)setBorderColor:(id)arg1 { %orig(ytlBool(@"removeIndicators") ? [UIColor clearColor] : arg1); }
%end

// Hide Tab Labels
%hook YTPivotBarItemView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    %orig;

    if (ytlBool(@"removeLabels")) {
        [self.navigationButton setTitle:@"" forState:UIControlStateNormal];
        [self.navigationButton setSizeWithPaddingAndInsets:NO];
    }

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(manageTab:)];
    longPress.minimumPressDuration = 0.3;
    if ([self.renderer.pivotIdentifier isEqualToString:@"FEwhat_to_watch"]) [self addGestureRecognizer:longPress];
}

%new
- (void)manageTab:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ytlBool(@"removeLibrary") ? ytlSetBool(NO, @"removeLibrary") : ytlSetBool(YES, @"removeLibrary");
        [[[%c(YTHeaderContentComboViewController) alloc] init] refreshPivotBar];
        [[%c(YTToastResponderEvent) eventWithMessage:ytlBool(@"removeLibrary") ? LOC(@"LibraryRemoved") : LOC(@"LibraryAdded") firstResponder:self.delegate] send];
    }
}
%end

// Startup Tab
BOOL isTabSelected = NO;
%hook YTPivotBarViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!isTabSelected && !ytlBool(@"shortsOnlyMode")) {
        NSArray *pivotIdentifiers = @[@"FEwhat_to_watch", @"FEexplore", @"FEshorts", @"FEsubscriptions", @"FElibrary"];
        [self selectItemWithPivotIdentifier:pivotIdentifiers[ytlInt(@"pivotIndex")]];
        isTabSelected = YES;
    }

    if (ytlBool(@"shortsOnlyMode")) {
        [self selectItemWithPivotIdentifier:@"FEshorts"];
        [self.parentViewController hidePivotBar];
    }
}
%end

%hook YTAppViewController
- (void)showPivotBar {
    if (!ytlBool(@"shortsOnlyMode")) {
        %orig;

        isOverlayShown = YES;
    }
}
%end

%hook YTReelWatchRootViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (ytlBool(@"shortsOnlyMode")) {
        [self.navigationController.parentViewController hidePivotBar];
    }
}
%end

%hook YTEngagementPanelView
- (void)layoutSubviews {
    %orig;

    if (ytlBool(@"copyVideoInfo") && [self.panelIdentifier.identifierString isEqualToString:@"video-description-ep-identifier"]) {
        YTQTMButton *copyInfoButton = [%c(YTQTMButton) iconButton];
        copyInfoButton.accessibilityLabel = LOC(@"CopyVideoInfo");
        [copyInfoButton setTag:999];
        [copyInfoButton enableNewTouchFeedback];
        [copyInfoButton setImage:YTImageNamed(@"yt_outline_copy_24pt") forState:UIControlStateNormal];
        [copyInfoButton setTintColor:[UIColor labelColor]];
        [copyInfoButton setTranslatesAutoresizingMaskIntoConstraints:false];
        [copyInfoButton addTarget:self action:@selector(didTapCopyInfoButton:) forControlEvents:UIControlEventTouchUpInside];

        if (self.headerView && ![self.headerView viewWithTag:999]) {
            [self.headerView addSubview:copyInfoButton];

            [NSLayoutConstraint activateConstraints:@[
                [copyInfoButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-48],
                [copyInfoButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
                [copyInfoButton.widthAnchor constraintEqualToConstant:40.0],
                [copyInfoButton.heightAnchor constraintEqualToConstant:40.0],
            ]];
        }
    }
}

%new
- (void)didTapCopyInfoButton:(UIButton *)sender {
    YTPlayerViewController *playerVC = self.resizeDelegate.parentViewController.parentViewController.parentViewController.playerViewController;
    NSString *title = playerVC.playerResponse.playerData.videoDetails.title;
    NSString *shortDescription = playerVC.playerResponse.playerData.videoDetails.shortDescription;

    YTDefaultSheetController *sheetController = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:nil];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyTitle") iconImage:YTImageNamed(@"yt_outline_text_box_24pt") style:0 handler:^ {
        [UIPasteboard generalPasteboard].string = title;
        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.resizeDelegate] send];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"CopyDescription") iconImage:YTImageNamed(@"yt_outline_message_bubble_right_24pt") style:0 handler:^ {
        [UIPasteboard generalPasteboard].string = shortDescription;
        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Copied") firstResponder:self.resizeDelegate] send];
    }]];

    [sheetController presentFromViewController:self.resizeDelegate animated:YES completion:nil];
}
%end

CGFloat rateBeforeSpeedmaster = 1.0;

static void manageSpeedmasterYTLite(UILongPressGestureRecognizer *gesture, YTMainAppVideoPlayerOverlayViewController *delegate, YTInlinePlayerScrubUserEducationView *edu) {
    NSArray *speedLabels = @[@0, @2.0, @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];

    YTLabel *label = [edu valueForKey:@"_userEducationLabel"];
    edu.labelType = 1;
    [label setValue:[NSString stringWithFormat:@"%@: %@×", LOC(@"PlaybackSpeed"), speedLabels[ytlInt(@"speedIndex")]] forKey:@"text"];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        rateBeforeSpeedmaster = delegate.currentPlaybackRate;
        [delegate setPlaybackRate:[speedLabels[ytlInt(@"speedIndex")] floatValue]];
        [edu setVisible:YES];
    }

    else if (gesture.state == UIGestureRecognizerStateEnded) {
        [delegate setPlaybackRate:rateBeforeSpeedmaster];
        [edu setVisible:NO];
    }
}

%hook YTMainAppVideoPlayerOverlayView
- (void)setSeekAnywherePanGestureRecognizer:(id)arg1 {
    %orig;

    if (objc_lookUpClass("YTSpeedmasterController") != nil) return;
    if (ytlInt(@"speedIndex") == 0) return;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(speedmasterYtLite:)];
    longPress.minimumPressDuration = 0.3;
    longPress.delaysTouchesBegan = NO;
    longPress.delaysTouchesEnded = NO;
    longPress.cancelsTouchesInView = NO;
    [self addGestureRecognizer:longPress];
}

%new
- (void)speedmasterYtLite:(UILongPressGestureRecognizer *)gesture {
    YTInlinePlayerScrubUserEducationView *edu = self.scrubUserEducationView;
    manageSpeedmasterYTLite(gesture, self.delegate, edu);
}
%end

%hook YTSpeedmasterController
- (void)speedmasterDidLongPressWithRecognizer:(UILongPressGestureRecognizer *)gesture {
    if (ytlInt(@"speedIndex") == 0) return;
    if (ytlInt(@"speedIndex") == 1) return %orig;

    YTMainAppVideoPlayerOverlayViewController *delegate = [self valueForKey:@"_delegate"];
    YTInlinePlayerScrubUserEducationView *edu = (YTInlinePlayerScrubUserEducationView *)delegate.videoPlayerOverlayView.scrubUserEducationView;
    manageSpeedmasterYTLite(gesture, delegate, edu);
}
%end

// Disable Right-To-Left Formatting
%hook NSParagraphStyle
+ (NSWritingDirection)defaultWritingDirectionForLanguage:(id)lang { return ytlBool(@"disableRTL") ? NSWritingDirectionLeftToRight : %orig; }
+ (NSWritingDirection)_defaultWritingDirection { return ytlBool(@"disableRTL") ? NSWritingDirectionLeftToRight : %orig; }
%end

// Fix Albums For Russian Users
static NSURL *newCoverURL(NSURL *originalURL) {
    NSDictionary <NSString *, NSString *> *hostsToReplace = @{
        @"yt3.ggpht.com": @"yt4.ggpht.com",
        @"yt3.googleusercontent.com": @"yt4.googleusercontent.com",
    };

    NSString *const replacement = hostsToReplace[originalURL.host];
    if (ytlBool(@"fixAlbums") && replacement) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:originalURL resolvingAgainstBaseURL:NO];
        components.host = replacement;
        return components.URL;
    }
    return originalURL;
}

%hook YTImageSelectionStrategyImageURLs
- (id)initWithSelectedImageURL:(NSURL *)selectedImageURL updatedImageURL:(NSURL *)updatedImageURL {
    return %orig(newCoverURL(selectedImageURL), newCoverURL(updatedImageURL));
}
%end

%group OfflineInterception

%hook YTOfflineVideoEndpointCommandHandlerImpl
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender completionBlock:(id)block {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:nil fromView:nil];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommandContext:(id)context handler:(id)handler {
    if (ytlBool(@"downloadManager")) {
        @try {
            id command = nil;
            @try { command = [context valueForKey:@"command"]; } @catch (NSException *e) {}
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:nil fromView:nil];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
%end

%hook YTOfflineVideoEndpointCommandHandler
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender completionBlock:(id)block {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:entry fromView:fromView];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommand:(id)command {
    if (ytlBool(@"downloadManager")) {
        @try {
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:nil fromView:nil];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
- (void)executeWithCommandContext:(id)context handler:(id)handler {
    if (ytlBool(@"downloadManager")) {
        @try {
            id command = nil;
            @try { command = [context valueForKey:@"command"]; } @catch (NSException *e) {}
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:command entry:nil fromView:nil];
        } @catch (NSException *e) {}
        return;
    }
    %orig;
}
%end

%hook YTOfflineQualitySelectionAlertView
- (void)show {
    if (ytlBool(@"downloadManager")) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[%c(YTLDownloadManager) sharedManager] handleOfflineEndpointCommand:nil entry:nil fromView:nil];
        });
        return;
    }
    %orig;
}
%end

%hook YTOfflineVideoQualitySelectorViewController
- (void)viewDidLoad {
    %orig;
    if (ytlBool(@"downloadManager")) {
        ((UIViewController *)self).view.hidden = YES;
    }
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (ytlBool(@"downloadManager")) {
        [self dismissViewControllerAnimated:NO completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSString *vid = [[%c(YTLDownloadManager) sharedManager] lastActiveVideoID];
                if (!vid && gCurrentPlayerVC) {
                    @try { vid = [gCurrentPlayerVC contentVideoID] ?: [gCurrentPlayerVC valueForKey:@"currentVideoID"]; } @catch (NSException *e) {}
                }
                if (vid && vid.length > 0) {
                    [[%c(YTLDownloadManager) sharedManager] handleDownloadForVideoId:vid playerResponse:nil sourceView:nil];
                }
            });
        }];
    }
}
%end

%hook ELMPBShowActionSheetCommand
- (void)executeWithCommandContext:(id)context handler:(id)handler {
    if (ytlBool(@"downloadManager")) {
        NSString *desc = [self description];
        NSString *ctxDesc = [context description];
        static NSRegularExpression *re = nil;
        static NSRegularExpression *urlRe = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            re = [NSRegularExpression regularExpressionWithPattern:@"(?:video_id|videoId|videoID)[\":=\\s]+([a-zA-Z0-9_-]{11})" options:NSRegularExpressionCaseInsensitive error:nil];
            urlRe = [NSRegularExpression regularExpressionWithPattern:@"(?:youtu\\.be/|v=|/v/|/embed/)([a-zA-Z0-9_-]{11})" options:NSRegularExpressionCaseInsensitive error:nil];
        });
        NSTextCheckingResult *match = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
        if (!match && ctxDesc) {
            match = [re firstMatchInString:ctxDesc options:0 range:NSMakeRange(0, ctxDesc.length)];
        }
        if (match && match.numberOfRanges > 1) {
            NSString *targetStr = (match.range.location < desc.length) ? desc : ctxDesc;
            NSString *vid = [targetStr substringWithRange:[match rangeAtIndex:1]];
            [[%c(YTLDownloadManager) sharedManager] setLastActiveVideoID:vid];
        } else {
            NSTextCheckingResult *uMatch = [urlRe firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
            if (!uMatch && ctxDesc) {
                uMatch = [urlRe firstMatchInString:ctxDesc options:0 range:NSMakeRange(0, ctxDesc.length)];
            }
            if (uMatch && uMatch.numberOfRanges > 1) {
                NSString *targetStr = (uMatch.range.location < desc.length) ? desc : ctxDesc;
                NSString *vid = [targetStr substringWithRange:[uMatch rangeAtIndex:1]];
                [[%c(YTLDownloadManager) sharedManager] setLastActiveVideoID:vid];
            }
        }
    }
    %orig;
}
%end

%hook YTShareEntityEndpointCommandHandler
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender {
    if (ytlBool(@"downloadManager")) {
        NSString *desc = [command description];
        static NSRegularExpression *re = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            re = [NSRegularExpression regularExpressionWithPattern:@"(?:video_id|videoId|videoID)[\":=\\s]+([a-zA-Z0-9_-]{11})" options:NSRegularExpressionCaseInsensitive error:nil];
        });
        NSTextCheckingResult *match = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *vid = [desc substringWithRange:[match rangeAtIndex:1]];
            [[%c(YTLDownloadManager) sharedManager] setLastActiveVideoID:vid];
        }
    }
    %orig;
}
%end

%hook YTInlinePlayerBarContainerView
- (void)setDelegate:(id)delegate {
    %orig;
    if (delegate && ytlBool(@"downloadManager")) {
        @try {
            id pr = nil;
            if ([delegate respondsToSelector:@selector(contentPlayerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [delegate performSelector:@selector(contentPlayerResponse)];
                #pragma clang diagnostic pop
            } else if ([delegate respondsToSelector:@selector(playerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [delegate performSelector:@selector(playerResponse)];
                #pragma clang diagnostic pop
            }
            if (!pr) pr = [delegate valueForKey:@"contentPlayerResponse"] ?: [delegate valueForKey:@"playerResponse"];
            id vid = [delegate valueForKey:@"videoId"] ?: [delegate valueForKey:@"videoID"];
            if (pr || vid) {
                [[%c(YTLDownloadManager) sharedManager] didActivateVideoWithPlaybackData:nil videoID:vid playerResponse:pr];
            }
        } @catch (NSException *e) {}
    }
}
%end

%hook YTCorePlaybackController
- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    if (ytlBool(@"downloadManager")) {
        @try {
            NSString *vid = nil;
            if ([video respondsToSelector:@selector(videoId)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [video performSelector:@selector(videoId)];
                #pragma clang diagnostic pop
            } else if ([video respondsToSelector:@selector(videoID)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [video performSelector:@selector(videoID)];
                #pragma clang diagnostic pop
            }
            if (!vid) vid = [video valueForKey:@"videoId"] ?: [video valueForKey:@"videoID"];

            id pr = nil;
            if ([playbackData respondsToSelector:@selector(playerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [playbackData performSelector:@selector(playerResponse)];
                #pragma clang diagnostic pop
            } else if ([playbackData respondsToSelector:@selector(contentPlayerResponse)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                pr = [playbackData performSelector:@selector(contentPlayerResponse)];
                #pragma clang diagnostic pop
            }
            if (!pr) pr = [playbackData valueForKey:@"playerResponse"] ?: [playbackData valueForKey:@"contentPlayerResponse"];

            [[%c(YTLDownloadManager) sharedManager] didActivateVideo:video withPlaybackData:playbackData videoID:vid playerResponse:pr];
        } @catch (NSException *e) {}
    }
}

- (void)playbackControllerDidActivateVideo:(id)video withPlayerResponse:(id)playerResponse {
    %orig;
    if (ytlBool(@"downloadManager")) {
        @try {
            NSString *vid = nil;
            if ([video respondsToSelector:@selector(videoId)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [video performSelector:@selector(videoId)];
                #pragma clang diagnostic pop
            } else if ([video respondsToSelector:@selector(videoID)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                vid = [video performSelector:@selector(videoID)];
                #pragma clang diagnostic pop
            }
            if (!vid) vid = [video valueForKey:@"videoId"] ?: [video valueForKey:@"videoID"];

            [[%c(YTLDownloadManager) sharedManager] didActivateVideo:video withPlaybackData:nil videoID:vid playerResponse:playerResponse];
        } @catch (NSException *e) {}
    }
}
%end

%end

%ctor {
    %init;

    if (objc_lookUpClass("YTOfflineVideoEndpointCommandHandlerImpl") || objc_lookUpClass("YTOfflineVideoEndpointCommandHandler") || objc_lookUpClass("YTOfflineQualitySelectionAlertView") || objc_lookUpClass("ELMPBShowActionSheetCommand") || objc_lookUpClass("YTInlinePlayerBarContainerView") || objc_lookUpClass("YTCorePlaybackController")) {
        %init(OfflineInterception,
              YTOfflineVideoEndpointCommandHandlerImpl = objc_lookUpClass("YTOfflineVideoEndpointCommandHandlerImpl"),
              YTOfflineVideoEndpointCommandHandler = objc_lookUpClass("YTOfflineVideoEndpointCommandHandler"),
              YTOfflineQualitySelectionAlertView = objc_lookUpClass("YTOfflineQualitySelectionAlertView"),
              YTOfflineVideoQualitySelectorViewController = objc_lookUpClass("YTOfflineVideoQualitySelectorViewController"),
              ELMPBShowActionSheetCommand = objc_lookUpClass("ELMPBShowActionSheetCommand"),
              YTShareEntityEndpointCommandHandler = objc_lookUpClass("YTShareEntityEndpointCommandHandler"),
              YTInlinePlayerBarContainerView = objc_lookUpClass("YTInlinePlayerBarContainerView"),
              YTCorePlaybackController = objc_lookUpClass("YTCorePlaybackController"));
    }

    if (ytlBool(@"shortsOnlyMode") && (ytlBool(@"removeShorts") || ytlBool(@"reExplore"))) {
        ytlSetBool(NO, @"removeShorts");
        ytlSetBool(NO, @"reExplore");
    }

    if (!ytlBool(@"advancedMode") && !ytlBool(@"advancedModeReminder")) {
        ytlSetBool(YES, @"advancedModeReminder");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{
                ytlSetBool(YES, @"advancedMode");
            }
            actionTitle:LOC(@"Yes")
            cancelTitle:LOC(@"No")];
            alertView.title = @"YTLite";
            alertView.subtitle = [NSString stringWithFormat:LOC(@"AdvancedModeReminder"), @"YTLite", LOC(@"Version"), LOC(@"Advanced")];
            [alertView show];
        });
    }
}
