#!/usr/bin/env bash
# iOS DevKit 一键安装：状态栏工具 + CodeBuddy Skill
#   ./install.sh              安装到 /Applications 与 ~/.codebuddy/skills
#   PREFIX=~/Applications ./install.sh   换安装目录
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="${PREFIX:-/Applications}"
SKILL_DIR="${SKILL_DIR:-$HOME/.codebuddy/skills}"

if [ ! -d "$PREFIX" ] || [ ! -w "$PREFIX" ]; then
  echo "⚠ $PREFIX 不可写，改装到 ~/Applications"
  PREFIX="$HOME/Applications"
  mkdir -p "$PREFIX"
fi

echo "== 安装状态栏工具 =="
APP_SRC=""
if [ -d "IOSRunner.app" ]; then
  APP_SRC="IOSRunner.app"
elif [ -d "dist/IOSRunner.app" ]; then
  APP_SRC="dist/IOSRunner.app"
fi

if [ -n "$APP_SRC" ]; then
  rm -rf "$PREFIX/IOSRunner.app"
  mkdir -p "$PREFIX"
  cp -R "$APP_SRC" "$PREFIX/"
  xattr -dr com.apple.quarantine "$PREFIX/IOSRunner.app" 2>/dev/null || true
  codesign --verify --deep --strict "$PREFIX/IOSRunner.app" >/dev/null 2>&1 \
    && echo "  ✓ $PREFIX/IOSRunner.app（签名有效）" \
    || echo "  ⚠ $PREFIX/IOSRunner.app 已复制，但签名校验未通过"
else
  echo "  ⚠ 当前目录没有 IOSRunner.app，跳过"
fi

echo
echo "== 安装 CodeBuddy Skill =="
if [ -d "skills/ios-run" ]; then
  mkdir -p "$SKILL_DIR"
  rm -rf "$SKILL_DIR/ios-run"
  cp -R "skills/ios-run" "$SKILL_DIR/"
  chmod +x "$SKILL_DIR/ios-run/scripts/ios-run.sh"
  echo "  ✓ $SKILL_DIR/ios-run"
  echo "    重启 CodeBuddy 后，在对话里说「跑一下」即可触发"
else
  echo "  ⚠ 当前目录没有 skills/ios-run，跳过"
fi

echo
echo "== 安装 Cursor Skill =="
CURSOR_HOME="${CURSOR_HOME:-$HOME/.cursor}"
if [ "${SKIP_CURSOR:-0}" = "1" ]; then
  echo "  - 已跳过（SKIP_CURSOR=1）"
elif [ -d "/Applications/Cursor.app" ] || [ -d "$CURSOR_HOME" ]; then
  if [ -d "skills/ios-run" ]; then
    mkdir -p "$CURSOR_HOME/skills"
    rm -rf "$CURSOR_HOME/skills/ios-run"
    cp -R "skills/ios-run" "$CURSOR_HOME/skills/"
    chmod +x "$CURSOR_HOME/skills/ios-run/scripts/ios-run.sh"
    echo "  ✓ $CURSOR_HOME/skills/ios-run"
    echo "    重启 Cursor 后，在 Agent 里说「跑一下」即可触发"
  fi
else
  echo "  - 未检测到 Cursor，跳过（可选：SKIP_CURSOR=1 强制跳过）"
fi

echo
echo "== 环境检查 =="
ok=0
bad=0
chk() {
  if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; ok=$((ok+1));
  else echo "  ✗ $1  → $3"; bad=$((bad+1)); fi
}

chk "Apple Silicon / macOS 13+" '[ "$(uname -m)" = "arm64" ]' "本工具仅支持 M 系列芯片"
chk "xcode-select 指向 Xcode.app" 'xcode-select -p | grep -q "Xcode.app"' "sudo xcode-select -s /Applications/Xcode.app"
chk "xcodebuild 可用" 'xcodebuild -version' "安装完整 Xcode，或 sudo xcodebuild -license accept"
chk "iOS SDK 已安装" 'xcodebuild -showsdks | grep -q iphoneos' "Xcode → Settings → Components 下载 iOS 平台"
chk "有 Apple 开发证书" 'security find-identity -v -p codesigning | grep -q "Apple Development"' "Xcode → Settings → Accounts 登录 Apple ID"
chk "检测到已配对设备" 'xcrun devicectl list devices | grep -qE "available|connected"' "数据线连接 iPhone、解锁、信任此电脑"

echo
if [ "$bad" -eq 0 ]; then
  echo "✓ 环境就绪（$ok 项通过）"
else
  echo "✗ 还有 $bad 项需要处理，详见《使用手册.md》第 3 节"
fi

echo
echo "接下来："
echo "  1. 打开 $PREFIX/IOSRunner.app（首次请右键 → 打开）"
echo "  2. 或重启 CodeBuddy / Cursor，直接说「跑一下」"
