# Technical Specification: Native AVFoundation Download Manager for YTLite

- **Status:** In Review
- **Date:** 2026-08-30
- **Author:** Antigravity & anh guộc
- **Target Repository:** `tunglt1810/YTLite`

---

## 1. Objective & Scope

Tích hợp trực tiếp module **Download Manager** vào mã nguồn mở của `YTLite` (Objective-C tweak) cho phép tải video YouTube chất lượng cao (1080p Full HD, 720p HD, 480p, 360p) và trích xuất Audio (M4A/AAC), sau đó tự động ghép luồng (Muxing) thông qua `AVFoundation` gốc của iOS và lưu vào Thư viện ảnh (`PHPhotoLibrary`) hoặc mở Share Sheet.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      YouTube Player UI                      │
│   (Hook Download Button: id.ui.add_to.offline.button)      │
└──────────────────────────────┬──────────────────────────────┘
                               │ User taps Download
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                   YTLDownloadManager (UI)                   │
│   - Intercepts native offline download prompt               │
│   - Extracts streaming formats from YTIPlayerResponse       │
│   - Displays ActionSheet with resolutions & file sizes      │
└──────────────────────────────┬──────────────────────────────┘
                               │ User selects quality (e.g., 1080p MP4)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 YTLDownloadManager (Engine)                 │
│   - Task 1: Download Video DASH Stream (.mp4)               │
│   - Task 2: Download Best Audio DASH Stream (AAC .m4a)      │
│   - Shows Progress HUD / Alert                              │
└──────────────────────────────┬──────────────────────────────┘
                               │ Both downloads complete
                               ▼
┌─────────────────────────────────────────────────────────────┐
│             AVFoundation Muxing (Passthrough)               │
│   - AVMutableComposition + AVAssetExportSession             │
│   - Combines Video + Audio tracks in ~1-2s (Zero re-encode) │
└──────────────────────────────┬──────────────────────────────┘
                               │ Muxed output file created
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                      Export & Storage                       │
│   - Save directly to Photos Album (PHPhotoLibrary)          │
│   - Present UIActivityViewController (Share / Files)        │
│   - Clean up temporary files (.tmp / NSTemporaryDirectory)  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Design

### 3.1. Stream Extraction & Format Resolution
* **Target Controller:** Hook vào `YTSingleVideoController` / `YTPlayerViewController` để truy xuất `YTPlayerResponse` $\rightarrow$ `YTIStreamingData`.
* **Adaptive Formats Parsing:**
  * Lọc danh sách `adaptiveFormats` cho các luồng MP4 (`video/mp4; codecs="avc1..."` hoặc `"av01..."`):
    * `1080p` (itag 137, 299, 399)
    * `720p` (itag 136, 298, 398)
    * `480p` (itag 135, 397)
    * `360p` (itag 134, 396)
  * Lọc luồng Audio AAC chất lượng cao nhất (`audio/mp4`, itag 140 - 128kbps AAC).
  * Ước tính dung lượng file: `contentLength` (bytes) format sang MB/GB để hiển thị trên UI menu.

### 3.2. Download Engine (`YTLDownloadManager`)
* Quản lý tiến trình tải ngầm qua `NSURLSessionDownloadDelegate`.
* Hỗ trợ tải song song 2 luồng: Video stream và Audio stream.
* Cập nhật phần trăm tiến độ tải trực tiếp lên màn hình (HUD / Toast Notification).

### 3.3. Muxing Engine (`AVMutableComposition`)
* Tạo `AVMutableComposition` chứa 2 tracks:
  1. `AVMutableCompositionTrack` loại `AVMediaTypeVideo` gắn video stream tạm thời.
  2. `AVMutableCompositionTrack` loại `AVMediaTypeAudio` gắn audio stream tạm thời.
* Xuất file bằng `AVAssetExportSession` với cấu hình:
  * `presetName = AVAssetExportPresetPassthrough` (sao chép trực tiếp các gói dữ liệu mà không cần re-encode CPU, tốc độ muxing cực nhanh và giữ nguyên 100% chất lượng gốc).
  * `outputFileType = AVFileTypeMPEG4`.

### 3.4. Output & Permissions
* Xin quyền `PHPhotoLibrary` (`PHAccessLevelAddOnly` hoặc `PHPhotoLibrary authorizationStatus`).
* Sau khi muxing hoàn tất:
  * Tự động lưu vào Album Camera Roll (`PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:`).
  * Hiển thị `UIActivityViewController` để người dùng có thể chia sẻ trực tiếp (Lưu vào Tệp / AirDrop).
  * Xóa các file `.tmp` video/audio trung gian sau khi lưu xong để không tốn bộ nhớ thiết bị.

---

## 4. Build Configuration & Dependencies

### 4.1. Frameworks trong Makefile
Bổ sung các framework có sẵn của iOS SDK vào Makefile:
```makefile
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation SystemConfiguration Photos AVFoundation CoreMedia
```

### 4.2. File Changes
1. **[NEW] `Utils/YTLDownloadManager.h` & `Utils/YTLDownloadManager.m`**:
   - Engine quản lý tải, ghép luồng và lưu trữ.
2. **[MODIFY] `YTLite.x`**:
   - Hook nút tải trên thanh công cụ phát video (`id.ui.add_to.offline.button` / Menu) để mở `YTLDownloadManager`.
3. **[MODIFY] `Settings.x`**:
   - Bổ sung tuỳ chọn bật/tắt Download Manager và tuỳ chọn hành động sau khi tải (Lưu vào Photos / Mở Share Sheet).
4. **[MODIFY] `Makefile`**:
   - Thêm các framework `Photos AVFoundation CoreMedia`.

---

## 5. Verification Plan

### 5.1. Build Verification
- Chạy `make clean package DEBUG=0 FINALPACKAGE=1` kiểm tra biên dịch Theos trên macOS/CI không phát sinh lỗi hoặc cảnh báo thiếu framework.

### 5.2. Functional Verification
- Bấm nút Download dưới video YouTube $\rightarrow$ Menu chọn độ phân giải hiển thị đúng dung lượng.
- Chọn tải `1080p` $\rightarrow$ Tải cả 2 luồng video + audio $\rightarrow$ Muxing thành công thành 1 file MP4 có đầy đủ tiếng và hình.
- File xuất hiện trong Photos / File app và phát bình thường.
