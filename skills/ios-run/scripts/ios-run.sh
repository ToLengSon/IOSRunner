#!/usr/bin/env bash
# iOS 真机：编译 -> 安装 -> 启动，输出精简结果（完整日志写文件，不灌终端）
#
#   ios-run.sh                         # 自动选设备（上次使用的 > 唯一在线）
#   ios-run.sh --list                  # 只列设备清单和状态，不构建
#   ios-run.sh -p ~/proj/App.xcworkspace -d "iPhone 13"
#   ios-run.sh --clean --json          # 清理后构建，输出 JSON 供程序解析
#   ios-run.sh -s MyApp -v             # 指定 scheme 并打印完整日志
#   ios-run.sh --events                # 逐行输出 NDJSON 事件流（供图形界面消费）
#   ios-run.sh --crash                 # 只取最近的崩溃日志并解析，不构建不安装
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
EVENTS=0
# 启动后固定等 2 秒再查一次进程：够发现「启动即崩」，又不会拖慢日常
VERIFY_SECS=2
DO_CRASH=0
CRASH_WINDOW=900

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
    --events)     EVENTS=1; JSON=1; shift ;;
    --crash)      DO_CRASH=1; shift ;;
    --within)     CRASH_WINDOW="${2:-900}"; shift 2 ;;
    -h|--help)    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

RUN_TMP="$(mktemp -d)"
# 日志固定路径实时写入：图形界面可以直接 tail 这个文件显示构建进度
LASTLOG="${TMPDIR:-/tmp}/ios-run-last.log"
LOG="$LASTLOG"
: > "$LOG" 2>/dev/null || { LOG="$RUN_TMP/xcodebuild.log"; : > "$LOG"; }
trap 'rm -rf "$RUN_TMP"' EXIT

# events 模式：stdout 只出 NDJSON，最终结果用单行 JSON，方便界面逐行解析
if [[ $EVENTS -eq 1 ]]; then
  export IOSRUN_COMPACT=1
  printf '{"event":"logpath","path":"%s"}\n' "$LOG"
fi

ev() {
  [[ $EVENTS -eq 1 ]] || return 0
  case "$1" in
    stage) printf '{"event":"stage","name":"%s"}\n' "$2" ;;
  esac
}

