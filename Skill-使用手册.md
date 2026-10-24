# Skill `ios-run` 使用手册

> CodeBuddy 与 Cursor 通用。两者都使用 `SKILL.md` 格式，同一份技能可同时安装到
> `~/.codebuddy/skills/` 与 `~/.cursor/skills/`。

## 1. 它是什么

一个 Agent Skill，让 AI 能独立完成 iOS 真机闭环：

```
你：标题改成"设置"，然后跑一下
AI：改代码 → 编译 → 安装到 iPhone → 启动 → "已启动，请看手机"
```

编译失败时，AI 拿到的是结构化结果而不是几百行日志，能直接定位问题、改代码、重跑；只有环境类问题（证书、SDK、设备）才会回来找你。

**不打开 Xcode，也不需要状态栏工具。**

## 2. 安装

```bash
./install.sh                    # 工具 + CodeBuddy Skill + Cursor Skill 一次装好
SKIP_CURSOR=1 ./install.sh      # 只装 CodeBuddy
```

或手动分别安装：

```bash
# CodeBuddy
mkdir -p ~/.codebuddy/skills
cp -R skills/ios-run ~/.codebuddy/skills/
chmod +x ~/.codebuddy/skills/ios-run/scripts/ios-run.sh

# Cursor（注意不是 skills-cursor，那个目录是 Cursor 内置技能专用）
mkdir -p ~/.cursor/skills
cp -R skills/ios-run ~/.cursor/skills/
chmod +x ~/.cursor/skills/ios-run/scripts/ios-run.sh
```

安装后**重启对应编辑器**，新会话即自动加载。

| 编辑器 | 个人 skill 目录 | 项目级目录 |
|---|---|---|
| CodeBuddy | `~/.codebuddy/skills/` | `.codebuddy/skills/` |
| Cursor | `~/.cursor/skills/` | `.cursor/skills/` |

> Cursor 的 `~/.cursor/skills-cursor/` 是内置技能保留目录，**不要**往里放自定义技能。

验证是否生效：问 CodeBuddy「你现在能做 iOS 真机运行吗」，或直接说「跑一下」。

## 3. 在对话里怎么用

触发方式很自然，只要提到「跑一下 / 运行到手机 / 装到手机上 / 真机调试 / 验证改动 / 编译看看 / 签名报错 / 看不到设备」即可：

```
这个按钮颜色改成蓝色，然后跑一下
```

```
跑一下，装到我手机上
```

```
刚才的改动编译不过，你修一下再跑
```

AI 的行为约定：

- 代码错误 → 自己改、自己重跑，不反问你
- 环境错误 → 明确告诉你缺什么、去哪做（例如登录 Apple ID）
- 连续两次环境失败 → 停止重试，直接说明阻塞点

## 4. 命令行直接调用

不想经过 AI 时直接用脚本：

```bash
S=~/.codebuddy/skills/ios-run/scripts/ios-run.sh

bash $S                                   # 当前目录找项目，自动选设备
bash $S -p ~/proj/App.xcworkspace         # 指定项目（CocoaPods 用 workspace）
bash $S -d "iPhone 13"                    # 指定设备（名字或 UDID）
bash $S -s MyApp                          # 指定 scheme
bash $S --clean                           # 先清理再构建
bash $S --config Release                  # 默认 Debug
bash $S --json                            # 机器可读输出
bash $S -v                                # 打印完整日志
```

### 成功输出

```
✔ 编译 6s · 安装 3s · 启动 0s
  设备: iPhone 13
  Bundle: study.Test.bbc
  产物: ~/Library/Caches/ios-run/Test-DerivedData/Build/Products/Debug-iphoneos/Test.app
```

### 失败输出

```
✘ 编译失败（耗时 8s）
  诊断: 缺少 Apple 开发证书
  建议: 打开 Xcode → Settings → Accounts 登录 Apple ID（免费账号即可），并给任意项目签一次名
  错误:
    error: No signing certificate "iOS Development" found: ...
  日志: ${TMPDIR}/ios-run-last.log
```

### JSON 格式

```json
{
  "result": "failure",
  "stage": "编译",
  "exitCode": 65,
  "diagnosis": "缺少 Apple 开发证书",
  "hint": "打开 Xcode → Settings → Accounts 登录 Apple ID…",
  "errors": ["error: No signing certificate ..."],
  "scheme": "Test",
  "container": "/Users/me/proj/Test.xcodeproj",
  "device": { "name": "iPhone 13", "udid": "00008110-..." },
  "log": "${TMPDIR}/ios-run-last.log"
}
```

