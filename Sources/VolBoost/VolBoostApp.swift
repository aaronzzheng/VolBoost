import AppKit
import ServiceManagement
import SwiftUI

@main
enum VolBoostApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock tile, no menu bar menus, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Launch-at-login, backed by the system login item registry so the switch always
/// agrees with System Settings > General > Login Items.
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false

    init() { refresh() }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fails when running the bare binary rather than the .app bundle.
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't \(enabled ? "enable" : "disable") launch at login"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()

        if enabled, SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Approve VolBoost in Login Items"
            alert.informativeText = "macOS needs you to switch VolBoost on under "
                + "System Settings > General > Login Items."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let manager = AudioTapManager()
    private let loginItem = LoginItem()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hostingController: NSHostingController<PopoverView>!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                   accessibilityDescription: "VolBoost")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hostingController = NSHostingController(
            rootView: PopoverView(manager: manager, loginItem: loginItem))
        // Without this the controller reports a zero preferredContentSize, so the
        // popover places its frame from a default size and then shrinks to fit —
        // which drags the arrow away from the menu bar item.
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = hostingController

        manager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    @objc private func togglePopover() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // It may have been toggled in System Settings since we last looked.
            loginItem.refresh()
            // Resolve the SwiftUI content size before the popover reads it.
            hostingController.view.layoutSubtreeIfNeeded()
            popover.contentSize = hostingController.view.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit VolBoost", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
