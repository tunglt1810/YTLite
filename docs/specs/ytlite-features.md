# Đặc tả Kỹ thuật YTLite (Nhánh main_manual)

Tài liệu đặc tả kiến trúc, các module chức năng và cấu hình triển khai trên nhánh `main_manual`.

---

## 1. Chặn Quảng Cáo & Tối Ưu Giao Diện

### 1.1. Data Source Layer
- **Hook `YTIItemSectionRenderer - (NSMutableArray *)contentsArray`**:
  - Quét và loại bỏ các phần tử quảng cáo: `promotedVideoRenderer`, `compactPromotedVideoRenderer`, `promotedVideoInlineMutedRenderer`, và các `elementRenderer` chứa dữ liệu logging quảng cáo.
- **Hook `YTSectionListViewController - (void)loadWithModel:(YTISectionListRenderer *)model`**:
  - Quét danh sách section. Loại bỏ hoàn toàn section nếu danh sách phần tử bên trong rỗng (`items.count == 0`) sau khi lọc.

### 1.2. View Layer
- **Hook `YTIElementRenderer - (NSData *)elementData`**:
  - Trả về `nil` khi `compatibilityOptions.hasAdLoggingData == YES`.
  - Quét mô tả chuỗi của element theo danh sách từ khóa: `brand_promo`, `product_carousel`, `promoted_sparkles`, `ad_placement`, `shelf_ad`, `banner_ad`. Trả về `nil` khi khớp.

### 1.3. Hiệu Năng Cuộn
- **Runtime Association Caching**:
  - Sử dụng `objc_setAssociatedObject` gắn cờ `kYTLItemSectionFilteredKey` lên instance `YTIItemSectionRenderer` sau lần xử lý đầu tiên.
  - Các lần truy cập tiếp theo vào `contentsArray` trả về mảng đã lọc với độ phức tạp $O(1)$.

### 1.4. Phản Hồi Cảm Ứng Player
- **Hook `YTMainAppVideoPlayerOverlayView - (void)setSeekAnywherePanGestureRecognizer:(UIPanGestureRecognizer *)panRecognizer`**:
  - Thiết lập các cờ điều khiển cử chỉ:
    ```objc
    panRecognizer.delaysTouchesBegan = NO;
    panRecognizer.delaysTouchesEnded = NO;
    panRecognizer.cancelsTouchesInView = NO;
    ```

---

## 2. Hệ Thống Tải Media

### 2.1. Trích Xuất Luồng Phát
- **Trích xuất từ Bộ nhớ Phát (RAM)**:
  - Hook `YTCorePlaybackController -playbackController:didActivateVideo:withPlaybackData:`, `YTSingleVideoController -playerStatusDidChange:`, và `YTPlayerViewController`.
  - Lấy `hlsManifestUrl` từ `playerResponse.streamingData`.
- **InnerTube API Fallback**:
  - Gửi yêu cầu HTTP `POST` tới endpoint `/youtubei/v1/player` với client payload `ANDROID_TESTSUITE` hoặc `IOS` để lấy `hlsManifestUrl` khi bộ nhớ RAM không chứa dữ liệu luồng.

### 2.2. Phân Giải HLS Master Playlist (`YTLM3U8Parser`)
- **Phân tích cú pháp M3U8**:
  - Tải Master Playlist `.m3u8` qua `NSURLSession`.
  - Phân tích thẻ `#EXT-X-STREAM-INF:` để trích xuất `RESOLUTION` (1080p, 720p, 480p, 360p), `BANDWIDTH`, `FRAME-RATE`, và URI của luồng video.
  - Phân tích thẻ `#EXT-X-MEDIA:TYPE=AUDIO` để trích xuất URI luồng âm thanh AAC độc lập theo `GROUP-ID`.
- **Thứ tự ưu tiên Codec**:
  - Luồng video sử dụng codec `avc1` (H.264) được ưu tiên trước `vp09` và `av01` để đảm bảo tương thích với `PHPhotoLibrary` và bộ giải mã phần cứng Apple.

### 2.3. Xử Lý & Ghép Luồng (`YTLDownloadManager` & `FFmpegKit`)
- **Pipeline FFmpegKit**:
  - Thực thi lệnh bất đồng bộ qua `[FFmpegKit executeWithArgumentsAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:]`:
    ```bash
    -y -protocol_whitelist file,http,https,tcp,tls,crypto -i "<video_m3u8_url>" -i "<audio_m3u8_url>" -c:v copy -c:a aac -bsf:a aac_adtstoasc -shortest "<output_path.mp4>"
    ```
  - Sao chép luồng H.264 trực tiếp (`-c:v copy`) và đóng gói luồng âm thanh AAC (`-c:a aac -bsf:a aac_adtstoasc`) vào container MP4.
- **Adaptive Stream Fallback**:
  - Đối với các định dạng không dùng HLS, hệ thống tải song song video/audio bằng `NSURLSessionDownloadTask` và ghép qua `AVMutableComposition` (`AVAssetExportPresetPassthrough`).

