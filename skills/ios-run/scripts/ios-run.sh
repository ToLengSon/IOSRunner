#!/usr/bin/env bash
# iOS 真机：编译 -> 安装 -> 启动，输出精简结果（完整日志写文件，不灌终端）
#
#   ios-run.sh                         # 自动选设备（上次使用的 > 唯一在线）
#   ios-run.sh --list                  # 只列设备清单和状态，不构建
#   ios-run.sh -p ~/proj/App.xcworkspace -d "iPhone 13"
#   ios-run.sh --clean --json          # 清理后构建，输出 JSON 供程序解析
#   ios-run.sh -s MyApp -v             # 指定 scheme 并打印完整日志
#   设备优先级：-d > IOSRunner.app 选择 > 上次使用(在线) > 唯一在线设备
set -uo pipefail

PROJECT=""
DEVICE=""
SCHEME=""
CONFIG="Debug"
DO_CLEAN=0
DO_LIST=0
JSON=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="${2:-}"; shift 2 ;;
    -d|--device)  DEVICE="${2:-}";  shift 2 ;;
    -s|--scheme)  SCHEME="${2:-}";  shift 2 ;;
    --config)     CONFIG="${2:-}";  shift 2 ;;
    --clean)      DO_CLEAN=1; shift ;;
    -l|--list)    DO_LIST=1; shift ;;
    --json)       JSON=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

RUN_TMP="$(mktemp -d)"
LOG="$RUN_TMP/xcodebuild.log"
LASTLOG="${TMPDIR:-/tmp}/ios-run-last.log"
trap 'rm -rf "$RUN_TMP"' EXIT

die() {
  if [[ $JSON -eq 1 ]]; then
    python3 -c 'import json,sys; print(json.dumps({"result":"failure","stage":"setup","diagnosis":sys.argv[1],"hint":None,"errors":[],"log":None},ensure_ascii=False,indent=1))' "$1"
  else
    echo "✘ $1" >&2
  fi
  exit 1
}

# ---------- 1. 定位容器 ----------
[[ -n "$PROJECT" ]] || PROJECT="$(pwd)"
if [[ -d "$PROJECT" ]]; then
  ws="$(ls -d "$PROJECT"/*.xcworkspace 2>/dev/null | head -1)"
  if [[ -n "$ws" ]]; then
    CONTAINER="$ws"
  else
    pr="$(ls -d "$PROJECT"/*.xcodeproj 2>/dev/null | head -1)"
    [[ -n "$pr" ]] || die "目录里没有 .xcworkspace / .xcodeproj：$PROJECT"
    CONTAINER="$pr"
  fi
else
  CONTAINER="$PROJECT"
fi

case "$CONTAINER" in
  *.xcworkspace) CF=(-workspace "$CONTAINER") ;;
  *.xcodeproj)   CF=(-project   "$CONTAINER") ;;
  *) die "不是 .xcworkspace / .xcodeproj：$CONTAINER" ;;
esac

CONTAINER_NAME="$(basename "$CONTAINER")"
CONTAINER_NAME="${CONTAINER_NAME%.*}"

# ---------- 2. 选设备 ----------
DEVJSON="$RUN_TMP/devices.json"
xcrun devicectl list devices --json-output "$DEVJSON" --quiet >/dev/null 2>&1 || true

# 「是否在线」以 xctrace 为准：它只列当前可达的物理设备，而 devicectl 的 tunnelState
# 常在设备正常时误报 disconnected（见 SKILL.md 踩坑 3），只作兜底。
XTOUT="$RUN_TMP/xctrace.txt"
xcrun xctrace list devices >"$XTOUT" 2>/dev/null || : >"$XTOUT"

DEV_LIST="$(python3 - "$DEVJSON" "$XTOUT" <<'PY'
import json, re, sys

# xctrace 输出中 "== Devices ==" 段是可达物理设备，行尾括号内为 UDID；Simulators 与 Offline 需排除
reachable = set()
try:
    in_devices = False
    for raw in open(sys.argv[2], errors="ignore"):
        line = raw.strip()
        if line.startswith("=="):
            in_devices = ("Devices" in line) and ("Simulators" not in line) and ("Offline" not in line)
            continue
        if not in_devices or not line or line.lower().endswith("(offline)"):
            continue
        m = re.search(r"\(([0-9A-Fa-f][0-9A-Fa-f-]{7,})\)\s*$", line)
        if m:
            reachable.add(m.group(1))
