# iOS DevKit —— 不开 Xcode 做 iOS 开发

一套让「改代码 → 编译 → 装到 iPhone → 验证」脱离 Xcode 界面的工具组合，日常可省 3–6 GB 内存。

## 包含什么

| 内容 | 说明 |
|---|---|
| `IOSRunner.app` | 状态栏工具。点图标 → 选设备 → 运行，失败直接给诊断结论 |
| `skills/ios-run/` | Agent Skill。在对话里说「跑一下」，AI 自动编译安装并处理错误（CodeBuddy / Cursor 通用） |
| `install.sh` | 一键安装上面两样 + 环境检查 |
| `使用手册.md` | 工具详细手册（界面、排障、命令速查） |
| `Skill-使用手册.md` | Skill 的安装、对话用法、参数与输出解读 |

两者互不依赖，**按你的习惯选一个用即可**：

- 想自己点按钮 → 用 `IOSRunner.app`
- 想让 AI 全程代劳 → 用 Skill
- 两个都装也没问题，它们共用同一套诊断规则

## 安装

**从分发包安装**（推荐给使用者）：

```bash
cd iOS-DevKit
chmod +x install.sh && ./install.sh
```

**从源码构建**（开发者）：

```bash
git clone <本仓库地址>
cd <仓库目录>
./build.sh --run      # 编译并启动状态栏工具
./pack.sh             # 生成完整分发包 dist/iOS-DevKit.zip
```

目录结构：

```
Sources/            源码（main / Runner / PanelView / Diagnosis）
skills/ios-run/     Agent Skill（CodeBuddy / Cursor 通用）
build.sh            编译 .app（arm64，adhoc 签名）
pack.sh             打包完整分发包
install.sh          安装到本机
使用手册.md         工具手册
Skill-使用手册.md   Skill 手册
```

安装位置：

- `/Applications/IOSRunner.app`
- `~/.codebuddy/skills/ios-run/`（CodeBuddy）
- `~/.cursor/skills/ios-run/`（Cursor，检测到才装；`SKIP_CURSOR=1` 可跳过）

`install.sh` 末尾会自动检查环境（芯片、Xcode、SDK、证书、设备），有 ✗ 的项按提示处理。

> 换目录安装：`PREFIX=~/Applications ./install.sh`

## 首次打开工具会被系统拦

因为它是 ad-hoc 签名、未公证：

- **右键 → 打开 → 打开**
- 或 `xattr -dr com.apple.quarantine /Applications/IOSRunner.app`
- 仍不行：系统设置 → 隐私与安全性 → 底部「仍要打开」

工具本身**没有有效期，不会过期**。

## 两种用法

**① 状态栏工具**

点 🔨 → 选项目（`.xcworkspace` / `.xcodeproj`）→ 选设备 → 运行。

**② Agent Skill（CodeBuddy / Cursor 通用）**

重启 CodeBuddy 或 Cursor 后直接说：

```
把标题改成"设置"，然后跑一下
```

AI 会改代码、编译、安装、启动；失败时读诊断结果自己修，环境问题才回来找你。

也可不经 AI 直接用命令行：

```bash
bash ~/.codebuddy/skills/ios-run/scripts/ios-run.sh -p ~/项目/App.xcworkspace
# Cursor 装的副本路径 ~/.cursor/skills/ios-run/scripts/ios-run.sh，完全等价
```

## 前置条件

只有两件事必须用 Xcode 做一次（之后不用再开）：

1. **登录 Apple ID**：Xcode → Settings → Accounts（免费账号即可，用于生成签名证书）
2. **下载 iOS SDK**：Xcode → Settings → Components

其余要求：

- Apple Silicon（M 系列），macOS 13+
- 完整 Xcode（不是只有 Command Line Tools）
- iPhone 已配对、已信任此电脑；iOS 16+ 需开启「开发者模式」并重启
- 项目本身能在 Xcode 里编译通过

## 两个会反复遇到的点

- **手机上 App 7 天过期**：免费 Apple ID 的描述文件有效期 7 天，到期闪退。重新运行一次即可续期，数据不丢。
- **第一次装到新手机要信任证书**：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。

---

详细内容见 [`使用手册.md`](使用手册.md)（工具）与 [`Skill-使用手册.md`](Skill-使用手册.md)（Skill）。