die() {
  if [[ $JSON -eq 1 ]]; then
    python3 -c 'import json,os,sys; print(json.dumps({"result":"failure","stage":"setup","diagnosis":sys.argv[1],"hint":None,"errors":[],"log":None},ensure_ascii=False,indent=None if os.environ.get("IOSRUN_COMPACT")=="1" else 1))' "$1"
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
import json, os, sys
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

crash_report() {
  # 从设备拉崩溃日志，解析异常类型、原因与出错帧（有 dSYM 时顺带符号化）
  local dest="$RUN_TMP/crash"
  local saved="$STATE_DIR/crash"
  mkdir -p "$saved" 2>/dev/null || true
  # 复制失败通常意味着设备掉线/锁屏，要和「没有崩溃日志」区分开
  xcrun devicectl device copy from --device "$UDID" --domain-type systemCrashLogs \
    --source . --destination "$dest" --quiet >/dev/null 2>&1 \
    || { echo "COPYFAILED\t1"; return 0; }

  python3 - "$dest" "$EXEC_NAME" "${APP}.dSYM/Contents/Resources/DWARF/${EXEC_NAME}" "$saved" "$APP/$EXEC_NAME" <<'PY'
import glob, json, os, re, shutil, subprocess, sys, time

root, app_name, dsym, saved, appbin = sys.argv[1:6]
# 优先 dSYM；没有时退回 app 内未 strip 的二进制
symbol_sources = [p for p in (dsym, appbin) if os.path.exists(p)]

def load(f):
    raw = open(f, errors="ignore").read()
    head, _, body = raw.partition("\n")
    try:
        meta = json.loads(head)
    except Exception:
        meta = {}
    try:
        data = json.loads(body)
    except Exception:
        data = None
    return (meta if isinstance(meta, dict) else {}), (data if isinstance(data, dict) else None)

cands = []
for f in glob.glob(os.path.join(root, "**", "*.ips"), recursive=True):
    try:
        cands.append((os.path.getmtime(f), f))
    except OSError:
        pass
cands.sort(reverse=True)

# 系统里混着大量 diskwrites_resource 之类的统计报告，第二段不是 JSON，只能按内容筛真正的崩溃报告
best = None
fallback = None
now = time.time()
try:
    window = int(os.environ.get("IOSRUN_CRASH_WINDOW") or "300")
except ValueError:
    window = 300
for mtime, f in cands[:300]:
    meta, data = load(f)
    if data is None:
        continue
    if "exception" not in data and "termination" not in data:
        continue
    label = f"{meta.get('app_name') or ''} {os.path.basename(f)}".lower()
    if app_name and app_name.lower() in label:
        best = (meta, data, f)
        break
    # 兜底只接受时间窗内的崩溃，避免把陈年系统崩溃当成这次的问题
    if fallback is None and (window <= 0 or now - mtime < window):
        fallback = (meta, data, f)

chosen = best or fallback
if not chosen:
    print("CRASHFILE\t")
    sys.exit(0)

meta, data, path = chosen
kept = path
try:
    kept = os.path.join(saved, os.path.basename(path))
    shutil.copy(path, kept)
except Exception:
    kept = path

exc = data.get("exception") or {}
term = data.get("termination") or {}
images = data.get("usedImages") or []

def symbolize(image_index, offset):
    if not symbol_sources or not isinstance(image_index, int) or image_index >= len(images):
        return ""
    img = images[image_index]
    if not isinstance(img, dict):
        return ""
    base = img.get("base")
    arch = img.get("arch") or "arm64"
    if not isinstance(base, int):
        return ""
    for src in symbol_sources:
        try:
            out = subprocess.run(
                ["atos", "-arch", arch, "-o", src, "-l", hex(base), hex(base + offset)],
                capture_output=True, text=True, timeout=15)
            text = out.stdout.strip()
            # 符号化失败时 atos 只回显 "0x... (in Foo)"，没有任何函数名
            if text and not re.match(r"^0x[0-9a-fA-F]+ \(in ", text):
                return text
        except Exception:
            continue
    return ""

# NSException 类闪退要读 lastExceptionBacktrace：faultingThread 那几条通常只是
# abort / pthread_kill，看不出业务代码在哪
frames = []
leb = data.get("lastExceptionBacktrace")
if isinstance(leb, list) and leb:
    frames = leb
else:
    threads = data.get("threads") or []
    ft = data.get("faultingThread")
    for i, th in enumerate(threads):
        if th.get("triggered") or (isinstance(ft, int) and i == ft):
            frames = th.get("frames") or []
            break

def emit(tag, value):
    if value:
        print(f"{tag}\t{str(value).replace(chr(9), ' ')}")

# exceptionReason.composed_message 是 NSException 的完整原因，比 termination 具体得多
er = data.get("exceptionReason")
reason = ""
if isinstance(er, dict):
    reason = er.get("composed_message") or ""
elif isinstance(er, str):
    reason = er
if not reason:
    reason = " / ".join(term.get("reasons") or []) or term.get("indicator") or ""

emit("EXCTYPE", exc.get("type") or "")
emit("SIGNAL", exc.get("signal") or "")
emit("REASON", reason)
emit("CRASHFILE", kept)

app_idx = set()
for i, img in enumerate(images):
    if not isinstance(img, dict):
        continue
    nm = (img.get("name") or "").lower()
    pth = (img.get("path") or "").lower()
    if app_name and app_name.lower() in (nm + " " + pth):
        app_idx.add(i)

def render(fr):
    idx = fr.get("imageIndex")
    off = fr.get("imageOffset") or 0
    sym = fr.get("symbol") or ""
    loc = fr.get("symbolLocation")
    src = fr.get("sourceFile") or ""
    line = fr.get("sourceLine")
    img_name = ""
    if isinstance(idx, int) and idx < len(images) and isinstance(images[idx], dict):
        img_name = images[idx].get("name") or ""
    # App 帧即使已带方法名，也要用 dSYM 补出 文件:行
    if isinstance(idx, int) and idx in app_idx:
        resolved = symbolize(idx, off)
        if resolved:
            return resolved
    if not sym and isinstance(idx, int):
        sym = symbolize(idx, off)
    where = f"{os.path.basename(src)}:{line}" if (src and line) else ""
    text = where
    if sym:
        text = (text + "  " if text else "") + sym + (f" + {loc}" if loc else "")
    if not text:
        # App 帧常常不带符号，必须有 dSYM 才能还原成 文件:行
        text = f"{img_name or ('image[%s]' % idx)} + {off}（未符号化，缺 dSYM）"
    return text

# App 自己的帧才指向代码，优先输出；系统库帧作为上下文补几条
own = [fr for fr in frames if isinstance(fr, dict) and fr.get("imageIndex") in app_idx]
others = [fr for fr in frames if isinstance(fr, dict) and fr.get("imageIndex") not in app_idx]
for shown, fr in enumerate(own[:3] + others[:3]):
    print(f"FRAME{shown}\t{render(fr)}")
PY
}

DERIVED="$HOME/Library/Caches/ios-run/$CONTAINER_NAME-DerivedData"
mkdir -p "$DERIVED"
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$SCHEME.app"

# ---------- 3.5 只查崩溃日志（不构建不安装） ----------
# 用于「App 已经崩了，现在想知道为什么」的场景，不依赖启动后那几秒的存活校验
if [[ $DO_CRASH -eq 1 ]]; then
  EXEC_NAME=""
  if [[ -f "$APP/Info.plist" ]]; then
    EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
  fi
  [[ -n "$EXEC_NAME" ]] || EXEC_NAME="$SCHEME"

  ev stage "取崩溃日志"
  [[ $JSON -eq 0 ]] && echo "▸ 从 $DEVNAME 取最近的崩溃日志（窗口 ${CRASH_WINDOW}s）"

  SUMMARY="$RUN_TMP/crash.txt"
  IOSRUN_CRASH_WINDOW="$CRASH_WINDOW" crash_report > "$SUMMARY"

  if grep -q '^COPYFAILED' "$SUMMARY" 2>/dev/null; then
    die "无法读取设备上的崩溃日志：设备可能已断开或锁屏，请解锁并重新连接后重试"
  fi

  EXCTYPE="$(awk -F'\t' '$1=="EXCTYPE"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  REASON="$(awk -F'\t' '$1=="REASON"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  CRASHFILE="$(awk -F'\t' '$1=="CRASHFILE"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  FRAMES="$(awk -F'\t' '$1 ~ /^FRAME/ {print $2}' "$SUMMARY" 2>/dev/null)"

  if [[ -z "$CRASHFILE" ]]; then
    if [[ $JSON -eq 1 ]]; then
      python3 -c 'import json,os,sys; print(json.dumps({"result":"failure","stage":"crash","diagnosis":"时间窗内没有崩溃日志","hint":"确认 App 确实闪退过；或用 --within 放宽窗口（秒，0=不限）","errors":[],"device":{"name":sys.argv[2],"udid":sys.argv[1]}},ensure_ascii=False,indent=None if os.environ.get("IOSRUN_COMPACT")=="1" else 1))' "$UDID" "$DEVNAME"
    else
      echo "✘ 时间窗内没有找到崩溃日志（${CRASH_WINDOW}s）"
      echo "  提示: 用 --within 3600 放宽窗口，或确认 App 确实闪退过"
    fi
    exit 1
  fi

  if [[ $JSON -eq 1 ]]; then
    python3 - "$SUMMARY" "$UDID" "$DEVNAME" "$SCHEME" <<'PY'
import json, os, sys
summary, udid, name, scheme = sys.argv[1:5]
info, frames = {}, []
try:
    for line in open(summary, errors="ignore"):
        line = line.rstrip("\n")
        if "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        if k.startswith("FRAME"):
            frames.append(v)
        else:
            info[k] = v
except Exception:
    pass
diag = "闪退" + (f"（{info['EXCTYPE']}）" if info.get("EXCTYPE") else "")
print(json.dumps({
    "result": "success",
    "stage": "crash",
    "diagnosis": diag,
    "reason": info.get("REASON") or None,
    "frames": frames,
    "crashReport": info.get("CRASHFILE") or None,
    "scheme": scheme,
    "device": {"name": name, "udid": udid},
}, ensure_ascii=False, indent=None if os.environ.get("IOSRUN_COMPACT") == "1" else 1))
PY
  else
    echo "✔ 找到崩溃日志"
    [[ -n "$EXCTYPE" ]] && echo "  类型: ${EXCTYPE}"
    [[ -n "$REASON" ]] && echo "  原因: ${REASON}"
    if [[ -n "$FRAMES" ]]; then
      echo "  崩溃栈:"
      echo "$FRAMES" | sed 's/^/    /'
    fi
    echo "  报告: ${CRASHFILE}"
  fi
  exit 0
fi

: > "$LOG"
T_START=$SECONDS

# ---------- 4. 清理 ----------
if [[ $DO_CLEAN -eq 1 ]]; then
  xcrun xcodebuild "${CF[@]}" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' clean >>"$LOG" 2>&1
  rm -rf "$DERIVED"
fi

# ---------- 5. 编译 ----------
ev stage "编译"
[[ $JSON -eq 0 ]] && echo "▸ 编译 ${SCHEME}（${CONFIG}）→ ${DEVNAME}"
# 强制生成 dSYM：Debug 默认是 dwarf，二进制会被 strip，闪退栈无法还原成 文件:行
xcrun xcodebuild "${CF[@]}" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
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
import json, os, sys
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
}, ensure_ascii=False, indent=None if os.environ.get("IOSRUN_COMPACT") == "1" else 1))
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
ev stage "安装"
[[ $JSON -eq 0 ]] && echo "▸ 安装到 $DEVNAME"
T1=$SECONDS
xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1
INSTALL_RC=$?
[[ $INSTALL_RC -eq 0 ]] || fail "安装" "$INSTALL_RC"
T_INSTALL=$((SECONDS - T1))

