---
name: ios-run
description: 在不开 Xcode 的情况下完成 iOS 真机开发闭环——编译、安装、启动到 iPhone，并在失败时自动诊断原因（开发证书、iOS SDK、xcode-select、设备连接、CocoaPods 等）。当需要把 iOS 项目构建并运行到真机、验证代码改动、清理构建产物后重新编译、排查真机构建/安装/启动失败、查看已连接设备时使用。触发说法包括：跑一下 / 运行一下这个 App、启动 App 看效果、装到手机上、真机上跑、真机调试、xcodebuild 构建、clean 一下 / 清理构建产物 / 清 DerivedData / 重新编译、签名或证书报错、看不到设备。
---

# iOS 真机运行

## 用途

替代打开 Xcode 完成「编译 → 安装到 iPhone → 启动」，并把失败原因翻译成人话。  
适合内存紧张、或希望由 CodeBuddy 独立完成「改代码 → 验证」闭环的场景。

Xcode 本体不需要打开，但必须已安装（提供 `xcodebuild`、iOS SDK、签名能力）。

## 核心脚本

本 skill 目录下的 `scripts/ios-run.sh`。安装位置：

- CodeBuddy：`~/.codebuddy/skills/ios-run/`
- Cursor：`~/.cursor/skills/ios-run/`

一条命令走完编译 → 安装 → 启动 → 校验存活，闪退时自动给出崩溃帧。完整日志写文件，终端只输出结论。

```bash
S=<本skill目录>/scripts/ios-run.sh

# 最常用：当前目录找容器，自动选设备（上次用过的 > 唯一在线）
bash $S

# 指定项目 / 设备 / scheme
bash $S -p ~/proj/App.xcworkspace -d "iPhone 13" -s App

# 机器可读（推荐给自动化用）
bash $S --json

# 清理后重编
bash $S --clean

# 启动后等 5s 再判断是否闪退（默认 3s，0 关闭校验）
bash $S --wait 5

# 图形界面用的事件流（NDJSON，界面逐行解析，无需读这一项）
bash $S --events
```

自动化场景优先用 `--json`，只解析需要的字段，避免把几百行构建日志读进上下文。

## 设备是怎么选的

按顺序取第一个可用项，日常「跑一下」不带参数也能确定，不会反问用户：

1. `-d` 指定（可用设备名或 UDID，允许离线，由 `xcodebuild` 给出精确诊断）
2. `IOSRunner.app` 里选中的设备（离线时直接报错，**不静默换机**，避免装错设备）
3. 本脚本上次成功启动的设备（仍需在线）
4. 当前唯一在线的已配对设备
5. 多台都在线且无历史记录 → 报错并列出候选，此时才需要问用户

「在线」以 `xcrun xctrace list devices` 的可达列表为准，`devicectl` 的 `tunnelState` 只作兜底。**历史配对过、如今已离线的设备不参与计数**，所以配过几台旧设备不会导致每次都要求 `-d`。`--list` 会标出 `← IOSRunner 选中` 和 `← 上次使用`。

### 需要用户选设备时的标准问法

脚本自身不会交互提问，它只以 `stage: setup` 失败退出并列出候选。收到「检测到 N 台在线设备」时**不要自己猜**，先跑 `--list` 拿 UDID，再按下面格式问一次：

> 检测到 2 台 iPhone 在线，需要确认装到哪台：
> 1. iPhone 13（00008110-…）← 上次使用
> 2. iPhone 15（00008110-…）
>
> 回复序号或设备名即可；想以后不再被问，可在菜单栏 IOSRunner 里选一次。

用户回复后，用 `-d "<名字或 UDID>"` 重跑，**不要在后续轮次重复询问**。若两台同名，必须让用户确认序号并改用 UDID 传参。

## 标准工作流

1. 修改代码
2. 执行 `ios-run.sh --json`（项目路径用 `-p` 指定）
3. 读取输出，先看 `result`：
   - `result: success` + `alive: true` → 进程已存活，告知用户在手机上验证效果
   - `result: success` + `alive: null` → 启动成功但查询进程失败（设备掉线等），按成功处理
   - `result: failure` + `stage: 运行` → **闪退**，见第 4 步
   - `result: failure` + 其他 stage → 编译/安装失败，见第 5 步
4. **闪退（`stage: 运行`）闭环**：
   - `frames` 里带 `文件:行` 的那一帧就是崩溃点，直接改那段代码，然后重跑，不要反问用户
   - 帧全落在系统库时，用 `reason` 判断类型：`unrecognized selector`（调了不存在的方法）、`index beyond bounds`（越界）、`unexpectedly found nil`（强制解包）、`EXC_BAD_ACCESS`（野指针/并发释放）
   - **交互触发的闪退**（用户说「点某个按钮后崩」）3 秒校验抓不到，要用 `--wait 30` 重跑，并提示用户现在去点按钮
   - 需要更多上下文时读 `crashReport` 指向的 `.ips`（已持久化到 `~/Library/Caches/ios-run/crash/`），**不要建议用户开 Xcode**
   - 同一处连续两次改动后仍崩，把 `reason` 和 `frames` 原文交给用户，停止盲改
5. **编译/安装失败**按 `hint` 处理：
   - 若是**代码问题**（`errors` 里是 `文件:行:列: error: ...`）→ 直接改代码，然后重跑，不要反问用户
   - 若是**环境问题**（`diagnosis` 非空，如证书、SDK、设备）→ 告知用户需要做的那一步，这属于用户侧操作
6. 连续两次因环境问题失败时，停止重试，明确告诉用户缺什么

## 输出格式

成功：

