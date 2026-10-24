import Foundation

/// 根据真实构建日志判断"到底缺了什么"，给出一句人话结论 + 修复步骤
struct Diagnosis {
    let title: String
    let hint: String
}

enum Diagnoser {

    private struct Rule {
        let title: String
        let hint: String
        let matches: (String) -> Bool
    }

    /// 顺序敏感：越具体的放越前面
    private static let rules: [Rule] = [

        Rule(
            title: "缺少 Apple 开发证书",
            hint: "打开 Xcode → Settings → Accounts 登录 Apple ID（免费账号即可），随便给一个项目签一次名以生成证书",
            matches: { $0.contains("no signing certificate") || $0.contains("no \"ios development\" signing certificate") }
        ),

        Rule(
            title: "Xcode 许可协议未同意",
            hint: "终端执行：sudo xcodebuild -license accept",
            matches: { $0.contains("not agreed to the xcode license") || $0.contains("agreeing to the license") }
        ),

        Rule(
            title: "xcode-select 指向了命令行工具，不是完整 Xcode",
            hint: "终端执行：sudo xcode-select -s /Applications/Xcode.app",
            matches: {
                $0.contains("active developer directory is a command line tools instance")
                    || $0.contains("xcodebuild requires xcode")
                    || $0.contains("requires xcode, but active developer directory")
            }
        ),

        Rule(
            title: "缺少 iOS SDK 组件",
            hint: "打开 Xcode → Settings → Components，下载 iOS 平台组件后重试",
            matches: {
                $0.contains("sdk is not installed")
                    || $0.contains("unable to find sdk")
                    || $0.contains("cannot find sdk")
                    || $0.contains("unable to locate a sdk")
            }
        ),

        Rule(
            title: "Bundle ID 不可用",
            hint: "项目 Target → General → Bundle Identifier 改成全局唯一（如 com.你的名字.项目名）",
            matches: {
                $0.contains("failed to register bundle identifier")
                    || $0.contains("bundle identifier is not available")
                    || $0.contains("does not match the entitlements file")
            }
        ),

        Rule(
            title: "没有选择开发者团队",
            hint: "项目 Target → Signing & Capabilities → Team 选择你的 Apple ID 账号",
            matches: { $0.contains("requires a development team") }
        ),

        Rule(
            title: "描述文件已过期",
            hint: "重新点一次「运行」即可自动续期（免费账号 7 天有效期）",
            matches: { $0.contains("provisioning profile") && $0.contains("expired") }
        ),

        Rule(
            title: "设备当前未连接",
            hint: "解锁 iPhone 并重新插好数据线（Wi-Fi 连接经常掉线，建议用 USB），然后在面板点 ↻ 刷新设备再运行",
            matches: {
                $0.contains("matching the provided destination specifier")
                    || $0.contains("unable to find a device matching")
                    || $0.contains("no devices are paired")
            }
        ),

        Rule(
            title: "手机处于锁屏状态",
            hint: "解锁 iPhone 后重新运行",
            matches: { $0.contains("device is locked") || $0.contains("kamddevicelocked") }
        ),

        Rule(
            title: "设备未开启开发者模式",
            hint: "手机：设置 → 隐私与安全性 → 开发者模式 → 打开并重启设备",
            matches: { $0.contains("failed to prepare device for development") || $0.contains("developer mode is not enabled") }
        ),

        Rule(
            title: "设备尚未信任开发者证书",
            hint: "手机：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任",
            matches: { $0.contains("not been explicitly trusted") }
        ),

        Rule(
            title: "钥匙串被锁定，无法签名",
            hint: "打开「钥匙串访问」解锁登录钥匙串；或在弹出的授权框里输入密码并选「始终允许」",
            matches: {
                $0.contains("user interaction is not allowed")
                    || $0.contains("errsecinternalcomponent")
                    || $0.contains("the specified item could not be found in the keychain")
            }
        ),

        Rule(
            title: "代码签名失败",
            hint: "确认证书有效；首次运行请在钥匙串弹窗中选「始终允许」",
            matches: { $0.contains("command codesign failed") }
        ),

        Rule(
            title: "CocoaPods 依赖没装好 / 选错了容器",
            hint: "应选择 .xcworkspace；若同目录没有，先在项目目录执行 pod install",
            matches: {
                ($0.contains("pods") && $0.contains("file not found"))
                    || $0.contains("no such module 'pods_")
                    || $0.contains("pods-") && $0.contains("umbrella header")
            }
        )
    ]

    static func diagnose(_ log: String) -> Diagnosis? {
        guard !log.isEmpty else { return nil }
        let lower = log.lowercased()
        for rule in rules where rule.matches(lower) {
            return Diagnosis(title: rule.title, hint: rule.hint)
        }
        return nil
    }
}
