# Download Manager Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sửa triệt để lỗi nút Download trong menu 3 chấm trên YouTube 21.34.3: chặn popup Premium, xoá bỏ hiện tượng nháy màn hình, và hỗ trợ nạp stream formats qua InnerTube API khi tải từ Feed/Search.

**Architecture:** Hook vào `YTOfflineVideoEndpointCommandHandlerImpl` để chặn đứng luồng Offline gốc của YouTube; trích xuất `videoId` từ `YTIOfflineVideoEndpoint`. Nếu video đang mở thì lấy trực tiếp `playerResponse`, nếu video ở ngoài Feed/Search thì gọi InnerTube API `/youtubei/v1/player` để lấy `streamingData` và hiển thị ActionSheet tải video.

**Tech Stack:** Objective-C, Logos/Theos, iOS UIKit, NSURLSession, AVFoundation.

## Global Constraints

- Mọi lệnh shell thực thi phải bắt đầu bằng dấu cách (space).
- Ngôn ngữ giải thích hoàn toàn bằng tiếng Việt, xưng hô "anh guộc".
- Thư mục chứa tài liệu: `docs/specs` và `docs/plans`.
- Sử dụng `.tmp` trong repo cho dữ liệu tạm.

---

### Task 1: Bổ sung API điều phối và xử lý InnerTube Player API trong `YTLDownloadManager`

**Files:**
- Modify: `Utils/YTLDownloadManager.h`
- Modify: `Utils/YTLDownloadManager.m`

**Interfaces:**
- Consumes: `videoId` (NSString), `playerResponse` (id, nullable), `parentVC` (UIViewController)
- Produces: 
  - `- (void)handleDownloadForVideoId:(nullable NSString *)videoId playerResponse:(nullable id)playerResponse parentViewController:(UIViewController *)parentVC;`
  - `- (void)fetchAndShowDownloadMenuForVideoId:(NSString *)videoId parentViewController:(UIViewController *)parentVC;`

- [ ] **Step 1: Khai báo các phương thức mới trong `Utils/YTLDownloadManager.h`**

```objc
- (void)handleDownloadForVideoId:(nullable NSString *)videoId
                  playerResponse:(nullable id)playerResponse
            parentViewController:(UIViewController *)parentVC;

- (void)fetchAndShowDownloadMenuForVideoId:(NSString *)videoId
                      parentViewController:(UIViewController *)parentVC;
```

- [ ] **Step 2: Triển khai logic điều phối và InnerTube fetcher trong `Utils/YTLDownloadManager.m`**

Triển khai:
1. `handleDownloadForVideoId:playerResponse:parentViewController:`:
   - So khớp `videoId` với `playerResponse`.
   - Nếu `playerResponse` hợp lệ và khớp `videoId`, gọi trực tiếp `showDownloadMenuForPlayerResponse:parentViewController:`.
   - Nếu `playerResponse` là nil hoặc không khớp `videoId` (tải từ Feed/Search), gọi `fetchAndShowDownloadMenuForVideoId:parentViewController:`.
2. `fetchAndShowDownloadMenuForVideoId:parentViewController:`:
   - Hiển thị thông báo "Đang lấy thông tin video...".
   - Tạo request POST tới `https://www.youtube.com/youtubei/v1/player` với context client `IOS`.
   - Bóc tách JSON: `streamingData` (adaptiveFormats, formats) và `videoDetails.title`.
   - Hiển thị `showDownloadMenuWithFormats:title:parentViewController:`.

- [ ] **Step 3: Xác minh cú pháp và các trường dữ liệu phân tích**

Đảm bảo `adaptiveFormats` và `formats` được bóc tách đúng chuẩn theo model `YTLDownloadFormat`.

---

### Task 2: Cập nhật Hook Command Handler trong `YTLite.x`

**Files:**
- Modify: `YTLite.x`

**Interfaces:**
- Consumes: `YTOfflineVideoEndpointCommandHandlerImpl`, `YTIOfflineVideoEndpoint`, `YTLDownloadManager`
- Produces: Hook hoàn chỉnh chặn luồng offline gốc của YouTube và chuyển tiếp sang `YTLDownloadManager`

- [ ] **Step 1: Thay thế `%hook YTOfflineVideoEndpointHandler` bằng `%hook YTOfflineVideoEndpointCommandHandlerImpl` và `%hook YTOfflineVideoEndpointCommandHandler`**

```objc
// Modern Offline Command Handlers (YouTube 19.x - 21.x)
%hook YTOfflineVideoEndpointCommandHandlerImpl
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender {
    if (ytlBool(@"downloadManager")) {
        NSString *videoId = nil;
        @try {
            id offlineEndpoint = [command valueForKey:@"offlineVideoEndpoint"];
            videoId = [offlineEndpoint valueForKey:@"videoId"];
        } @catch (NSException *e) {}

        UIViewController *topVC = [%c(YTUIUtils) topViewControllerForPresenting];
        YTPlayerViewController *playerVC = currentActivePlayerVC;
        id playerResponse = (playerVC && [playerVC respondsToSelector:@selector(playerResponse)]) ? playerVC.playerResponse : nil;

        [[YTLDownloadManager sharedManager] handleDownloadForVideoId:videoId playerResponse:playerResponse parentViewController:topVC];
        return;
    }
    %orig;
}

- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender completionBlock:(id)completionBlock {
    if (ytlBool(@"downloadManager")) {
        [self executeWithCommand:command entry:entry fromView:fromView sender:sender];
        if (completionBlock) {
            void (^block)(void) = completionBlock;
            block();
        }
        return;
    }
    %orig;
}
%end
```

- [ ] **Step 2: Cập nhật và bảo vệ `%hook YTOfflineVideoQualitySelectorViewController`**

Đảm bảo nếu controller này bất ngờ xuất hiện từ luồng phụ, nó được dismiss âm thầm và không kích hoạt lại popup Upsell.

---

### Task 3: Biên dịch và kiểm tra tính toàn vẹn (Verification)

**Files:**
- Code base toàn dự án

- [ ] **Step 1: Kiểm tra biên dịch / Linting**

Kiểm tra toàn bộ các file sửa đổi không có lỗi cú pháp Objective-C / Logos.

- [ ] **Step 2: Cập nhật tài liệu Walkthrough**

Ghi lại các thay đổi đã thực hiện và hướng dẫn kiểm thử chi tiết.
