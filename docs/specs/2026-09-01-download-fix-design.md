# Thiết kế kỹ thuật: Sửa lỗi Download Manager trên YouTube 21.34.3

## 1. Bối cảnh & Vấn đề

Trên phiên bản YouTube 21.34.3:
1. Khi bấm vào menu 3 chấm trên video (hoặc nút Download), tweak `YTLite` đang hook vào class cũ `YTOfflineVideoEndpointHandler` đã bị Google xoá bỏ/đổi tên.
2. Vì lệnh không bị chặn ở tầng Command Handler, YouTube tiếp tục đẩy luồng Offline gốc sang `YTOfflineVideoQualitySelectorViewController`.
3. Tweak phát hiện quality selector và gọi `dismissViewControllerAnimated:NO` (gây hiện tượng nháy màn hình vài frame), nhưng vì lệnh offline gốc chưa kết thúc và tài khoản không có YouTube Premium, YouTube kích hoạt luồng Upsell Coordinator và hiển thị popup yêu cầu mua YouTube Premium ("Require Premium").
4. Khi bấm menu 3 chấm từ Feed/Search, `currentActivePlayerVC` là `nil`, tweak không có `playerResponse` để phân tích danh sách stream nên không thể hiển thị menu tải.

---

## 2. Mục tiêu kỹ thuật

- Chặn triệt để luồng Offline gốc và ngăn 100% popup yêu cầu YouTube Premium.
- Loại bỏ hoàn toàn hiện tượng nháy màn hình.
- Hỗ trợ tải mượt mà từ mọi vị trí:
  - Nút Download / 3 chấm trong trình phát (Player).
  - Menu 3 chấm ngoài trang chủ (Feed), Tìm kiếm (Search), Kênh (Channel) bằng cách tự động truy vấn thông tin stream qua InnerTube Player API theo `videoId`.

---

## 3. Chi tiết kiến trúc & Luồng xử lý

```
[Người dùng ấn Download / 3 chấm]
               │
               ▼
[YTOfflineVideoEndpointCommandHandlerImpl] (Hooked)
               │
               ├──> Lấy videoId từ YTIOfflineVideoEndpoint
               │
               ├──> KHÔNG gọi %orig (Chặn đứt luồng Offline gốc + Popup Premium)
               │
               ▼
[YTLDownloadManager handleDownloadForVideoId:playerResponse:]
               │
       ┌───────┴────────────────────────────┐
       ▼                                    ▼
[Video đang phát trong Player]      [Video ở ngoài Feed/Search]
(videoId trùng khớp)                (playerResponse = nil hoặc khác videoId)
       │                                    │
       ▼                                    ▼
Dùng trực tiếp playerResponse       Hiện HUD loading "Đang lấy thông tin..."
       │                                    │
       │                            Gửi POST request tới InnerTube /player
       │                                    │
       │                            Nhận JSON & bóc tách streamingData
       │                                    │
       └────────────────┬───────────────────┘
                        │
                        ▼
       [Hiển thị ActionSheet chọn chất lượng]
         (1080p, 720p, 480p, 360p, M4A Audio)
                        │
                        ▼
             [Tiến hành tải & Muxing]
```

---

## 4. Các thay đổi chi tiết theo module

### 4.1. Tweak Hook (`YTLite.x`)

1. **Xoá bỏ hook lỗi thời**:
   - Xoá `%hook YTOfflineVideoEndpointHandler`.
2. **Hook Command Handler hiện đại**:
   - Hook `%hook YTOfflineVideoEndpointCommandHandlerImpl` và `%hook YTOfflineVideoEndpointCommandHandler`:
     - `- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender;`
     - `- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)fromView sender:(id)sender completionBlock:(id)completionBlock;`
   - Logic:
     - Trích xuất `videoId` từ `command.offlineVideoEndpoint.videoId` (hoặc `[command valueForKeyPath:@"offlineVideoEndpoint.videoId"]`).
     - Gọi `[[YTLDownloadManager sharedManager] handleDownloadForVideoId:videoId playerResponse:playerVC.playerResponse parentViewController:topVC]`.
     - `return;` (Không gọi `%orig` để triệt tiêu popup Premium).
3. **Cập nhật Fallback Selector**:
   - Đảm bảo `YTOfflineVideoQualitySelectorViewController` không gây xung đột nếu được gọi từ luồng phụ.

### 4.2. Download Manager (`Utils/YTLDownloadManager.h` & `Utils/YTLDownloadManager.m`)

1. **Bổ sung API điều phối**:
   ```objc
   - (void)handleDownloadForVideoId:(nullable NSString *)videoId
                     playerResponse:(nullable id)playerResponse
               parentViewController:(UIViewController *)parentVC;
   ```
2. **Xử lý nạp metadata qua InnerTube API**:
   - Endpoint: `https://www.youtube.com/youtubei/v1/player`
   - Payload:
     ```json
     {
       "context": {
         "client": {
           "clientName": "IOS",
           "clientVersion": "21.34.3",
           "deviceModel": "iPhone",
           "hl": "vi",
           "gl": "VN"
         }
       },
       "videoId": "<VIDEO_ID>"
     }
     ```
   - Phân tích trường `streamingData.adaptiveFormats` và `streamingData.formats` để tạo danh sách `YTLDownloadFormat`.
   - Trích xuất tiêu đề từ `videoDetails.title`.
   - Hiển thị menu tải trực tiếp cho người dùng.

---

## 5. Kế hoạch kiểm thử & Xác thực

1. **Kiểm tra biên dịch tweak**:
   - Chạy `make clean && make` trong môi trường Theos để đảm bảo không có cảnh báo hoặc lỗi cú pháp Objective-C.
2. **Kiểm tra luồng tải từ Player**:
   - Mở 1 video bất kỳ, ấn nút Download hoặc 3 chấm -> Download.
   - Xác nhận: Không còn nháy màn hình, không hiện popup yêu cầu Premium, bảng chọn chất lượng tải (Download Manager) hiện lên ngay lập tức.
3. **Kiểm tra luồng tải từ Feed/Search**:
   - Ở màn hình Home / Tìm kiếm, ấn nút 3 chấm trên video card -> chọn "Tải video xuống".
   - Xác nhận: Tweak tải metadata của video đó và mở menu chọn định dạng chính xác theo video tương ứng.