# ---------- 7. 启动 ----------
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || fail "启动" 1

ev stage "启动"
[[ $JSON -eq 0 ]] && echo "▸ 启动 $BUNDLE_ID"
T2=$SECONDS
xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >>"$LOG" 2>&1
LAUNCH_RC=$?
[[ $LAUNCH_RC -eq 0 ]] || fail "启动" "$LAUNCH_RC"
T_LAUNCH=$((SECONDS - T2))

# ---------- 8. 存活校验：区分「启动成功」与「启动即闪退」 ----------
# launch 只保证启动请求被接受，App 秒退它也会返回 0，必须回查进程是否还在
ALIVE=""
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
[[ -n "$EXEC_NAME" ]] || EXEC_NAME="$(basename "$APP" .app)"
if [[ "$VERIFY_SECS" -gt 0 ]]; then
  ev stage "校验"
  [[ $JSON -eq 0 ]] && echo "▸ 等待 ${VERIFY_SECS}s，确认进程没有闪退"
  sleep "$VERIFY_SECS"
  PROCS="$RUN_TMP/procs.json"
  xcrun devicectl device info processes --device "$UDID" --json-output "$PROCS" --quiet >/dev/null 2>&1
  # 查询失败（设备掉线等）时不做判断，避免把「查不到」误报成闪退
  # 注意字段名是 runningProcesses，executable 形如 file:///.../Foo.app/Foo
  if [[ -f "$PROCS" ]] && grep -q '"runningProcesses"' "$PROCS" 2>/dev/null; then
    if grep -qF "/${EXEC_NAME}.app/${EXEC_NAME}" "$PROCS" 2>/dev/null; then
      ALIVE=1
    else
      ALIVE=0
    fi
  fi