except OSError:
    pass

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    dp = dev.get("deviceProperties", {})
    cp = dev.get("connectionProperties", {})
    udid = hw.get("udid") or ""
    if not udid:
        continue
    name = (hw.get("marketingName") or dp.get("name") or "iPhone").replace("\t", " ")
    paired = "1" if cp.get("pairingState") == "paired" else "0"
    tunnel = "1" if cp.get("tunnelState") == "connected" else "0"
    online = "1" if (udid in reachable or tunnel == "1") else "0"
    print(f"{udid}\t{name}\t{paired}\t{online}\t{tunnel}")
PY
)"

UDID=""
DEVNAME=""
DEVSRC=""

STATE_DIR="${HOME}/Library/Caches/ios-run"
LAST_DEV_FILE="$STATE_DIR/last-device"

# IOSRunner.app 每次运行前会把选中的设备写进自己的 UserDefaults（键 deviceUDID）
APP_PREF_UDID="$(defaults read local.tools.iosrunner deviceUDID 2>/dev/null | head -1 | tr -d '\r')"
# 本脚本上次成功启动所用的设备，下次自动沿用
LAST_DEV_UDID="$(cut -f1 "$LAST_DEV_FILE" 2>/dev/null | head -1 | tr -d '\r')"

# pick_device <want> <need_online> <allow_unpaired>
# want 可匹配 UDID 或设备名；need_online=1 时要求在线；allow_unpaired=1 时不过滤配对状态（用于 -d）
pick_device() {
  local want="$1" need="${2:-0}" allow_any="${3:-0}"
  local hits=0 hit_u="" hit_n=""
  while IFS=$'\t' read -r u n p o t; do
    [[ -z "$u" ]] && continue
    if [[ "$allow_any" != "1" && "$p" != "1" ]]; then
      continue
    fi
    if [[ "$need" == "1" && "$o" != "1" ]]; then
      continue
    fi
    if [[ "$u" == "$want" || "$n" == "$want" ]]; then
      hits=$((hits + 1)); hit_u="$u"; hit_n="$n"
    fi
  done <<< "$DEV_LIST"
  # 同名设备不止一台时不能猜，否则会把 App 装到没预期的机器上
  [[ "$hits" -gt 1 ]] && return 2
  [[ -n "$hit_u" ]] || return 1
  UDID="$hit_u"; DEVNAME="$hit_n"; return 0
}

list_devices() {
  while IFS=$'\t' read -r u n p o t; do
    [[ -z "$u" ]] && continue
    local st="未配对"
    if [[ "$p" == "1" ]]; then
      if [[ "$o" == "1" ]]; then st="在线"; else st="已配对 · 未连接"; fi
    fi
    local mark=""
    if [[ "$u" == "$APP_PREF_UDID" ]]; then
      mark="   ← IOSRunner 选中"
    elif [[ "$u" == "$LAST_DEV_UDID" ]]; then
      mark="   ← 上次使用"
    fi
    echo "  $u  $n  $st$mark"
  done <<< "$DEV_LIST"
}

if [[ $DO_LIST -eq 1 ]]; then
  list_devices
  exit 0
fi

ONLINE_LIST="$(echo "$DEV_LIST" | awk -F'\t' 'NF && $3=="1" && $4=="1"')"
ONLINE_COUNT="$(printf '%s\n' "$ONLINE_LIST" | grep -c . || true)"

if [[ -n "$DEVICE" ]]; then
  # 显式指定时不做任何过滤，允许离线/未配对设备，交给 xcodebuild 给出精确诊断
  pick_device "$DEVICE" 0 1
  case $? in
    0) : ;;
    2) die "有多台设备同名「${DEVICE}」，无法区分。请改用 UDID 指定（--list 可查）" ;;
    *) die "找不到设备「${DEVICE}」，用 --list 查看可用设备" ;;
  esac
  DEVSRC="-d 参数"
elif [[ -n "$APP_PREF_UDID" ]] && pick_device "$APP_PREF_UDID" 1; then
  DEVSRC="IOSRunner.app 选择"
elif [[ -n "$APP_PREF_UDID" ]] && pick_device "$APP_PREF_UDID" 0; then
  # 用户在 App 里明确选过，不静默换机，避免装到没预期的设备上
  die "IOSRunner.app 选中的设备「${DEVNAME}」当前未连接。接上这台，或在 App 里换一台，或用 -d 指定"
elif [[ -n "$LAST_DEV_UDID" ]] && pick_device "$LAST_DEV_UDID" 1; then
  DEVSRC="上次使用的设备"
elif [[ "$ONLINE_COUNT" -eq 1 ]]; then
  pick_device "$(echo "$ONLINE_LIST" | cut -f1 | head -1)" 1 && DEVSRC="唯一在线设备"
