# Đặc tả Kỹ thuật Toàn diện Nhánh main_manual (YTLite)

Tài liệu này tổng hợp toàn bộ thông số và cơ chế kỹ thuật thực tế đang hoạt động trên nhánh `main_manual` của dự án YTLite.

---

## 1. Chặn Quảng Cáo & Tối Ưu Feed (Ad Removal & Feed Performance)

### 1.1. Lọc dữ liệu tận gốc tại Data Source Layer
- **Hook `YTIItemSectionRenderer - (NSMutableArray *)contentsArray`**:
  - Quét và loại bỏ trực tiếp các phần tử quảng cáo ra khỏi mảng dữ liệu trước khi `UICollectionView` nhận mô hình hiển thị.
  - Các đối tượng bị loại trừ: `promotedVideoRenderer`, `compactPromotedVideoRenderer`, `promotedVideoInlineMutedRenderer`, và các `elementRenderer` chứa dữ liệu logging quảng cáo.
- **Hook `YTSectionListViewController - (void)loadWithModel:(YTISectionListRenderer *)model`**:
  - Quét danh sách section. Nếu một section chỉ chứa quảng cáo và danh sách phần tử trở thành rỗng sau khi lọc (`items.count == 0`), section đó bị loại bỏ hoàn toàn, tránh hiển thị tiêu đề trống hoặc khoảng đen (*black space*) trên Home Feed.

### 1.2. Phòng vệ tầng View Layer
- **Hook `YTIElementRenderer - (NSData *)elementData`**:
  - Trả về `nil` khi `compatibilityOptions.hasAdLoggingData == YES`.
  - Quét mô tả chuỗi của element theo danh sách từ khóa nhận diện (`brand_promo`, `product_carousel`, `promoted_sparkles`, `ad_placement`, `shelf_ad`, `banner_ad`, v.v.). Nếu khớp, trả về `nil` để Element Parser không tạo cell rác.

### 1.3. Tối ưu hóa hiệu năng cuộn (Scroll Performance)
- **Single-pass Sanitization qua Runtime Association**:
  - Sử dụng `objc_setAssociatedObject` gắn cờ `kYTLItemSectionFilteredKey` lên instance của `YTIItemSectionRenderer` sau lần xử lý đầu tiên.
  - Các lần truy cập tiếp theo vào `contentsArray` đạt độ phức tạp $O(1)$, loại bỏ việc quét lại dữ liệu trên Main Thread, duy trì tốc độ khung hình 60/120fps.
- **Lazy Evaluation**: Chỉ gọi `[self description]` khi các cờ boolean nhanh (`adLoggingData`) chưa đủ để kết luận.

### 1.4. Tối ưu hóa phản hồi chạm (Touch Responsiveness)
- **Hook `YTMainAppVideoPlayerOverlayView - (void)setSeekAnywherePanGestureRecognizer:(UIPanGestureRecognizer *)panRecognizer`**:
  - Thiết lập thuộc tính trên gesture recognizer:
    ```objc
    panRecognizer.delaysTouchesBegan = NO;
    panRecognizer.delaysTouchesEnded = NO;
    panRecognizer.cancelsTouchesInView = NO;
    ```
  - Triệt tiêu hoàn toàn độ trễ tiếp nhận cảm ứng khi người dùng bấm mở toàn màn hình (fullscreen) hoặc tương tác với các nút điều khiển trên video player.

---

## 2. Hệ Thống Tải Video (Download Engine)

### 2.1. Trích xuất Ngữ cảnh Phát & URL Luồng (Playback Context Extraction)
- **Lấy thông tin từ Player RAM**:
  - Hook `YTCorePlaybackController -playbackController:didActivateVideo:withPlaybackData:`, `YTSingleVideoController -playerStatusDidChange:`, và `YTPlayerViewController`.
  - Trích xuất `hlsManifestUrl` từ `playerResponse.streamingData`. Luồng HLS này được YouTube cấp chữ ký session hợp lệ của ứng dụng, không bị hạn chế bởi BotGuard hoặc Cipher biến đổi.
- **InnerTube API Fallback**:
  - Nếu `streamingData` từ RAM không chứa URL HLS (như khi tải từ Preview Home Feed), hệ thống gửi yêu cầu `POST` trực tiếp tới endpoint `/youtubei/v1/player` với client payload `ANDROID_TESTSUITE` hoặc `IOS` để lấy `hlsManifestUrl`.

### 2.2. Phân giải HLS Master Playlist (`YTLM3U8Parser`)
- **Phân tích cú pháp M3U8**:
  - Tải tệp Master Manifest `.m3u8` qua `NSURLSession`.
  - Quét các khối `#EXT-X-STREAM-INF:` để lấy thông số `RESOLUTION` (1080p, 720p, 480p, 360p), `BANDWIDTH`, `FRAME-RATE`, và đường dẫn URI của variant video.
  - Quét các khối `#EXT-X-MEDIA:TYPE=AUDIO` để bóc tách luồng âm thanh độc lập (AAC) qua thuộc tính `URI` và nhóm theo `GROUP-ID`.
