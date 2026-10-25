# v1.0 —— 不开 Xcode 也能跑 iOS 到真机

把「改完代码 → 编译 → 装到 iPhone → 验证」从 Xcode 里解放出来，日常可省 3–6 GB 内存。

## 包含

### IOSRunner.app（菜单栏工具）

- 设备下拉选择，自动发现已配对的 iPhone
- 一键「运行」/「Clean」，状态图标随构建状态变化
- 实时日志区，可拖选复制；`复制错误` 只导出关键行，便于排查或求助
- **14 类环境问题自动诊断**：缺证书、SDK 未装、`xcode-select` 指错、设备未连接、未信任、Bundle ID 冲突、Pods 未安装等，直接给出修复步骤

### Agent Skill `ios-run`（CodeBuddy / Cursor 通用）

- 在对话里说「跑一下」，AI 自动完成编译 → 安装 → 启动
- 失败时返回结构化诊断：代码问题自己改自己重跑，环境问题才找你
- 也可脱离 AI 直接用命令行：`ios-run.sh -p ~/项目/App.xcworkspace`

## 安装

下载 `iOS-DevKit.zip`，解压后：

```bash
cd iOS-DevKit
chmod +x install.sh && ./install.sh
```

- 工具 → `/Applications/IOSRunner.app`（无写权限时自动装到 `~/Applications`）
- Skill → `~/.codebuddy/skills/ios-run` 与 `~/.cursor/skills/ios-run`（检测到才装）

准备发给别人的话，把 `iOS-DevKit.zip` 直接传过去即可，对方跑一次 `install.sh` 就完成。

## 环境要求

| 项目 | 要求 |
|---|---|
| 芯片 | Apple Silicon（M 系列），不支持 Intel |
| 系统 | macOS 13.0+ |
| Xcode | 完整版 Xcode.app（不是 Command Line Tools） |
| 签名 | 至少一个 Apple Development 证书（免费 Apple ID 即可） |
| 设备 | iPhone 已配对、已信任此电脑；iOS 16+ 需开启开发者模式 |

仅有一步绕不开：**首次需在 Xcode 里登录 Apple ID 并下载 iOS SDK 组件**，之后日常不再打开 Xcode。

## 关于过期

- 工具本体是 ad-hoc 签名，**没有证书也没有有效期，不会过期**
- 手机上的 App 有效期取决于你的开发者账号：免费账号 7 天，付费账号 1 年。到期闪退后重新点一次「运行」即自动续期，数据不丢

## 已知限制

- 仅支持 Debug 构建到真机，不含 Archive / 上架流程
- 不含 Intel Mac 支持
- 模拟器需自行使用 `xcrun simctl`

---

### TL;DR (English)

A macOS menu bar app plus an agent skill that builds, installs and launches an iOS app on a physical device without opening Xcode. Auto-diagnoses 14 common environment failures (signing, SDK, device connection, CocoaPods, …). Apple Silicon only, macOS 13+, requires full Xcode installed (Apple ID sign-in once).