成功时：

```json
{
  "result": "success",
  "stage": "launched",
  "bundleId": "study.Test.bbc",
  "app": ".../Test.app",
  "scheme": "Test",
  "device": { "name": "iPhone 13", "udid": "00008110-..." },
  "seconds": { "build": 6, "install": 3, "launch": 0 }
}
```

**完整日志固定备份在 `${TMPDIR}/ios-run-last.log`**，不会刷屏；需要细节时再 grep。

## 5. 它能自动识别的 14 类问题

| 诊断结论 | 日志特征 |
|---|---|
| 设备当前未连接 | `matching the provided destination specifier` |
| 缺少 Apple 开发证书 | `No signing certificate "iOS Development"` |
| Xcode 许可协议未同意 | `not agreed to the Xcode license` |
| xcode-select 指向命令行工具 | `requires Xcode` / `command line tools instance` |
| 缺少 iOS SDK 组件 | `SDK is not installed` |
| Bundle ID 不可用 | `Failed to register bundle identifier` |
| 未选择开发者团队 | `requires a development team` |
| 描述文件已过期 | `provisioning profile ... expired` |
| 设备未信任开发者证书 | `not been explicitly trusted` |
| 手机锁屏 | `device is locked` |
| 设备未开启开发者模式 | `Failed to prepare device for development` |
| 钥匙串被锁定 | `User interaction is not allowed` |
| 代码签名失败 | `Command CodeSign failed` |
| CocoaPods 依赖未安装 | `Pods` + `file not found` |

没命中的（例如语法错误）会退回显示 `文件:行:列: error: ...`。

## 6. 脚本替你处理的坑

1. **destination 必须用 UDID**（`00008110-...`），不是 `devicectl` 输出里的那个 UUID —— 填错会报 destination 找不到
2. **clean 必须带 `-destination 'generic/platform=iOS'`** —— 否则 xcodebuild 会挑中 `My Mac`，在系统版本不匹配时报错
3. **CocoaPods 项目自动优先 `.xcworkspace`** —— 用 `.xcodeproj` 会缺 Pods
4. **设备自动选择** —— `-d` > App 选中 > 上次使用 > 唯一在线；历史配对但已离线的设备不参与计数。「在线」以 `xctrace list devices` 为准，`tunnelState` 会抖动，只作兜底
5. **derivedData 集中存放** —— `~/Library/Caches/ios-run/<项目>-DerivedData`，不污染项目目录
6. **日志不刷屏** —— 只在终端输出结论，全量进文件

## 7. 环境要求

- Apple Silicon Mac，macOS 13+
- 完整 Xcode + `xcode-select -p` 指向 `/Applications/Xcode.app/Contents/Developer`
- 至少一个 `Apple Development` 证书（免费 Apple ID 即可）
- iPhone 已配对、已信任此电脑，iOS 16+ 需开启开发者模式
- 项目能在 Xcode 里正常编译

自检命令：

```bash
uname -m                                     # arm64
xcode-select -p                              # …/Xcode.app/Contents/Developer
xcodebuild -version                          # Xcode 16.x
xcodebuild -showsdks | grep iphoneos         # 有 iOS SDK
security find-identity -v -p codesigning | grep "Apple Development"
xcrun devicectl list devices                 # 看到 iPhone
```

## 8. 故障排查

**说「跑一下」AI 没反应？**
Skill 未安装或未重启 CodeBuddy。检查 `~/.codebuddy/skills/ios-run/SKILL.md` 是否存在。

**脚本报「没有在线的 iPhone」**
数据线连接 → 解锁 → 手机上点「信任此电脑」。历史配对过但当前不在设备旁的手机不算在线，不会误选。

**手机上 App 7 天后闪退**
免费账号 profile 过期，重新跑一次即续期。

**第一次装到新手机打不开**
手机上信任证书：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。

**编译报 `Xcode doesn't support My Mac's macOS …`**
这是 `My Mac` 这个 destination 的错误，说明没指定真机 destination。用脚本跑不会出现；手写命令时要带 `-destination 'id=<UDID>'`。

**想改脚本**
`~/.codebuddy/skills/ios-run/scripts/ios-run.sh`，改完立刻生效（无需重启 CodeBuddy）。诊断规则在同文件的 `diagnose()` 函数里。
