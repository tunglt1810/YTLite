# Native AVFoundation Download Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xây dựng và tích hợp module Download Manager gốc (Native AVFoundation) vào tweak YTLite để tải video YouTube chất lượng cao (1080p, 720p, 480p, 360p) và Audio M4A mà không cần bất kỳ dependency nặng nề nào.

**Architecture:** Sử dụng `NSURLSession` tải đồng thời Video DASH (.mp4) và Audio DASH (.m4a), ghép luồng tức thì (Passthrough Muxing) bằng `AVMutableComposition` + `AVAssetExportSession`, sau đó lưu vào Album Ảnh (`PHPhotoLibrary`) hoặc mở Share Sheet hệ thống.

**Tech Stack:** Objective-C, Theos / Logos, iOS SDK (UIKit, Foundation, AVFoundation, Photos, CoreMedia).

## Global Constraints

- Không dùng thư viện ngoài (như FFmpeg), tận dụng 100% AVFoundation gốc của iOS.
- Luôn dọn dẹp các tệp tạm trung gian trong `NSTemporaryDirectory()` sau khi hoàn thành hoặc lỗi.
- Đảm bảo tương thích tốt cả môi trường Rootless, Roothide và Sideloaded IPA.

---

### Task 1: Update Makefile Framework Dependencies

**Files:**
- Modify: `Makefile:16`

**Interfaces:**
- Consumes: Existing Makefile configuration
- Produces: Makefile with `Photos`, `AVFoundation`, `CoreMedia` linked

- [x] **Step 1: Modify Makefile to link required frameworks**

Cập nhật `Makefile`:
```makefile
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation SystemConfiguration Photos AVFoundation CoreMedia
```

- [x] **Step 2: Verify Makefile syntax**

Kiểm tra nội dung `Makefile` để đảm bảo không lỗi format.

---

### Task 2: Implement Core Download & Muxing Engine (`YTLDownloadManager`)

**Files:**
- Create: `Utils/YTLDownloadManager.h`
- Create: `Utils/YTLDownloadManager.m`

**Interfaces:**
- Consumes: iOS SDK (`AVFoundation`, `Photos`, `UIKit`, `Foundation`)
- Produces: `YTLDownloadManager` singleton với các method:
  - `+ (instancetype)sharedManager;`
  - `- (void)showDownloadMenuForPlayerResponse:(id)playerResponse parentViewController:(UIViewController *)parentVC;`
  - `- (void)downloadVideoFormat:(id)videoFormat audioFormat:(id)audioFormat title:(NSString *)title parentViewController:(UIViewController *)parentVC;`

- [x] **Step 1: Create `Utils/YTLDownloadManager.h`**

```objc
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

@interface YTLDownloadFormat : NSObject
@property (nonatomic, assign) int itag;
@property (nonatomic, copy) NSString *qualityLabel;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, assign) long long contentLength;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) BOOL isAudio;
@end

@interface YTLDownloadManager : NSObject <NSURLSessionDownloadDelegate>

+ (instancetype)sharedManager;

- (void)showDownloadMenuWithFormats:(NSArray<YTLDownloadFormat *> *)formats
                              title:(NSString *)title
               parentViewController:(UIViewController *)parentVC;

- (void)downloadVideoFormat:(YTLDownloadFormat *)videoFormat
                audioFormat:(YTLDownloadFormat *)audioFormat
                      title:(NSString *)title
       parentViewController:(UIViewController *)parentVC;

@end
```

- [x] **Step 2: Create `Utils/YTLDownloadManager.m` with download, progress HUD, passthrough muxing, and save to Photos/ShareSheet**

Implement logic:
- `NSURLSessionDownloadTask` tải luồng Video và Audio.
- Progress Alert / HUD hiển thị phần trăm hoàn thành.
- Muxing bằng `AVMutableComposition`:
  ```objc
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
  AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
  ```
- Export bằng `AVAssetExportSession` với `presetName = AVAssetExportPresetPassthrough`.
- Lưu vào `PHPhotoLibrary` và mở `UIActivityViewController`.

---

### Task 3: Hook Video Player & Intercept Download Action in `YTLite.x`

**Files:**
- Modify: `YTLite.x`
- Modify: `YTLite.h`

**Interfaces:**
- Consumes: `YTLDownloadManager` từ Task 2, `YTIPlayerResponse` / `YTIStreamingData` từ YouTube.
- Produces: Intercepted Download button click to display `YTLDownloadManager` action sheet.

- [x] **Step 1: Import `YTLDownloadManager.h` and add interfaces in `YTLite.h`**

Khai báo các class YouTube liên quan đến format (`YTIStreamingData`, `YTIFormatStream`, `YTIPlayerResponse`, v.v.).

- [x] **Step 2: Hook Download button & Action bar in `YTLite.x`**

Hook vào controller phát video khi người dùng bấm nút Download:
- Trích xuất `streamingData.adaptiveFormats` và `streamingData.formats`.
- Khởi tạo danh sách `YTLDownloadFormat`.
- Gọi `[[YTLDownloadManager sharedManager] showDownloadMenuWithFormats:formats title:videoTitle parentViewController:topVC];`.

---

### Task 4: Settings Integration & User Preferences

**Files:**
- Modify: `Settings.x`
- Modify: `Utils/YTLUserDefaults.m`

**Interfaces:**
- Consumes: Preference key `downloadManager`
- Produces: Settings toggle cho Download Manager

- [x] **Step 1: Add default setting key in `Utils/YTLUserDefaults.m`**
- [x] **Step 2: Add Download Manager switch in `Settings.x`**

---

### Task 5: Compilation and Verification

**Files:**
- All modified files

- [x] **Step 1: Check code syntax and imports**
- [x] **Step 2: Test building the package with Theos**