elif [[ "$ONLINE_COUNT" -eq 0 ]]; then
  die "没有在线的 iPhone（历史配对但已离线的设备不算）。请数据线连接、解锁并信任此电脑"
else
  die "检测到 ${ONLINE_COUNT} 台在线设备，无法确定用哪台。请用 -d 指定：$(echo "$ONLINE_LIST" | awk -F'\t' '{printf "%s(%s) ", $2, $1}')"
fi

if [[ -z "$UDID" ]]; then
  die "没有在线的 iPhone。请数据线连接、解锁并信任此电脑"
fi

# ---------- 3. 解析 scheme ----------
if [[ -z "$SCHEME" ]]; then
  SCHEME="$(xcrun xcodebuild -list -json "${CF[@]}" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0: sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
c = d.get("workspace") or d.get("project") or {}
schemes = c.get("schemes") or []
main = [s for s in schemes if not s.lower().startswith("pods")]
print((main or schemes or [""])[0])
')"
fi
[[ -n "$SCHEME" ]] || die "无法确定 scheme，请用 -s 指定"
[[ "$SCHEME" == "$CONTAINER_NAME" ]] || true

DERIVED="$HOME/Library/Caches/ios-run/$CONTAINER_NAME-DerivedData"
mkdir -p "$DERIVED"
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$SCHEME.app"

: > "$LOG"
T_START=$SECONDS

# ---------- 4. 清理 ----------
if [[ $DO_CLEAN -eq 1 ]]; then
  xcrun xcodebuild "${CF[@]}" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' clean >>"$LOG" 2>&1
  rm -rf "$DERIVED"
fi

# ---------- 5. 编译 ----------
[[ $JSON -eq 0 ]] && echo "▸ 编译 ${SCHEME}（${CONFIG}）→ ${DEVNAME}"
xcrun xcodebuild "${CF[@]}" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build >>"$LOG" 2>&1
BUILD_RC=$?
T_BUILD=$((SECONDS - T_START))

# ---------- 失败输出 ----------
diagnose() {
  local f="$1"
  if grep -qiE "matching the provided destination specifier|unable to find a device matching" "$f"; then
    DIAG="设备当前未连接"; HINT="解锁 iPhone 并重新插好数据线（Wi-Fi 常掉线，建议 USB），然后重试"
  elif grep -qiE 'no signing certificate' "$f"; then
    DIAG="缺少 Apple 开发证书"; HINT="打开 Xcode → Settings → Accounts 登录 Apple ID（免费账号即可），并给任意项目签一次名"
  elif grep -qiE 'not agreed to the xcode license' "$f"; then
    DIAG="Xcode 许可协议未同意"; HINT="sudo xcodebuild -license accept"
  elif grep -qiE 'active developer directory is a command line tools|requires xcode' "$f"; then
    DIAG="xcode-select 指向命令行工具"; HINT="sudo xcode-select -s /Applications/Xcode.app"
  elif grep -qiE 'sdk is not installed|unable to find sdk' "$f"; then
    DIAG="缺少 iOS SDK 组件"; HINT="Xcode → Settings → Components 下载 iOS 平台"
  elif grep -qiE 'failed to register bundle identifier|bundle identifier is not available' "$f"; then
    DIAG="Bundle ID 不可用"; HINT="改项目 Bundle Identifier 为全局唯一值"
  elif grep -qiE 'requires a development team' "$f"; then
    DIAG="未选择开发者团队"; HINT="Target → Signing & Capabilities → 选择 Team"
  elif grep -qiE 'provisioning profile.*expired|has expired' "$f"; then
    DIAG="描述文件已过期"; HINT="重新运行即可自动续期（免费账号 7 天）"
  elif grep -qiE 'not been explicitly trusted' "$f"; then
    DIAG="设备未信任开发者证书"; HINT="手机：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任"
  elif grep -qiE 'device is locked|not, or could not be, unlocked' "$f"; then
    DIAG="手机锁屏"; HINT="解锁 iPhone 后重试"
  elif grep -qiE 'failed to prepare device for development|developer mode' "$f"; then
    DIAG="设备未开启开发者模式"; HINT="手机：设置 → 隐私与安全性 → 开发者模式"
  elif grep -qiE 'user interaction is not allowed|errsecinternalcomponent' "$f"; then
    DIAG="钥匙串被锁定"; HINT="解锁登录钥匙串，或重试并在弹窗选「始终允许」"
  elif grep -qiE 'command codesign failed' "$f"; then
    DIAG="代码签名失败"; HINT="确认证书有效；钥匙串弹窗选「始终允许」"
  elif grep -qiE "pods.*file not found|no such module 'pods_" "$f"; then
    DIAG="CocoaPods 依赖未安装 / 选错容器"; HINT="使用 .xcworkspace；缺失时先 pod install"
  else
    DIAG=""; HINT=""
  fi
}

