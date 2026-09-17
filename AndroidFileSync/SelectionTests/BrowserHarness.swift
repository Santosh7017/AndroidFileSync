import AppKit
import SwiftUI
@testable import AndroidFileSync

@MainActor
final class BrowserFixture: ObservableObject {
    @Published var selection: Set<String> = []
    var openedFolders: [String] = []
    let files = (0..<30).map {
        UnifiedFile(name: String(format: "%02d %@", $0, $0.isMultiple(of: 2) ? "Folder" : "File.txt"),
                    path: "/fixture/\($0)", isDirectory: $0.isMultiple(of: 2), size: 12)
    }
}

struct BrowserFixtureView: View {
    @ObservedObject var fixture: BrowserFixture
    var body: some View {
        FileBrowserView(
            files: fixture.files, currentPath: "/fixture", isLoading: false, canGoBack: false,
            selectedFiles: $fixture.selection, onNavigate: { fixture.openedFolders.append($0) }, onGoBack: {},
            onDownload: { _ in }, onUpload: { _ in }, onDelete: nil, onRename: nil,
            onBatchDelete: nil, onBatchDownload: nil, onBatchChangeExtension: nil
        )
    }
}

@main
struct BrowserTestApp: App {
    @NSApplicationDelegateAdaptor(FixtureDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

enum BrowserIntegrationTests {
    @MainActor
    static func runTests() async throws {
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer { previousApp?.activate(options: []) }
        let suiteName = "afs-browser-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(CommandLine.arguments.contains("tiles") ? "tiles" : "list", forKey: "fileBrowserViewMode")
        let fixture = BrowserFixture()
        let host = NSHostingView(rootView: BrowserFixtureView(fixture: fixture).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 650, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false, screen: NSScreen.main)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func settle() async {
            try? await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        await settle()
        window.makeKey()
        func fail(_ message: String) {
            let report: [String: Any] = ["error": message, "views": descendants(host).map {
                "\(type(of: $0)) \($0.frame)"
            }]
            try! JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "SelectionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let table = descendants(host).compactMap { $0 as? NSTableView }.first
        guard let keyboard = descendants(host).compactMap({ $0 as? FileBrowserKeyboardNavigation.KeyboardView }).first
        else { fail("Keyboard view was not laid out"); return }
        let stride = table == nil ? keyboard.itemFrames.values.filter {
            abs($0.minY - (keyboard.itemFrames.values.map(\.minY).min() ?? 0)) < 1
        }.count : 1
        try require(stride > 0, "Tile geometry did not reach the input handler")
        let point: NSPoint
        if let table {
            point = table.convert(NSPoint(x: 70, y: table.rect(ofRow: 3).midY), to: nil)
        } else {
            guard let frame = keyboard.itemFrames[3] else {
                fail("Tile frames are missing: \(keyboard.itemFrames)")
                return
            }
            point = keyboard.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            // Post through AppKit's queue so installed monitors and native event
            // dispatch are exercised, rather than calling the handler directly.
            NSApp.postEvent(event, atStart: false)
        }
        mouse(.leftMouseDown, point)
        mouse(.leftMouseUp, point)
        await settle()
        var selections = [fixture.selection.sorted()]
        try require(fixture.selection == [fixture.files[3].id], "Click did not select the clicked item")
        for step in 1...3 {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
                charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
            NSApp.postEvent(event, atStart: true)
            await settle()
            selections.append(fixture.selection.sorted())
            try require(fixture.selection == Set(fixture.files[3...(3 + stride * step)].map(\.id)),
                        "Repeated Shift + Down failed at step \(step): \(fixture.selection.sorted())")
        }
        let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f700}",
            charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126)!
        NSApp.postEvent(up, atStart: true)
        await settle()
        try require(fixture.selection == Set(fixture.files[3...(3 + stride * 2)].map(\.id)),
                    "Shift + Up did not shrink the selected range")

        fixture.selection = []
        await settle()
        if let table { table.scrollRowToVisible(0) }
        else if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await settle()
        func itemPoint(_ index: Int) -> NSPoint {
            if let table {
                return table.convert(NSPoint(x: 90, y: table.rect(ofRow: index).midY), to: nil)
            }
            let frame = keyboard.itemFrames[index]!
            return keyboard.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        }
        let startIndex = table == nil ? stride + 1 : 3
        let endIndex = table == nil ? stride * 2 + 3 : 6
        mouse(.leftMouseDown, itemPoint(startIndex))
        await settle()
        mouse(.leftMouseDragged, itemPoint(endIndex))
        await settle()
        let expanded = table == nil
            ? Set([stride + 1, stride + 2, stride + 3, stride * 2 + 1, stride * 2 + 2, stride * 2 + 3])
            : Set(3...6)
        try require(fixture.selection == Set(expanded.map { fixture.files[$0].id }),
                    "Drag selected the wrong group: \(fixture.selection.sorted())")
        mouse(.leftMouseDragged, itemPoint(table == nil ? 0 : 2))
        await settle()
        let reversed = table == nil ? Set([0, 1, stride, stride + 1]) : Set([2, 3])
        try require(fixture.selection == Set(reversed.map { fixture.files[$0].id }),
                    "Reversing the drag retained items outside the rectangle: \(fixture.selection.sorted())")
        mouse(.leftMouseUp, itemPoint(table == nil ? 0 : 2))
        await settle()
        let folderPoint = itemPoint(2)
        mouse(.leftMouseDown, folderPoint)
        mouse(.leftMouseUp, folderPoint)
        await settle()
        mouse(.leftMouseDown, folderPoint, clicks: 2)
        await settle()
        try require(fixture.openedFolders.isEmpty, "Folder opened before detecting whether the second click was a drag")
        let draggedPoint = NSPoint(x: folderPoint.x + 8, y: folderPoint.y - 5)
        mouse(.leftMouseDragged, draggedPoint, clicks: 2)
        await settle()
        mouse(.leftMouseUp, draggedPoint, clicks: 2)
        await settle()
        try require(fixture.openedFolders.isEmpty, "Selecting a folder then dragging a little opened it")
        mouse(.leftMouseDown, folderPoint, clicks: 2)
        await settle()
        try require(fixture.openedFolders.isEmpty, "Double-click opened before mouse release")
        mouse(.leftMouseUp, folderPoint, clicks: 2)
        await settle()
        try require(fixture.openedFolders == [fixture.files[2].path], "Completed double-click did not open the folder exactly once")
        let report: [String: Any] = ["selections": selections, "bounds": String(describing: keyboard.bounds),
                                    "responder": String(describing: window.firstResponder),
                                    "keyWindow": window.isKeyWindow, "passed": true]
        try! JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
        window.close()
        print("PASS: rendered browser events")
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var completed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await BrowserIntegrationTests.runTests() }
            catch {
                let report = ["error": error.localizedDescription]
                try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
            }
            completed = true
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        completed ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
