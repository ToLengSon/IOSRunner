import Foundation
import AppKit

// MARK: - 数据模型

struct Device: Identifiable, Hashable {
    let udid: String
    let name: String
    let osVersion: String
    let connected: Bool
    let paired: Bool

    var id: String { udid }
    var label: String {
        paired ? "\(name) · iOS \(osVersion)" : "\(name) · 未配对"
    }
}

enum Phase: Equatable {
    case idle
    case busy(String)
    case success(String)
    case failure(String)

    var isBusy: Bool { if case .busy = self { return true }; return false }
    var isFailure: Bool { if case .failure = self { return true }; return false }
    var isSuccess: Bool { if case .success = self { return true }; return false }

    var text: String {
        switch self {
        case .idle:                     return "就绪"
        case .busy(let t), .success(let t), .failure(let t): return t
        }
    }
}

// MARK: - 子进程封装

final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var pending = ""
    private var exitCode: Int32?
    private var exitHandler: ((Int32) -> Void)?

    var isRunning: Bool { process.isRunning }

    func start(executable: String, arguments: [String], cwd: URL?) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.pending += String(decoding: data, as: UTF8.self)
            self.lock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? self.pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                self.lock.lock()
                self.pending += String(decoding: rest, as: UTF8.self)
                self.lock.unlock()
            }
            self.lock.lock()
            self.exitCode = proc.terminationStatus
            let handler = self.exitHandler
            self.lock.unlock()
            handler?(proc.terminationStatus)
        }

        try process.run()
    }

    /// 注册退出回调；若进程已经结束则立即回调，避免 continuation 悬挂。
    func setExitHandler(_ handler: @escaping (Int32) -> Void) {
        lock.lock()
        if let code = exitCode {
            lock.unlock()
            handler(code)
            return
        }
        exitHandler = handler
        lock.unlock()
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = pending
        pending = ""
        return text
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

// MARK: - 主控制器

final class Runner: ObservableObject {

    @Published var projectURL: URL?
    @Published var scheme: String = ""
    @Published var devices: [Device] = []
    @Published var selectedUDID: String = ""
    @Published var phase: Phase = .idle { didSet { onPhase?(phase) } }
    @Published var log: String = ""
    @Published var errors: [String] = []
    @Published var diagnosis: Diagnosis?
    @Published var showLog: Bool = false
    @Published var toast: String = ""

    var onPhase: ((Phase) -> Void)?

    private(set) var transcript = ""
    private var current: ProcessRunner?
    private var pollTimer: Timer?
    private var lastRefresh = Date.distantPast
    private let defaults = UserDefaults.standard

    init() {
        if let path = defaults.string(forKey: "projectPath"),
           FileManager.default.fileExists(atPath: path) {
            projectURL = URL(fileURLWithPath: path)
        } else {
            projectURL = Self.discoverProject()
        }
        selectedUDID = defaults.string(forKey: "deviceUDID") ?? ""
    }

    // MARK: 展示用属性

    var projectName: String {
        projectURL?.lastPathComponent ?? "未选择项目"
    }

    var projectDir: String {
        projectURL?.deletingLastPathComponent().path
            ?? "点击右侧文件夹图标选择 .xcodeproj / .xcworkspace"
    }

    var isWorkspace: Bool {
        projectURL?.pathExtension == "xcworkspace"
    }

    var canRun: Bool {
        !phase.isBusy && projectURL != nil && !selectedUDID.isEmpty
    }

    // MARK: 项目

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 .xcworkspace / .xcodeproj，或包含它的目录（CocoaPods 请选 .xcworkspace）"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        var container: URL?
        if ext == "xcworkspace" || ext == "xcodeproj" {
            container = Self.upgradeToWorkspace(url)
        } else {
            container = Self.firstContainer(in: url)
        }
        guard let container else {
            flashToast("该目录下没有 .xcworkspace / .xcodeproj")
            return
        }
        projectURL = container
        defaults.set(container.path, forKey: "projectPath")
        refreshDevices()
    }

    // MARK: 设备

    func refreshDevicesIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 10 { refreshDevices() }
    }

    func refreshDevices() {
        lastRefresh = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("iosrunner-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }

            var list: [Device] = []
            let pr = ProcessRunner()
            do {
                try pr.start(executable: "/usr/bin/xcrun",
                             arguments: ["devicectl", "list", "devices",
                                         "--json-output", tmp.path, "--quiet"],
                             cwd: nil)
                pr.waitUntilExit()
                if let data = try? Data(contentsOf: tmp) {
                    list = Self.parseDevices(data)
                }
            } catch { }

            DispatchQueue.main.async {
                self.devices = list
                if !list.contains(where: { $0.udid == self.selectedUDID }) {
                    self.selectedUDID = list.first(where: { $0.connected })?.udid
                        ?? list.first(where: { $0.paired })?.udid
                        ?? list.first?.udid ?? ""
                }
            }
        }
    }

    // MARK: 运行

    func run() {
        guard !phase.isBusy else { return }
        guard let project = projectURL else {
            phase = .failure("没有选择项目")
            return
        }
        guard !selectedUDID.isEmpty else {
            phase = .failure("没有可用设备，请连接 iPhone 并解锁")
            flashToast("请先连接设备")
            return
        }
        // 配对状态是稳定字段，可以安全地提前拦住
        if let dev = devices.first(where: { $0.udid == selectedUDID }), !dev.paired {
            phase = .failure("设备未配对")
            diagnosis = Diagnosis(title: "设备未配对",
                                  hint: "解锁 iPhone，在手机上点「信任此电脑」，然后在面板点 ↻ 刷新设备")
            refreshDevices()
            return
        }
        defaults.set(selectedUDID, forKey: "deviceUDID")

        transcript = ""
        log = ""
        errors = []
        diagnosis = nil
        showLog = true

        let udid = selectedUDID
        Task { await performRun(project: project, udid: udid) }
    }

    private func performRun(project: URL, udid: String) async {
        startPolling()
        defer { stopPolling() }

        let name = project.deletingPathExtension().lastPathComponent
        let derived = Self.cacheDirectory(for: name)
        try? FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)

        // 1. 解析 scheme
        var schemeName = name
        let (listCode, listOut) = await capture("/usr/bin/xcrun",
            ["xcodebuild", "-list", "-json"] + Self.containerArgs(for: project))
        if listCode == 0, let parsed = Self.firstScheme(from: listOut, preferred: name) {
            schemeName = parsed
        }
        ui { self.scheme = schemeName }

        // 2. 编译
        ui { self.phase = .busy("编译中…") }
        let buildCode = await exec("/usr/bin/xcrun",
            ["xcodebuild"]
            + Self.containerArgs(for: project)
            + [
                "-scheme", schemeName,
                "-configuration", "Debug",
                "-destination", "id=\(udid)",
                "-derivedDataPath", derived.path,
                "-allowProvisioningUpdates",
                "build"
            ],
            cwd: project.deletingLastPathComponent())

        if buildCode != 0 {
            let text = await currentTranscript()
            let errs = Self.extractErrors(from: text)
            let diag = Diagnoser.diagnose(text)
            ui {
                self.errors = errs
                self.showLog = true
                self.diagnosis = diag
                self.phase = .failure("编译失败")
            }
            return
        }

        // 3. 安装
        let app = derived.appendingPathComponent("Build/Products/Debug-iphoneos/\(schemeName).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            ui { self.phase = .failure("未找到产物 \(schemeName).app") }
            return
        }
        ui { self.phase = .busy("安装中…") }
        let installCode = await exec("/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", udid, app.path], cwd: nil)
        if installCode != 0 {
            let text = await currentTranscript()
            let errs = Self.extractErrors(from: text)
            let diag = Diagnoser.diagnose(text)
            ui {
                self.errors = errs
                self.diagnosis = diag
                self.phase = .failure("安装失败")
            }
            return
        }

        // 4. 启动
        ui { self.phase = .busy("启动中…") }
        let bundleID = Self.bundleID(of: app) ?? ""
        let launchCode = await exec("/usr/bin/xcrun",
            ["devicectl", "device", "process", "launch", "--device", udid,
             "--terminate-existing", bundleID], cwd: nil)
        if launchCode != 0 {
            let text = await currentTranscript()
            let diag = Diagnoser.diagnose(text)
            ui {
                self.errors = Self.extractErrors(from: text)
                self.diagnosis = diag
                self.phase = .failure("启动失败")
            }
            return
        }

        ui { self.phase = .success("已启动 · \(name)") }
    }

    // MARK: 清理

    func clean() {
        guard !phase.isBusy, let project = projectURL else { return }
        transcript = ""
        log = ""
        errors = []
        diagnosis = nil
        showLog = true
        Task { await performClean(project: project) }
    }

    private func performClean(project: URL) async {
        startPolling()
        defer { stopPolling() }

        let name = project.deletingPathExtension().lastPathComponent
        var schemeName = name
        let (code, out) = await capture("/usr/bin/xcrun",
            ["xcodebuild", "-list", "-json"] + Self.containerArgs(for: project))
        if code == 0, let parsed = Self.firstScheme(from: out, preferred: name) {
            schemeName = parsed
        }

        ui { self.phase = .busy("清理中…") }
        // 必须显式给 destination，否则 xcodebuild 会挑中 "My Mac" 直接报错
        let cleanCode = await exec("/usr/bin/xcrun",
            ["xcodebuild"]
            + Self.containerArgs(for: project)
            + [
                "-scheme", schemeName,
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", Self.cacheDirectory(for: name).path,
                "clean"
            ],
            cwd: project.deletingLastPathComponent())

        try? FileManager.default.removeItem(at: Self.cacheDirectory(for: name))

        ui {
            if cleanCode == 0 {
                self.phase = .success("已清理")
            } else {
                self.errors = Self.extractErrors(from: self.transcript)
                self.diagnosis = Diagnoser.diagnose(self.transcript)
                self.phase = .failure("清理失败")
            }
        }
    }

    // MARK: 复制

    func copyErrors() {
        var parts: [String] = []
        if let diag = diagnosis {
            parts.append("【诊断】\(diag.title)")
            parts.append("【建议】\(diag.hint)")
            parts.append("")
        }
        if !errors.isEmpty {
            parts.append("【原始错误】")
            parts.append(contentsOf: errors)
        } else if !transcript.isEmpty {
            parts.append(transcript)
        }

        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else {
            flashToast("还没有错误内容")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if diagnosis != nil {
            flashToast("已复制诊断 + \(errors.count) 处错误")
        } else {
            flashToast(errors.isEmpty ? "已复制日志" : "已复制 \(errors.count) 处错误")
        }
    }

    func copyAll() {
        guard !transcript.isEmpty else {
            flashToast("还没有日志")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        flashToast("已复制完整日志")
    }

    func clearLog() {
        transcript = ""
        log = ""
        errors = []
        diagnosis = nil
        showLog = false
        phase = .idle
    }

    private func flashToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.toast == text { self?.toast = "" }
        }
    }

    // MARK: 执行管道

    private func exec(_ tool: String, _ args: [String], cwd: URL?) async -> Int32 {
        let pr = ProcessRunner()
        do {
            try pr.start(executable: tool, arguments: args, cwd: cwd)
        } catch {
            ui { self.append("[启动失败] \(error.localizedDescription)\n") }
            return -1
        }
        ui { self.current = pr }
        let code: Int32 = await withCheckedContinuation { continuation in
            pr.setExitHandler { continuation.resume(returning: $0) }
        }
        ui {
            self.flush()
            self.current = nil
        }
        return code
    }

    private func capture(_ tool: String, _ args: [String]) async -> (Int32, String) {
        let pr = ProcessRunner()
        do {
            try pr.start(executable: tool, arguments: args, cwd: nil)
        } catch {
            return (-1, "")
        }
        let code: Int32 = await withCheckedContinuation { continuation in
            pr.setExitHandler { continuation.resume(returning: $0) }
        }
        return (code, pr.drain())
    }

    private func currentTranscript() async -> String {
        await withCheckedContinuation { continuation in
            ui { continuation.resume(returning: self.transcript) }
        }
    }

    private func append(_ text: String) {
        transcript += text
        if transcript.count > 600_000 {
            transcript = String(transcript.suffix(400_000))
        }
        log = transcript
    }

    private func flush() {
        guard let pr = current else { return }
        let chunk = pr.drain()
        guard !chunk.isEmpty else { return }
        append(chunk)
    }

    private func ui(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func startPolling() {
        ui {
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    private func stopPolling() {
        ui {
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.flush()
            self.current = nil
        }
    }

    // MARK: 工具方法

    static func extractErrors(from text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("error:") else { continue }
            if line.contains("BUILD FAILED") || line.contains("CompileSwiftSources") { continue }
            if seen.insert(line).inserted {
                result.append(line)
            }
        }
        return Array(result.prefix(200))
    }

    static func bundleID(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return obj["CFBundleIdentifier"] as? String
    }

    /// xcodebuild 的容器参数：workspace 用 -workspace，project 用 -project
    static func containerArgs(for url: URL) -> [String] {
        url.pathExtension.lowercased() == "xcworkspace"
            ? ["-workspace", url.path]
            : ["-project", url.path]
    }

    /// 优先同名 scheme，其次排除 Pods 类 scheme（CocoaPods 场景）
    static func firstScheme(from json: String, preferred: String = "") -> String? {
        guard let start = json.firstIndex(of: "{"),
              let data = String(json[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let container = (obj["workspace"] as? [String: Any])
            ?? (obj["project"] as? [String: Any])
            ?? [:]
        guard let schemes = container["schemes"] as? [String], !schemes.isEmpty else { return nil }

        if !preferred.isEmpty, let exact = schemes.first(where: { $0 == preferred }) {
            return exact
        }
        if let main = schemes.first(where: { !$0.lowercased().hasPrefix("pods") }) {
            return main
        }
        return schemes.first
    }

    static func parseDevices(_ data: Data) -> [Device] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }

        return devices.compactMap { device -> Device? in
            let hw = device["hardwareProperties"] as? [String: Any] ?? [:]
            let props = device["deviceProperties"] as? [String: Any] ?? [:]
            let conn = device["connectionProperties"] as? [String: Any] ?? [:]
            guard let udid = hw["udid"] as? String, !udid.isEmpty else { return nil }
            return Device(
                udid: udid,
                name: (hw["marketingName"] as? String) ?? (props["name"] as? String) ?? "iPhone",
                osVersion: props["osVersionNumber"] as? String ?? "?",
                connected: (conn["tunnelState"] as? String) == "connected",
                paired: (conn["pairingState"] as? String) == "paired"
            )
        }
    }

    static func cacheDirectory(for projectName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("IOSRunner", isDirectory: true)
            .appendingPathComponent("\(projectName)-DerivedData", isDirectory: true)
    }

    static func discoverProject() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["IOSRUNNER_PROJECT"],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }

        // 从可执行文件所在位置逐级向上找（分发包放在项目目录内时可直接命中）
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if let found = firstContainer(in: dir) { return found }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        // 不猜测用户的项目位置，交由用户在面板里选择
        return nil
    }

    /// 目录里优先取 .xcworkspace（CocoaPods），其次 .xcodeproj
    static func firstContainer(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let extensions = Set(["xcworkspace", "xcodeproj"])
        let candidates = items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                if lhs.pathExtension == rhs.pathExtension { return lhs.lastPathComponent < rhs.lastPathComponent }
                return lhs.pathExtension == "xcworkspace"
            }
        return candidates.first
    }

    /// 选了 .xcodeproj 但同目录存在同名 .xcworkspace 时，自动切到 workspace
    static func upgradeToWorkspace(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "xcodeproj" else { return url }
        let sibling = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("xcworkspace")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : url
    }
}
