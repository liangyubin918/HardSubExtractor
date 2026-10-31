#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
echo "==> 编译 ($CONFIG)"
swift build -c "$CONFIG" --disable-sandbox

BIN="$ROOT/.build/$CONFIG/HardSubExtractor"
APP="$ROOT/build/硬字幕提取器.app"

echo "==> 生成图标"
swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset" >/dev/null
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/HardSubExtractor"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# PaddleOCR 的模型与字符字典
if [ -d "$ROOT/Resources/Models" ]; then
    mkdir -p "$APP/Contents/Resources/Models"
    cp "$ROOT/Resources/Models"/* "$APP/Contents/Resources/Models/"
    echo "    模型：$(du -sh "$ROOT/Resources/Models" | cut -f1)"
fi

# FFmpeg 可执行文件（兼容 MKV / 10-bit H.264 / AV1 等 AVFoundation 解不了的格式）
FFMPEG_BIN="$ROOT/Vendor/ffmpeg/ffmpeg"
if [ -f "$FFMPEG_BIN" ]; then
    cp "$FFMPEG_BIN" "$APP/Contents/Resources/ffmpeg"
    chmod +x "$APP/Contents/Resources/ffmpeg"
    echo "    ffmpeg：$(du -sh "$FFMPEG_BIN" | cut -f1)"
fi

# onnxruntime 动态库（运行时 dlopen，缺失不影响应用启动）
ORT_LIB="$ROOT/Vendor/onnxruntime/lib/libonnxruntime.1.dylib"
if [ -f "$ORT_LIB" ]; then
    cp "$ORT_LIB" "$APP/Contents/Frameworks/"
    echo "    onnxruntime：$(du -sh "$ORT_LIB" | cut -f1)"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>硬字幕提取器</string>
    <key>CFBundleDisplayName</key>
    <string>硬字幕提取器</string>
    <key>CFBundleExecutable</key>
    <string>HardSubExtractor</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.hardsubextractor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local build</string>
</dict>
</plist>
PLIST

echo '==> 签名'
if [ -f "$APP/Contents/Resources/ffmpeg" ]; then
    codesign --force --sign - "$APP/Contents/Resources/ffmpeg" >/dev/null 2>&1 || true
fi
if [ -f "$APP/Contents/Frameworks/libonnxruntime.1.dylib" ]; then
    codesign --force --sign - "$APP/Contents/Frameworks/libonnxruntime.1.dylib" >/dev/null 2>&1 || true
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (跳过签名)"

echo "完成：$APP"
du -sh "$APP" | awk '{print "体积：" $1}'
echo "启动：open \"$APP\""