fail() {
  local stage="$1" rc="$2"
  diagnose "$LOG"
  cp "$LOG" "$LASTLOG" 2>/dev/null || true
  local errs
  errs="$(grep -E "error:" "$LOG" 2>/dev/null | grep -v "BUILD FAILED" | awk '!seen[$0]++' | head -15)"

  if [[ $JSON -eq 1 ]]; then
    python3 - "$stage" "$rc" "$DIAG" "$HINT" "$LASTLOG" "$UDID" "$DEVNAME" "$SCHEME" "$CONTAINER" <<'PY'
import json, sys
stage, rc, diag, hint, log, udid, name, scheme, container = sys.argv[1:10]
errors = []
try:
    for line in open(log, errors="ignore"):
        line = line.strip()
        if "error:" in line and "BUILD FAILED" not in line and line not in errors:
            errors.append(line)
except Exception:
    pass
print(json.dumps({
    "result": "failure",
    "stage": stage,
    "exitCode": int(rc),
    "diagnosis": diag or None,
    "hint": hint or None,
    "errors": errors[:20],
    "scheme": scheme,
    "container": container,
    "device": {"name": name, "udid": udid},
    "log": log,
}, ensure_ascii=False, indent=1))
PY
  else
    echo "✘ ${stage}失败（耗时 $((SECONDS - T_START))s）"
    [[ -n "$DIAG" ]] && { echo "  诊断: $DIAG"; echo "  建议: $HINT"; }
    if [[ -n "$errs" ]]; then
      echo "  错误:"
      echo "$errs" | sed 's/^/    /'
    else
      echo "  （日志里没有 error: 行，用 -v 看完整输出）"
    fi
    echo "  日志: $LASTLOG"
  fi
  [[ $VERBOSE -eq 1 ]] && tail -40 "$LOG" >&2
  exit 1
}

[[ $BUILD_RC -eq 0 ]] || fail "编译" "$BUILD_RC"
[[ -d "$APP" ]] || fail "编译" 1

# ---------- 6. 安装 ----------
[[ $JSON -eq 0 ]] && echo "▸ 安装到 $DEVNAME"
T1=$SECONDS
xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1
INSTALL_RC=$?
[[ $INSTALL_RC -eq 0 ]] || fail "安装" "$INSTALL_RC"
T_INSTALL=$((SECONDS - T1))

# ---------- 7. 启动 ----------
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || fail "启动" 1

[[ $JSON -eq 0 ]] && echo "▸ 启动 $BUNDLE_ID"
T2=$SECONDS
xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >>"$LOG" 2>&1
LAUNCH_RC=$?
[[ $LAUNCH_RC -eq 0 ]] || fail "启动" "$LAUNCH_RC"
T_LAUNCH=$((SECONDS - T2))

# ---------- 8. 记住本次设备，下次自动沿用 ----------
mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\t%s\n' "$UDID" "$DEVNAME" >"$LAST_DEV_FILE" 2>/dev/null || true

# ---------- 9. 成功输出 ----------
if [[ $JSON -eq 1 ]]; then
  python3 - "$BUNDLE_ID" "$APP" "$UDID" "$DEVNAME" "$SCHEME" "$T_BUILD" "$T_INSTALL" "$T_LAUNCH" <<'PY'
import json, sys
bundle, app, udid, name, scheme, tb, ti, tl = sys.argv[1:9]
print(json.dumps({
    "result": "success",
    "stage": "launched",
    "bundleId": bundle,
    "app": app,
    "scheme": scheme,
    "device": {"name": name, "udid": udid},
    "seconds": {"build": int(tb), "install": int(ti), "launch": int(tl)},
}, ensure_ascii=False, indent=1))
PY
else
  echo "✔ 编译 ${T_BUILD}s · 安装 ${T_INSTALL}s · 启动 ${T_LAUNCH}s"
  echo "  设备: $DEVNAME（来源：${DEVSRC}）"
  echo "  Bundle: $BUNDLE_ID"
  echo "  产物: $APP"
fi

[[ $VERBOSE -eq 1 ]] && tail -20 "$LOG"
cp "$LOG" "$LASTLOG" 2>/dev/null || true
exit 0
