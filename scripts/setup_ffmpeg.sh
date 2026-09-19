#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
TMP_DIR="$ROOT_DIR/.tmp"
ZIP_FILE="$TMP_DIR/ffmpeg-kit-ios-full.zip"
EXTRACT_DIR="$TMP_DIR/ffmpeg-kit-extracted"
DOWNLOAD_URL="https://github.com/luthviar/ffmpeg-kit-ios-full/releases/download/6.0/ffmpeg-kit-ios-full.zip"

mkdir -p "$FRAMEWORKS_DIR" "$TMP_DIR"

if [ -d "$FRAMEWORKS_DIR/ffmpegkit.framework" ] && [ -f "$FRAMEWORKS_DIR/ffmpegkit.framework/ffmpegkit" ]; then
    echo "[+] ffmpegkit.framework already exists in $FRAMEWORKS_DIR"
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

# Copy all ios-arm64 frameworks to Frameworks/
echo "[*] Copying frameworks to $FRAMEWORKS_DIR..."
mkdir -p "$ROOT_DIR/layout/var/jb/Library/Frameworks" "$ROOT_DIR/layout/Library/Frameworks"

for xcf in "$EXTRACT_DIR"/ffmpeg-kit-ios-full/*.xcframework; do
    if [ -d "$xcf/ios-arm64" ]; then
        for fw in "$xcf/ios-arm64"/*.framework; do
            fw_name="$(basename "$fw")"
            echo "  -> Copying $fw_name"
            rm -rf "$FRAMEWORKS_DIR/$fw_name" "$ROOT_DIR/layout/var/jb/Library/Frameworks/$fw_name" "$ROOT_DIR/layout/Library/Frameworks/$fw_name"
            cp -R "$fw" "$FRAMEWORKS_DIR/$fw_name"
            cp -R "$fw" "$ROOT_DIR/layout/var/jb/Library/Frameworks/$fw_name"
            cp -R "$fw" "$ROOT_DIR/layout/Library/Frameworks/$fw_name"
        done
    fi
done

# Cleanup extracted temp files
rm -rf "$EXTRACT_DIR"

echo "[+] Successfully setup all FFmpegKit frameworks in $FRAMEWORKS_DIR"
