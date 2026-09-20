#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
LAYOUT_FW_DIR="$ROOT_DIR/layout/Library/Frameworks"
TMP_DIR="$ROOT_DIR/.tmp"
ZIP_FILE="$TMP_DIR/ffmpeg-kit-ios-full.zip"
EXTRACT_DIR="$TMP_DIR/ffmpeg-kit-extracted"
DOWNLOAD_URL="https://github.com/luthviar/ffmpeg-kit-ios-full/releases/download/6.0/ffmpeg-kit-ios-full.zip"

mkdir -p "$FRAMEWORKS_DIR" "$TMP_DIR"

# Luôn dọn dẹp thư mục trùng lặp trong layout/var/jb nếu có để tránh deb bị nhân đôi dung lượng
rm -rf "$ROOT_DIR/layout/var/jb/Library/Frameworks"

if [ -d "$FRAMEWORKS_DIR/ffmpegkit.framework" ] && [ -f "$FRAMEWORKS_DIR/ffmpegkit.framework/ffmpegkit" ] && [ -d "$LAYOUT_FW_DIR/ffmpegkit.framework" ]; then
    echo "[+] FFmpegKit frameworks already exist and optimized in $FRAMEWORKS_DIR and $LAYOUT_FW_DIR"
    exit 0
fi

if [ ! -f "$ZIP_FILE" ]; then
    echo "[*] Downloading ffmpeg-kit-ios-full from $DOWNLOAD_URL..."
    curl -L -C - -o "$ZIP_FILE" "$DOWNLOAD_URL"
fi

echo "[*] Extracting ios-arm64 frameworks from $ZIP_FILE..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

unzip -q -o "$ZIP_FILE" -d "$EXTRACT_DIR"

echo "[*] Processing frameworks..."
rm -rf "$LAYOUT_FW_DIR"
mkdir -p "$LAYOUT_FW_DIR"

for xcf in "$EXTRACT_DIR"/ffmpeg-kit-ios-full/*.xcframework; do
    if [ -d "$xcf/ios-arm64" ]; then
        for fw in "$xcf/ios-arm64"/*.framework; do
            fw_name="$(basename "$fw")"
            echo "  -> Processing $fw_name"

            # 1. Copy vào Frameworks/ để dùng cho compile-time (giữ headers để clang biên dịch)
            rm -rf "$FRAMEWORKS_DIR/$fw_name"
            cp -RP "$fw" "$FRAMEWORKS_DIR/$fw_name"
            rm -rf "$FRAMEWORKS_DIR/$fw_name/_CodeSignature" "$FRAMEWORKS_DIR/$fw_name/.DS_Store" "$FRAMEWORKS_DIR/$fw_name/strip-frameworks.sh"

            # 2. Copy vào layout/Library/Frameworks/ cho runtime đóng gói DEB/IPA
            # Tối ưu triệt để: Xóa toàn bộ file SDK (Headers, Modules, LICENSE, scripts)
            # Runtime trên iOS chỉ cần DUY NHẤT file binary Mach-O + Info.plist
            target_fw="$LAYOUT_FW_DIR/$fw_name"
            cp -RP "$fw" "$target_fw"
            rm -rf "$target_fw/Headers"
            rm -rf "$target_fw/Modules"
            rm -rf "$target_fw/SOURCE"
            rm -rf "$target_fw/strip-frameworks.sh"
            rm -rf "$target_fw/.DS_Store"
            rm -rf "$target_fw/_CodeSignature"
            rm -f "$target_fw"/LICENSE*

            # 3. Strip symbol của binary để giảm kích thước và tăng tốc độ hash của zsign/iLoader
            bin_name="$(basename "$fw_name" .framework)"
            if [ -f "$target_fw/$bin_name" ]; then
                strip -x "$target_fw/$bin_name" 2>/dev/null || true
            fi
        done
    fi
done

# Cleanup extracted temp files
rm -rf "$EXTRACT_DIR"

echo "[+] Successfully setup and optimized all FFmpegKit frameworks for build and sideloading!"
