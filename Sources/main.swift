import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let runner = Runner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = symbol("hammer")
            button.toolTip = "iOS Runner"
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hosting = NSHostingController(rootView: PanelView(runner: runner))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        runner.onPhase = { [weak self] phase in
            guard let self else { return }
            let name: String
            if phase.isBusy {
                name = "hourglass"
            } else if phase.isFailure {
                name = "exclamationmark.triangle.fill"
            } else if phase.isSuccess {
                name = "checkmark.circle"
            } else {
                name = "hammer"
            }
            self.statusItem.button?.image = self.symbol(name)
        }

        runner.refreshDevices()
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "iOS Runner")
        image?.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        runner.refreshDevicesIfStale()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
