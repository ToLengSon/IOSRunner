#!/usr/bin/env bash
# 编译状态栏工具（Apple Silicon 原生，不依赖 Xcode 工程）
#   ./build.sh           编译到 dist/IOSRunner.app
#   ./build.sh --run     编译完直接启动
#   ./build.sh --zip     编译完额外打包 dist/IOSRunner.zip（发给别人用这个）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="IOSRunner"
BUNDLE="dist/$APP_NAME.app"
STAGE=".build-tool"
MIN_MACOS="13.0"
ARCH="$(uname -m)"

SOURCES=(Sources/main.swift Sources/Runner.swift Sources/PanelView.swift Sources/Diagnosis.swift)

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "▸ 编译 ${ARCH}（-O 全模块优化）"
swiftc -O -wmo -swift-version 5 -target "$ARCH-apple-macos$MIN_MACOS" \
  -framework Cocoa -framework SwiftUI \
  "${SOURCES[@]}" -o "$STAGE/$APP_NAME"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$STAGE/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"

# ad-hoc 签名：无证书、无有效期，不会过期；但没有公证，分发时对方需右键打开
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || echo "⚠︎ 签名失败，仍可直接运行"
codesign --verify --deep --strict "$BUNDLE" >/dev/null 2>&1 \
  && echo "✓ 签名自检通过（adhoc，永不过期）" || echo "⚠︎ 签名自检未通过"

echo "✓ $BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME"), $(du -h "$BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1))"

for arg in "$@"; do
  case "$arg" in
    --zip)
      rm -rf dist/pkg "dist/$APP_NAME.zip"
      mkdir -p dist/pkg
      cp -R "$BUNDLE" dist/pkg/ || true
      cp 使用手册.md dist/pkg/ 2>/dev/null || true
      xattr -cr dist/pkg 2>/dev/null || true
      ( cd dist/pkg && ditto -c -k --norsrc --noextattr --noqtn . "../$APP_NAME.zip" )
      rm -rf dist/pkg
      echo "✓ dist/$APP_NAME.zip（app + 手册，发给别人用这个）"
      ;;
    --run)
      pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
      sleep 0.3
      open "$BUNDLE"
      echo "✓ 已启动，看上边菜单栏的锤子图标"
      ;;
  esac
done