- **Lọc và Ưu tiên Codec**:
  - Ưu tiên chọn luồng video codec `avc1` (H.264) trước `vp09` hoặc `av01` để đảm bảo tương thích 100% với Apple Photos (`PHPhotoLibrary`) và bộ giải mã phần cứng Apple.

### 2.3. Xử lý & Ghép luồng Media (`YTLDownloadManager` & `FFmpegKit`)
- **Pipeline Ghép luồng FFmpegKit**:
  - Sử dụng API bất đồng bộ `FFmpegKit executeWithArgumentsAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:`.
  - Lệnh thực thi:
    ```bash
    -y -protocol_whitelist file,http,https,tcp,tls,crypto -i "<video_m3u8_url>" -i "<audio_m3u8_url>" -c:v copy -c:a aac -bsf:a aac_adtstoasc -shortest "<output_path.mp4>"
    ```
  - Sao chép trực tiếp luồng hình ảnh H.264 (`-c:v copy`) và chuẩn hóa luồng âm thanh AAC (`-c:a aac -bsf:a aac_adtstoasc`) vào container MP4 tiêu chuẩn mà không cần re-encode toàn bộ video, bảo toàn chất lượng gốc và tối ưu tốc độ xử lý.
- **Adaptive Stream Fallback**:
  - Đối với các video cung cấp URL nhị phân trực tiếp, hệ thống tải song song video và audio qua `NSURLSessionDownloadTask`, sau đó ghép luồng qua `AVMutableComposition` với `AVAssetExportPresetPassthrough`.

### 2.4. Giao diện Người dùng & Phản hồi Tiến trình (`YTLDownloadProgressHUD`)
- **Cấu trúc Giao diện**:
  - View độc lập dạng Pill UI với hiệu ứng Dark Blur (`UIBlurEffectStyleSystemUltraThinMaterialDark`), bo góc 18pt, hiển thị nổi tại cạnh trên màn hình (dưới Safe Area).
  - Bao gồm: Biểu tượng trạng thái, nhãn trạng thái thời gian thực (độ phân giải, % tiến độ, dung lượng đã tải / tổng dung lượng MB), thanh `UIProgressView` và nút Hủy (Cancel).
- **Cập nhật Luồng**:
  - Thống kê tiến trình từ `withStatisticsCallback` của FFmpegKit được đồng bộ trực tiếp lên Main Queue và phản ánh tức thì vào HUD. Tự động ẩn có hiệu ứng mờ dần khi hoàn tất hoặc hủy bỏ.

### 2.5. Điểm Kích Hoạt & An Toàn Giao Diện (UI Hooking & Runtime Safety)
- **Menu 3 chấm (Action Sheet) ở Watch Page, Home Feed & Preview**:
  - Hook `YTDefaultSheetController -addAction:`: Nhận diện action tải xuống (`isDownloadAction` qua identifier `@"7"`, `id.ui.download_action`, accessibility label hoặc trích xuất tiêu đề đa ngôn ngữ từ chuỗi, `NSAttributedString`, `YTIFormattedString`). Đảm bảo duy nhất 1 nút tải bằng cờ `ytl_has_download`. Trích xuất và bảo toàn icon gốc của YouTube (`gCachedDownloadIcon`), khởi tạo `YTActionSheetAction` mới chuẩn mực (style 0 hoặc identifier riêng `id.ytlite.download`), tuyệt đối không gán identifier hệ thống `@"7"` để tách biệt hoàn toàn với Command Router nội bộ của YouTube.
  - Handler của action tải áp dụng độ trễ an toàn `dispatch_after(0.35s)` để UIKit hoàn tất 100% animation đóng Action Sheet gốc của YouTube trước khi kích hoạt `handleDownloadForVideoId:`.
  - Bộ cấp icon đa tầng (`getDownloadIcon`): Ưu tiên `gCachedDownloadIcon` đã lấy từ YouTube -> quét danh sách asset bundle -> SF Symbol `arrow.down.to.line` (iOS 13+) -> vẽ vector 24x24 CoreGraphics runtime, đảm bảo nút tải luôn có icon hiển thị template chuẩn.
- **Nút Tải tại Watch Page (Offline Button)**:
  - Hook `YTOfflineVideoEndpointCommandHandler` và `YTOfflineVideoEndpointCommandHandlerImpl`: Khi `downloadManager` bật, toàn bộ các phương thức thực thi endpoint offline được chặn và điều hướng sang `handleOfflineEndpointCommand`, luôn return mà không gọi `%orig;` để triệt tiêu hoàn toàn nguy cơ sập ứng dụng (crash) do engine offline của YouTube.
  - Hook `YTOfflineQualitySelectionAlertView` và `YTOfflineVideoQualitySelectorViewController`: Điều hướng ngầm trong `viewDidAppear:` và chỉ gọi kích hoạt tải trong completion block sau khi đóng modal thành công, tuyệt đối không can thiệp trong `viewWillAppear:` nhằm bảo vệ UIKit transition coordinator.
