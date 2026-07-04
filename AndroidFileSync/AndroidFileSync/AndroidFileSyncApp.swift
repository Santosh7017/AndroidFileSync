
import SwiftUI
import AppKit

extension Notification.Name {
    static let afsDeleteShortcut = Notification.Name("afsDeleteShortcut")
    static let afsPermanentDeleteShortcut = Notification.Name("afsPermanentDeleteShortcut")
    static let afsTransferCountChanged = Notification.Name("afsTransferCountChanged")
    static let afsDownloadBatchCompleted = Notification.Name("afsDownloadBatchCompleted")
    static let afsUploadBatchCompleted = Notification.Name("afsUploadBatchCompleted")
    static let afsDownloadBatchStateChanged = Notification.Name("afsDownloadBatchStateChanged")
    static let afsUploadBatchStateChanged = Notification.Name("afsUploadBatchStateChanged")
    static let afsDeletionsChanged = Notification.Name("afsDeletionsChanged")
}

@main
struct AndroidFileSyncApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create managers at App level to prevent ContentView re-evaluation
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var uploadManager = UploadManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceManager: deviceManager,
                downloadManager: downloadManager,
                uploadManager: uploadManager
            )
        }
        .defaultSize(width: 1050, height: 660)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowStyle(.titleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let dropCoordinator = DropCoordinator()
    private let showQuitDebuggingReminderKey = "showQuitDebuggingReminder"
    private var localKeyMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.santosh.AndroidFileSync1"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if runningApps.count > 1 {
            AppLogger.log("⚠️ Another instance of AndroidFileSync is already running. Activating the existing instance and terminating this one.", level: .warning)
            for app in runningApps {
                if app != NSRunningApplication.current {
                    app.activate(options: .activateIgnoringOtherApps)
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                    break
                }
            }
            return
        }
        
        AppLogger.addSessionSeparator()
        AppLogger.log("🚀 AndroidFileSync started successfully on macOS.")
        guard let window = NSApp.windows.first,
              let contentView = window.contentView else {
            return
        }
        
        // Allow dragging the window from any non-interactive area
        // (path bar, empty space, breadcrumbs etc.) — the correct Apple approach
        window.isMovableByWindowBackground = true
        
        // Register for drag-and-drop
        contentView.registerForDraggedTypes([.fileURL])
        (contentView as? NSView)?.window?.registerForDraggedTypes([.fileURL])
        
        installDeleteShortcutMonitor()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shouldShowReminder = UserDefaults.standard.object(forKey: showQuitDebuggingReminderKey) as? Bool ?? true
        guard shouldShowReminder else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Before quitting"
        alert.informativeText = "If you don't need debugging right now, turn off Wireless debugging (or USB debugging) on your phone for better security and battery life."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: showQuitDebuggingReminderKey)
        }

        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }

        // Default behavior: ensure phone does not stay "wireless debugging connected"
        // after app exit for single-app users.
        // Advanced/shared-ADB users can opt out via UserDefaults flag.
        let disconnectAllOnQuit = UserDefaults.standard.object(forKey: "disconnectAllWirelessOnQuit") as? Bool ?? true
        if disconnectAllOnQuit {
            _ = Shell.run(adbPath, args: ["disconnect"])
        } else {
            ADBManager.disconnectAppManagedWirelessSync()
        }

    }

    private func installDeleteShortcutMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 51 else { return event } // Backspace/Delete key
            guard NSApp.modalWindow == nil else { return event }
            guard NSApp.keyWindow?.attachedSheet == nil else { return event }
            guard !self.shouldBypassDeleteShortcutForTextInput() else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            let commandOnly: NSEvent.ModifierFlags = [.command]
            let commandOption: NSEvent.ModifierFlags = [.command, .option]

            if flags == commandOnly {
                NotificationCenter.default.post(name: .afsDeleteShortcut, object: nil)
                return nil
            }
            if flags == commandOption {
                NotificationCenter.default.post(name: .afsPermanentDeleteShortcut, object: nil)
                return nil
            }
            return event
        }
    }

    private func shouldBypassDeleteShortcutForTextInput() -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isFieldEditor else {
            return false
        }

        // Keep normal Cmd+Delete behavior in text inputs, except search fields where
        // we want file-level delete shortcuts to keep working without pressing Esc first.
        if let delegate = textView.delegate {
            if delegate is NSSearchField {
                return false
            }
            let delegateType = String(describing: type(of: delegate))
            if delegateType.localizedCaseInsensitiveContains("search") {
                return false
            }
        }
        return true
    }
}

struct ConnectionBadge: View {
    let type: DeviceManager.ConnectionType
    
    var body: some View {
        HStack(spacing: 4) {
            switch type {
            case .usb:
                Image(systemName: "bolt.fill")
                Text("USB")
                    .font(.caption)
            case .wireless:
                Image(systemName: "wifi")
                Text("WiFi")
                    .font(.caption)
            case .none:
                Image(systemName: "xmark.circle")
                Text("Disconnected")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeColor)
        .cornerRadius(4)
    }
    
    private var badgeColor: Color {
        switch type {
        case .usb: return Color.blue.opacity(0.2)
        case .wireless: return Color.green.opacity(0.2)
        case .none: return Color.gray.opacity(0.2)
        }
    }
}
