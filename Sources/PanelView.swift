import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            deviceRow
            actionRow
            statusRow
            if runner.phase.isFailure {
                if let diag = runner.diagnosis {
                    diagnosisCard(diag)
                } else if !runner.errors.isEmpty {
                    errorSummary
                }
            }
            if runner.showLog { logSection }
            footer
        }
        .padding(14)
        .frame(width: 480)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.projectName)
                    .font(.system(size: 13, weight: .semibold))
                Text(runner.projectDir)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                runner.chooseProject()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("切换项目（.xcworkspace / .xcodeproj）")
        }
    }

    // MARK: 设备

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: $runner.selectedUDID) {
                if runner.devices.isEmpty {
                    Text("未发现设备").tag("")
                }
                ForEach(runner.devices) { device in
                    Text(device.label).tag(device.udid)
                }
            }
            .labelsHidden()
            .disabled(runner.phase.isBusy)

            Button {
                runner.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新扫描设备")
        }
    }

    // MARK: 操作

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                runner.run()
            } label: {
                Label("运行", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!runner.canRun)

            Button {
                runner.clean()
            } label: {
                Label("Clean", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(runner.phase.isBusy || runner.projectURL == nil)
        }
    }

    // MARK: 状态

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(runner.phase.text)
                .font(.system(size: 11))
                .foregroundStyle(runner.phase.isFailure ? Color.red : .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if runner.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
            }
            if !runner.toast.isEmpty {
                Text(runner.toast)
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .frame(height: 16)
    }

    private var statusColor: Color {
        switch runner.phase {
        case .idle:    return .secondary
        case .busy:    return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: 诊断结论

    private func diagnosisCard(_ diag: Diagnosis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(diag.title, systemImage: "stethoscope")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(diag.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
    }

    // MARK: 错误摘要

    private var errorSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(runner.errors.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if runner.errors.count > 3 {
                Text("… 还有 \(runner.errors.count - 3) 处，点「复制错误」拿全部")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.08)))
    }

    // MARK: 日志

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(runner.log.isEmpty ? "暂无输出" : runner.log)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(runner.log.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("log-bottom")
            }
            .frame(height: runner.phase.isFailure ? 250 : 170)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.22)))
            .onChange(of: runner.log) { _ in
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button("复制错误") { runner.copyErrors() }
                .controlSize(.small)
                .disabled(runner.transcript.isEmpty)
            Button("复制全部") { runner.copyAll() }
                .controlSize(.small)
                .disabled(runner.transcript.isEmpty)
            Button("清空") { runner.clearLog() }
                .controlSize(.small)
                .disabled(runner.phase.isBusy)

            Spacer()

            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}
