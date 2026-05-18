
import SwiftUI

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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