fi


if [[ "$ALIVE" == "0" ]]; then
  SUMMARY="$RUN_TMP/crash.txt"
  crash_report > "$SUMMARY"
  EXCTYPE="$(awk -F'\t' '$1=="EXCTYPE"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  REASON="$(awk -F'\t' '$1=="REASON"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  CRASHFILE="$(awk -F'\t' '$1=="CRASHFILE"{print $2}' "$SUMMARY" 2>/dev/null | head -1)"
  DIAG="运行中闪退（进程已退出）"
  [[ -n "$EXCTYPE" ]] && DIAG="运行中闪退（${EXCTYPE}）"
  HINT="按崩溃帧里的 文件:行 定位并修复，然后重跑；若帧全在系统库，看 原因 里的异常信息"

  cp "$LOG" "$LASTLOG" 2>/dev/null || true

  if [[ $JSON -eq 1 ]]; then
    python3 - "$SUMMARY" "$BUNDLE_ID" "$UDID" "$DEVNAME" "$SCHEME" "$LASTLOG" "$VERIFY_SECS" <<'PY'
import json, os, sys
summary, bundle, udid, name, scheme, log, wait = sys.argv[1:8]
info, frames = {}, []
try:
    for line in open(summary, errors="ignore"):
        line = line.rstrip("\n")
        if "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        if k.startswith("FRAME"):
            frames.append(v)
        else:
            info[k] = v
except Exception:
    pass
diag = "运行中闪退" + (f"（{info['EXCTYPE']}）" if info.get("EXCTYPE") else "")
print(json.dumps({
    "result": "failure",
    "stage": "运行",
    "exitCode": 1,
    "diagnosis": diag,
    "hint": f"进程在启动后 {wait}s 内退出。按 frames 里的 文件:行 修复代码，然后重跑",
    "reason": info.get("REASON") or None,
    "frames": frames,
    "crashReport": info.get("CRASHFILE") or None,
    "bundleId": bundle,
    "scheme": scheme,
    "device": {"name": name, "udid": udid},
    "log": log,
}, ensure_ascii=False, indent=None if os.environ.get("IOSRUN_COMPACT") == "1" else 1))
PY
  else
    echo "✘ 运行失败：启动后 ${VERIFY_SECS}s 内退出（闪退）"
    echo "  诊断: ${DIAG}"
    [[ -n "$REASON" ]] && echo "  原因: ${REASON}"
    echo "  建议: ${HINT}"
    if grep -q '^FRAME0' "$SUMMARY" 2>/dev/null; then
      echo "  崩溃栈:"
      awk -F'\t' '$1 ~ /^FRAME/ {print "    " $2}' "$SUMMARY" | head -6
    fi
    [[ -n "$CRASHFILE" ]] && echo "  崩溃报告: ${CRASHFILE}"
    echo "  日志: $LASTLOG"
  fi

  [[ $VERBOSE -eq 1 ]] && tail -20 "$SUMMARY"
  exit 1
fi

# ---------- 9. 记住本次设备，下次自动沿用 ----------
mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s\t%s\n' "$UDID" "$DEVNAME" >"$LAST_DEV_FILE" 2>/dev/null || true

# ---------- 10. 成功输出 ----------
if [[ $JSON -eq 1 ]]; then
  python3 - "$BUNDLE_ID" "$APP" "$UDID" "$DEVNAME" "$SCHEME" "$T_BUILD" "$T_INSTALL" "$T_LAUNCH" "$ALIVE" "$VERIFY_SECS" <<'PY'
import json, os, sys
bundle, app, udid, name, scheme, tb, ti, tl, alive, wait = sys.argv[1:11]
print(json.dumps({
    "result": "success",
    "stage": "launched",
    "bundleId": bundle,
    "app": app,
    "scheme": scheme,
    "device": {"name": name, "udid": udid},
    "alive": True if alive == "1" else None,
    "verifySeconds": int(wait),
    "seconds": {"build": int(tb), "install": int(ti), "launch": int(tl)},
}, ensure_ascii=False, indent=None if os.environ.get("IOSRUN_COMPACT") == "1" else 1))
PY
else
  echo "✔ 编译 ${T_BUILD}s · 安装 ${T_INSTALL}s · 启动 ${T_LAUNCH}s"
  if [[ "$ALIVE" == "1" ]]; then
    echo "  运行: 正常（已存活 ${VERIFY_SECS}s）"
  elif [[ "$ALIVE" == "0" ]]; then
    echo "  运行: 未知"
  else
    echo "  运行: 未校验"
  fi
  echo "  设备: $DEVNAME（来源：${DEVSRC}）"
  echo "  Bundle: $BUNDLE_ID"
  echo "  产物: $APP"
fi

[[ $VERBOSE -eq 1 ]] && tail -20 "$LOG"
cp "$LOG" "$LASTLOG" 2>/dev/null || true
exit 0
