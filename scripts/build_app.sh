#!/usr/bin/env bash
# 編譯並打包成 build/VolumeChecker.app
# 用法：./scripts/build_app.sh            （本機架構）
#       ./scripts/build_app.sh --universal （Apple Silicon + Intel，需安裝完整 Xcode）
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/VolumeChecker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VolumeChecker" "$APP/Contents/MacOS/VolumeChecker"
cp Support/Info.plist "$APP/Contents/Info.plist"

# 本機自簽（ad-hoc），讓 macOS 能記住麥克風權限。
codesign --force --deep --sign - "$APP"

echo "完成：$APP"
echo "執行：open $APP"
echo "安裝：cp -R $APP /Applications/"
