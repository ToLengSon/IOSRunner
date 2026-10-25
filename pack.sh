#!/usr/bin/env bash
# 打完整分发包：状态栏工具 + Skill + 安装脚本 + 两份手册
#   ./pack.sh   →  dist/iOS-DevKit.zip
set -euo pipefail
cd "$(dirname "$0")"

NAME="iOS-DevKit"
OUT="dist/$NAME"
ZIP="dist/$NAME.zip"

echo "▸ 编译工具"
./build.sh >/dev/null
echo "  ✓ dist/IOSRunner.app"

echo "▸ 同步 Skill"
LOCAL_SKILL="skills/ios-run"
USER_SKILL="$HOME/.codebuddy/skills/ios-run"
if [ -d "$USER_SKILL" ]; then
  rm -rf "$LOCAL_SKILL"
  mkdir -p skills
  cp -R "$USER_SKILL" "$LOCAL_SKILL"
  echo "  ✓ 取自 $USER_SKILL"
elif [ -d "$LOCAL_SKILL" ]; then
  echo "  ✓ 使用项目内副本"
else
  echo "  ✗ 找不到 skill，先在 ~/.codebuddy/skills/ios-run 创建" >&2
  exit 1
fi

echo "▸ 组装分发包"
rm -rf "$OUT" "$ZIP"
mkdir -p "$OUT/skills"

cp -R dist/IOSRunner.app "$OUT/"
cp install.sh README.md 使用手册.md Skill-使用手册.md RELEASE_NOTES.md "$OUT/"
cp -R "$LOCAL_SKILL" "$OUT/skills/"

chmod +x "$OUT/install.sh" "$OUT/skills/ios-run/scripts/ios-run.sh"
xattr -cr "$OUT" 2>/dev/null || true

ditto -c -k --norsrc --noextattr --noqtn --keepParent "$OUT" "$ZIP"

echo "✓ dist/$NAME.zip  ($(du -h "$ZIP" | cut -f1))"
echo
echo "包内结构："
find "$OUT" -maxdepth 3 -not -path '*/IOSRunner.app/*' | sed "s|$OUT|  $NAME|"

# 中间目录用完即删，dist 只留 app 与 zip
rm -rf "$OUT"
