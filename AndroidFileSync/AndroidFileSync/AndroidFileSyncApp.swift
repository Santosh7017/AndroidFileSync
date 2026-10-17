
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
            .onAppear {
                appDelegate.deviceManager = deviceManager
                appDelegate.downloadManager = downloadManager
                appDelegate.uploadManager = uploadManager
            }
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
    private var terminationTask: Task<Void, Never>?
    private var terminationTimer: Timer?
    private var isTerminationInProgress = false
    private var hasRepliedToTermination = false
    weak var deviceManager: DeviceManager?
    weak var downloadManager: DownloadManager?
    weak var uploadManager: UploadManager?
    
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
        // AppKit is already waiting for the cleanup task to call
        // reply(toApplicationShouldTerminate:). Do not start a second cleanup.
        if isTerminationInProgress {
            return .terminateLater
        }

        let shouldShowReminder = UserDefaults.standard.object(forKey: showQuitDebuggingReminderKey) as? Bool ?? true
        if shouldShowReminder {
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

            guard response == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        beginTerminationCleanup(for: sender)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeLocalKeyMonitor()
        terminationTimer?.invalidate()
        terminationTimer = nil
        terminationTask?.cancel()
        terminationTask = nil
    }

    /// ADB can occasionally stop responding after an OS update or device/network
    /// change. Cleanup therefore uses AppKit's asynchronous termination contract and
    /// a short timeout, so Command-Q can never leave a windowless app in the Dock.
    private func beginTerminationCleanup(for application: NSApplication) {
        isTerminationInProgress = true
        // Snapshot actor-isolated ADB state before entering AppKit's modal quit
        // loop. Main-actor Tasks do not run in that loop on macOS 27.
        let adbPath = ADBManager.getADBPath()
        let wirelessTargets = ADBManager.appManagedWirelessCleanupTargets()
        let disconnectAll = UserDefaults.standard.object(forKey: "disconnectAllWirelessOnQuit") as? Bool ?? true
        removeLocalKeyMonitor()
        AppProcessLifecycle.beginTermination()
        deviceManager?.stopMonitoring()
        WirelessDiscovery.shared.stop()
        downloadManager?.cancelAllDownloads()
        uploadManager?.cancelAllUploads()

        let timer = Timer(timeInterval: 4.0, repeats: false) { [weak self, weak application] _ in
            MainActor.assumeIsolated {
                guard let application else { return }
                self?.finishTermination(for: application, timedOut: true)
            }
        }
        terminationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)

        let reply: @Sendable () -> Void = { [weak self, weak application] in
            MainActor.assumeIsolated {
                guard let application else { return }
                self?.finishTermination(for: application)
            }
        }
        terminationTask = Task.detached(priority: .utility) {
            await Self.performADBTerminationCleanup(adbPath: adbPath, wirelessTargets: wirelessTargets,
                                                     disconnectAll: disconnectAll)
            // DispatchQueue.main and MainActor are suspended by the modal quit
            // loop. Schedule the reply in its run-loop mode instead.
            RunLoop.main.perform(inModes: [.common, .modalPanel], block: reply)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func finishTermination(for application: NSApplication, timedOut: Bool = false) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        terminationTimer?.invalidate()
        terminationTimer = nil
        if timedOut { terminationTask?.cancel() }
        AppLogger.log(timedOut ? "⚠️ Quit cleanup exceeded its deadline; allowing application termination."
                              : "👋 Quit cleanup finished; allowing application termination.")
        application.reply(toApplicationShouldTerminate: true)
    }

    nonisolated private static func performADBTerminationCleanup(
        adbPath: String, wirelessTargets: [String: Int], disconnectAll: Bool
    ) async {
        guard !adbPath.isEmpty else { return }

        // App sessions may belong to either daemon; disconnect each on its owning port.
        await withTaskGroup(of: Void.self) { group in
            for (target, port) in wirelessTargets {
                group.addTask {
                    _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect", target], timeoutSeconds: 1.0,
                        environment: Shell.serverEnvironment(port: port), allowDuringTermination: true)
                }
            }
        }
        if disconnectAll {
            _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect"], timeoutSeconds: 1.0,
                environment: Shell.adbEnvironment, allowDuringTermination: true)
        }
        // The private daemon is app-owned even when USB uses Android Studio's server.
        _ = await Shell.runAsyncWithTimeout(adbPath, args: ["kill-server"], timeoutSeconds: 1.0,
            environment: Shell.adbEnvironment, allowDuringTermination: true)
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
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
