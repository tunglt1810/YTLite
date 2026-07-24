# Implementation Plan - Add `build_from_source` Flag to Bypass Pre-built Release DEB

Bổ sung tham số cấu hình `build_from_source` vào GitHub Actions Workflow (`main.yml`, `cyan_ts.yml`, `_build_tweaks.yml`) để cho phép biên dịch trực tiếp mã nguồn mở YTLite từ repository thông qua Theos, thay vì tự động tải file `ytplus.deb` pre-compiled bị dính check subscription từ GitHub Releases.

## User Review Required

> [!IMPORTANT]
> Mặc định flag `build_from_source` sẽ được bật (`default: true`). Khi bật, GitHub Action sẽ tự biên dịch mã nguồn local trong repo (sử dụng [Makefile](file:///Users/bez/Workspace/repos/bez/YTLite/Makefile)), tạo ra bản build sạch hoàn toàn mở full tính năng mà không bị dính câu lệnh kiểm tra đăng ký dịch vụ của gói phát hành sẵn.

## Proposed Changes

### Workflows

#### [MODIFY] [_build_tweaks.yml](file:///Users/bez/Workspace/repos/bez/YTLite/.github/workflows/_build_tweaks.yml)
- Bổ sung `inputs.build_from_source` (type: boolean, default: true).
- Cập nhật điều kiện trigger của bước Setup Theos / iOS SDK (khi `build_from_source == true` hoặc các tweak khác bật).
- Thêm bước `Build YTLite from source`: Chạy `make clean package DEBUG=0 FINALPACKAGE=1` và đổi tên `.deb` đầu ra thành `ytplus.deb`.
- Đảm bảo bước `Download YouTube Plus (by version)` chỉ chạy khi `build_from_source == false` và có `tweak_version`.

#### [MODIFY] [main.yml](file:///Users/bez/Workspace/repos/bez/YTLite/.github/workflows/main.yml)
- Bổ sung input `build_from_source` (Description: "Build YTLite from local source code (Full Features, No Subscription)").
- Truyền `build_from_source: ${{ inputs.build_from_source }}` sang `_build_tweaks.yml`.

#### [MODIFY] [cyan_ts.yml](file:///Users/bez/Workspace/repos/bez/YTLite/.github/workflows/cyan_ts.yml)
- Bổ sung input `build_from_source` (Description: "Build YTLite from local source code (Full Features, No Subscription)").
- Truyền `build_from_source: ${{ inputs.build_from_source }}` sang `_build_tweaks.yml`.

---

## Verification Plan

### Automated Verification
- Kiểm tra tính hợp lệ cú pháp YAML của các file workflow.

### Manual Verification
- Kiểm tra luồng chạy logic trong `_build_tweaks.yml` khi `build_from_source = true` và `build_from_source = false`.
