# Kế hoạch Triển khai Module Download Chất lượng cao cho YouTube Plus (YTLite)

## 1. Mục tiêu
Giải quyết dứt điểm vấn đề nút Download bị giới hạn bởi popup Premium trên YouTube iOS 21.34.3:
- Cho phép người dùng tải video độ phân giải cao: 1080p (Full HD), 720p (HD), 480p, 360p kèm âm thanh chất lượng cao.
- Cho phép trích xuất tải riêng tệp âm thanh M4A (Audio HQ).
- Cho phép tải ảnh bìa (Thumbnail) chất lượng gốc.
- Cho phép sao chép liên kết video nhanh.
- Lưu video trực tiếp vào Cuộn Camera (Photos / PHPhotoLibrary) và mở Share Sheet để người dùng có thể Lưu vào Tệp (Files), AirDrop.
- Hoàn toàn độc lập với máy chủ YouTube Offline của Google, không phụ thuộc tài khoản Premium, không bao giờ bị popup Premium chặn.

## 2. Thiết kế Kỹ thuật (Architecture)

### 2.1. Thành phần YTLDownloadManager (`Utils/YTLDownloadManager.h` & `Utils/YTLDownloadManager.m`)
- **Singleton**: `[YTLDownloadManager sharedManager]` quản lý toàn bộ vòng đời tải xuống và hiển thị giao diện.
- **Trích xuất thông tin Stream**:
  - Truy xuất `YTPlayerViewController` -> `playerResponse` -> `playerData` (`YTIPlayerResponse`) -> `streamingData` (`YTIStreamingData`).
  - Lấy danh sách `adaptiveFormatsArray` (luồng video H.264 mp4 1080p/720p/480p/360p và luồng âm thanh AAC m4a) và `formatsArray` (luồng muxed).
- **Giao diện Action Sheet**:
  - Khi bấm nút Download, hiển thị `UIAlertController` kiểu `ActionSheet` đẹp mắt, hỗ trợ đầy đủ iPad (popover anchor) và iPhone.
  - Các tùy chọn rõ ràng: Tải Video 1080p, 720p, 480p, 360p, Tải Âm thanh M4A, Tải Thumbnail, Sao chép link.
- **Cơ chế Tải & Mux Luồng (Parallel Download & Passthrough Muxing)**:
  - Tải song song luồng Video và Audio thông qua `NSURLSessionDownloadTask`.
  - Mux kết hợp video + audio bằng `AVMutableComposition` và `AVAssetExportSession` với preset `AVAssetExportPresetPassthrough`.
  - Không cần re-encode CPU-heavy, mux xong trong 1 giây, giữ nguyên 100% chất lượng gốc.
- **Lưu trữ & Xuất file**:
  - Ghi thẳng vào `PHPhotoLibrary` (`PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:`).
  - Kèm mở `UIActivityViewController` (Share Sheet) để hỗ trợ lưu vào ứng dụng Tệp (Files app).
- **Thông báo Toast HUD**:
  - Hiển thị Toast thông báo trạng thái tải (Đang tải, Đang ghép file, Hoàn tất, Thất bại) nhẹ nhàng, không che khuất trải nghiệm xem video.

### 2.2. Hooking trong `YTLite.x`
- Hook `ASDisplayNode`:
  Gắn `UITapGestureRecognizer` với `cancelsTouchesInView = YES` vào view có `accessibilityIdentifier = @"id.ui.add_to.offline.button"` để chặn triệt để gesture mặc định của YouTube.
- Hook `YTOfflineQualitySelectionAlertView`:
  Chặn phương thức `show`, ngăn chặn popup chọn quality của YouTube (nơi hiện popup Premium), chuyển hướng sang Download Sheet của tweak.
- Hook `YTOfflineVideoEndpointCommandHandler` & `YTOfflineVideoEndpointCommandHandlerImpl`:
  Chặn lệnh offline của YouTube, chuyển hướng sang Download Sheet.
- Hook `YTPlayerViewController`:
  Lưu `gCurrentPlayerVC` để luôn lấy được video và stream hiện hành.

### 2.3. Cấu hình Cài đặt (`Settings.x` & `Utils/YTLUserDefaults.m`)
- Thêm khóa `downloadManager` vào `YTLUserDefaults` mặc định là `@YES`.
- Thêm switch `DownloadManager` vào menu Cài đặt YouTube Plus.

### 2.4. `Makefile`
- Bổ sung framework `Photos` vào `$(TWEAK_NAME)_FRAMEWORKS`.

## 3. Kế hoạch Kiểm chứng (Verification)
- Kiểm tra biên dịch cục bộ Objective-C qua `xcrun -sdk iphoneos clang -arch arm64`.
- Đảm bảo cú pháp và kiểu dữ liệu chuẩn xác, không có cảnh báo hay lỗi biên dịch.
- Đẩy commit lên remote để GitHub Actions CI tự động đóng gói IPA `YouTubePlus`.