### 2.4. Giao Diện Tiến Trình Tải (`YTLDownloadProgressHUD`)
- **Cấu trúc UI**:
  - Pill view nổi tại cạnh trên màn hình với hiệu ứng làm mờ `UIBlurEffectStyleSystemUltraThinMaterialDark`, góc bo 18pt.
  - Thành phần: Biểu tượng trạng thái, nhãn văn bản (độ phân giải, phần trăm, dung lượng đã tải / tổng dung lượng), thanh `UIProgressView` và nút Hủy.
- **Đồng bộ Tiến trình**:
  - Nhận dữ liệu thống kê từ callback của FFmpegKit và cập nhật lên Main Queue.

### 2.5. Điểm Kích Hoạt Download
- **Menu 3 chấm (Action Sheet)**:
  - Hook `YTDefaultSheetController` (`addAction:`, `setActions:`).
  - Khi `downloadManager` bật: giữ nguyên nút download gốc của YouTube trong Action Sheet. Tại `addAction:`, trích xuất và cache icon gốc qua `normalizeIcon24` (canvas 24x24 pt), đồng thời trích xuất `videoId` từ `serviceEndpoint.offlineVideoEndpoint` để cập nhật `lastActiveVideoID` trên `YTLDownloadManager`.
  - Khi `removeDownloadMenu` bật: loại bỏ hoàn toàn nút download khỏi sheet qua `addAction:` và `setActions:`.
  - Nhận diện nút download gốc (`isDownloadAction`): Kiểm tra `accessibilityIdentifier == "7"`, endpoint chứa `offlineVideoEndpoint`/`downloadVideoEndpoint`, class name endpoint chứa `"Offline"`/`"Download"`, quét toàn bộ chuỗi trích xuất đa tầng qua `extractAllStringsFromAction` đối chiếu từ khóa download/offline đa ngôn ngữ.
- **Offline Endpoint Handlers**:
  - Hook `YTOfflineVideoEndpointCommandHandler` và `YTOfflineVideoEndpointCommandHandlerImpl`:
    - Chặn các phương thức `executeWithCommand:...` và điều hướng sang `[[YTLDownloadManager sharedManager] handleOfflineEndpointCommand:entry:fromView:]`.
    - Bọc `@try ... @catch` toàn bộ. Không gọi `%orig` và không gọi khối `completionBlock`.
  - Hook `YTOfflineQualitySelectionAlertView` và `YTOfflineVideoQualitySelectorViewController`: Đặt ẩn view trong `viewDidLoad`, dismiss controller trong `viewDidAppear:`, sau đó gọi `handleDownloadForVideoId:`.
- **Điều hướng Presenter**:
  - Hàm `findBestPresenter`: Duyệt cây `UIViewController` từ `activeWindow.rootViewController` đến leaf controller có `view.window != nil` và `!isBeingDismissed`.
  - Thiết lập thuộc tính `popoverPresentationController` với sourceView/sourceRect khi hiển thị `UIAlertController` trên iPad.

### 2.6. Xuất Dữ Liệu
- **Camera Roll**: Lưu tệp MP4 vào Thư viện ảnh qua `PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:`.
- **Hệ thống chia sẻ**: Kích hoạt `UIActivityViewController` chia sẻ tệp ra bên ngoài.

---

## 3. Đóng Gói & Tích Hợp Hệ Thống

### 3.1. Dynamic Frameworks (`scripts/setup_ffmpeg.sh`)
- Tải gói `ffmpeg-kit-ios-full` (v6.0 iOS), trích xuất slice `ios-arm64` của 8 dynamic frameworks vào `Frameworks/` và `layout/Library/Frameworks/`.
- Cấu trúc bundle tại `layout/Library/Frameworks/`: Gồm 8 Mach-O binaries (đã xử lý `strip -x`) và 8 tệp `Info.plist`. Toàn bộ headers, modules, tài liệu và mã ký cũ bị loại bỏ.
- Cấu hình `Makefile`:
  - Search path: `_LDFLAGS += -F./Frameworks`
  - Liên kết: `_EXTRA_FRAMEWORKS += ffmpegkit`
  - System frameworks: `VideoToolbox AudioToolbox CoreMedia CoreMotion`
  - Thư viện: `-lz -lbz2 -liconv -lc++`

### 3.2. CI/CD & Sideload Packaging
- Workflow GitHub Actions thực thi trên `macos-latest`.
- Tạo gói IPA bằng lệnh:
  ```bash
  cyan -uwef
  ```
  Bảo toàn cấu trúc iOS app bundle và load commands cho các công cụ sideload (AltStore, Sideloadly, TrollStore, iLoader).

### 3.3. Bản Địa Hóa
- Tệp `layout/Library/Application Support/YTLite.bundle`: Cung cấp tài nguyên giao diện và các tệp `Localizable.strings` hỗ trợ đa ngôn ngữ.