- **An Toàn Trình Bày Giao Diện & Điều Hướng (UIKit Safety)**:
  - Hàm `getTopViewController`: Phân tách các modal tạm thời (`Sheet`, `Alert`, `Dialog`, `Popup`) đang chuẩn bị đóng để giữ nguyên view controller nền hợp lệ.
  - Hàm `presentActionSheetSafely`: Ưu tiên xác định presenter qua `[YTUIUtils topViewControllerForPresenting]` -> `activePlayerViewController` -> `getTopViewController`. Tuyệt đối không can thiệp ép dismiss modal cũ mà tự động hoãn (0.25s) để UIKit hoàn tất chu kỳ chuyển cảnh tự nhiên nếu controller đang bận. Cấu hình tự động `popoverPresentationController` với sourceView/sourceRect và tọa độ fallback chính giữa màn hình, bảo đảm an toàn 100% trên iPad.
  - Trích xuất định danh video an toàn (`depth <= 2`): Giới hạn độ sâu đệ quy trên các Protobuf message descriptors để triệt tiêu nguy cơ tràn ngăn xếp (Stack Overflow).
  - Hàm `safePerform`: Sử dụng `NSMethodSignature` kiểm tra trả về kiểu Object (`@`) trước khi gọi selector, loại bỏ nguy cơ `EXC_BAD_ACCESS` trên kiến trúc ARM64 do gọi nhầm selector trả về struct/scalar.

### 2.6. Xuất Tệp & Lưu Trữ
- **Lưu vào Thư viện Ảnh (Camera Roll)**:
  - Kiểm tra quyền truy cập `PHPhotoLibrary`.
  - Thực hiện lưu tệp MP4 qua `PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:`.
- **Chia sẻ qua Share Sheet**:
  - Mở `UIActivityViewController` chia sẻ tệp MP4 ra bên ngoài (AirDrop, Tệp / Files, VLC, ứng dụng nhắn tin).

---

## 3. Tích Hợp Hệ Thống & Quy Trình Đóng Gói (Build Pipeline & Integration)

### 3.1. Framework Ngoại Vi & Cấu Hình Theos
- **Script Nạp Framework (`scripts/setup_ffmpeg.sh`)**:
  - Tự động tải gói `ffmpegkit.xcframework` (phiên bản v6.0 iOS), giải nén và trích xuất slice `ios-arm64` vào thư mục `Frameworks/ffmpegkit.framework`.
  - Thiết lập layout runtime rootless tại `layout/var/jb/Library/Frameworks/ffmpegkit.framework` để dyld nạp thư viện động trên thiết bị jailbreak.
- **Cấu hình `Makefile`**:
  - Thêm search path: `_LDFLAGS += -F./Frameworks`
  - Liên kết framework: `_EXTRA_FRAMEWORKS += ffmpegkit`
  - Bổ sung system frameworks: `VideoToolbox AudioToolbox CoreMedia CoreMotion`
  - Bổ sung thư viện liên kết: `-lz -lbz2 -liconv -lc++`

### 3.2. CI/CD Tự Động (GitHub Actions)
- **Workflow Đóng gói (`.github/workflows/build_deb_from_source.yml`)**:
  - Chạy trên môi trường `macos-14` / `ubuntu-latest`.
  - Tự động cài đặt Theos, chạy `scripts/setup_ffmpeg.sh` để chuẩn bị framework, biên dịch mã nguồn Objective-C/Logos và xuất artifact gói cài đặt `.deb`.
- **Workflow Cache Framework (`.github/workflows/_build_tweaks.yml`)**:
  - Thiết lập cơ chế cache thư mục `Frameworks/` theo khóa hash của script nạp, tối ưu thời gian build CI.

### 3.3. Tùy Biến Bundle & Bản Địa Hóa (Localization)
- **Script Vá Tự Động (`.github/scripts/patch_ytplus.py`)**:
  - Đồng bộ tên hiển thị `YouTubePlus`, cập nhật thuộc tính bundle, cấu hình icon và các nút điều khiển media trên màn hình khóa.
- **Tài Nguyên Bundle (`layout/Library/Application Support/YTLite.bundle`)**:
  - Chứa tệp tài nguyên hình ảnh (`Assets.car`), âm thanh mở rộng (`SponsorAudio.m4a`).
  - Hỗ trợ đa ngôn ngữ đầy đủ với các tệp `Localizable.strings` cho 14+ ngôn ngữ (Tiếng Việt, Tiếng Anh, Tiếng Pháp, Tiếng Trung, Tiếng Nhật, Tiếng Hàn, Tiếng Nga, Tiếng Tây Ban Nha, Tiếng Ả Rập, v.v.).