```
✔ 编译 12s · 安装 3s · 启动 1s
  设备: iPhone 13
  Bundle: study.Test.bbc
  产物: ~/Library/Caches/ios-run/Test-DerivedData/Build/Products/Debug-iphoneos/Test.app
```

失败：

```
✘ 编译失败（耗时 8s）
  诊断: 缺少 Apple 开发证书
  建议: 打开 Xcode → Settings → Accounts 登录 Apple ID（免费账号即可）
  错误:
    error: No signing certificate "iOS Development" found: ...
  日志: ${TMPDIR}/ios-run-last.log
```

闪退（`stage: 运行`，脚本自己从设备拉崩溃日志）：

```
✘ 运行失败：启动后 12s 内退出（闪退）
  诊断: 运行中闪退（EXC_CRASH）
  原因: *** -[__NSArray0 objectAtIndex:]: index 3 beyond bounds for empty array
  建议: 按崩溃帧里的 文件:行 定位并修复，然后重跑；若帧全在系统库，看 原因 里的异常信息
  崩溃栈:
    -[ViewController crashNow] (in Test) (ViewController.m:219)
    main (in Test) (main.m:17)
    __exceptionPreprocess + 164
  崩溃报告: ~/Library/Caches/ios-run/crash/Test-2026-10-25-121854.ips
  日志: ${TMPDIR}/ios-run-last.log
```

JSON：

```json
{
  "result": "failure",
  "stage": "编译",
  "diagnosis": "缺少 Apple 开发证书",
  "hint": "打开 Xcode → Settings → Accounts 登录 Apple ID…",
  "errors": ["error: No signing certificate ..."],
  "device": {"name": "iPhone 13", "udid": "00008110-..."},
  "log": "${TMPDIR}/ios-run-last.log"
}
```

完整日志固定备份到 `${TMPDIR}/ios-run-last.log`，需要时再 grep，不要整段读入上下文。

## 必须知道的事实（踩过的坑）

1. **destination 用 UDID**：形如 `00008110-XXXXXXXXXXXXXXXX`。`devicectl list devices` 输出里的 `XXXXXXXX-...` 是另一个标识，填给 `-destination` 会报找不到。
2. **clean 必须带 destination**：`-destination 'generic/platform=iOS'`。不带的话 `xcodebuild` 会挑中 `My Mac`，在 macOS 版本不匹配的机器上报 `Xcode doesn't support My Mac's macOS`。
3. **`tunnelState` 不可靠**：设备正常时也可能显示 `disconnected`（实测常见）。是否可用以 `xcrun xctrace list devices` 的可达列表为准，其次是 `xcodebuild -showdestinations` 或实际构建结果，不要用它做前置拦截。
4. **CocoaPods 项目必须用 `.xcworkspace`**：用 `.xcodeproj` 会报一堆 `Pods` 头文件找不到。脚本遇到目录里有 workspace 会自动优先选它。
5. **产物路径**：`<derivedData>/Build/Products/<Config>-iphoneos/<Scheme>.app`，脚本默认 derivedData 在 `~/Library/Caches/ios-run/<项目名>-DerivedData`。
6. **免费账号 profile 7 天过期**：手机上的 App 到期会闪退，重新运行一次即自动续期，数据不丢。
7. **首次运行需要在手机上信任证书**：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。iOS 16+ 还需先开启「开发者模式」并重启。
8. **不要用 `open -a Xcode`**，也不要建议用户打开 Xcode 来做日常运行，只在必须登录 Apple ID 或下载 SDK 组件时才指引打开。
9. **launch 返回 0 ≠ 启动成功**：`devicectl process launch` 只保证启动请求被接受，App 秒退同样返回 0。脚本默认启动后等 3s 回查进程存活（`--wait` 调整，`0` 关闭），闪退时自动从设备 `systemCrashLogs` 域拉 `.ips` 并解析出崩溃帧，**全程不需要打开 Xcode**。
10. **构建默认带 dSYM**：脚本给 `xcodebuild` 传 `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`。Debug 默认是 `dwarf`，二进制会被 strip，闪退栈只剩 `Foo + 5888872` 这种地址，无法定位。有 dSYM 后 App 帧会自动用 `atos` 还原成 `文件:行`。若仍显示「未符号化」，说明 dSYM 与设备上的包不匹配（代码改过但没重新构建安装）。
11. **App 帧优先**：崩溃栈前几条常是系统库（CoreFoundation、libsystem_*），那是表象；脚本会把 App 自己的帧排在前面，根因优先看它。帧全在系统库时，靠 `reason` 判断（如 `unrecognized selector`、野指针）。

## 环境前提

- Apple Silicon Mac，macOS 13+
- 完整 Xcode（非仅 Command Line Tools），`xcode-select -p` 指向 `/Applications/Xcode.app/Contents/Developer`
- 至少一个 `Apple Development` 证书
- iPhone 已配对、已信任此电脑
- 项目本身能在 Xcode 里编译通过

## 附带的可选工具

若用户希望自己手动点按钮（而不是每次找 CodeBuddy），可介绍状态栏工具 `IOSRunner.app`：

- 安装位置：`/Applications/IOSRunner.app`
- 双击启动后菜单栏出现 🔨 图标，提供设备下拉、运行、Clean、日志复制、错误诊断
- 与本 skill 互不依赖：skill 走命令行，工具走界面，两者使用同一套诊断规则
- 未安装时，从同一分发包中获取并用 `install.sh` 安装

首次打开若被 Gatekeeper 拦截，用「右键 → 打开」，或执行 `xattr -dr com.apple.quarantine /Applications/IOSRunner.app`。
