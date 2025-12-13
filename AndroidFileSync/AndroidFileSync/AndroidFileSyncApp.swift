
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
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let dropCoordinator = DropCoordinator()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first,
              let contentView = window.contentView else {
            return
        }
        
        // Register for drag-and-drop
        contentView.registerForDraggedTypes([.fileURL])
        
        // Set the coordinator
        (contentView as? NSView)?.window?.registerForDraggedTypes([.fileURL])
    }
}

struct ConnectionBadge: View {
    let type: DeviceManager.ConnectionType
    
    var body: some View {
        HStack(spacing: 4) {
            if type == .adb {
                Image(systemName: "bolt.fill")
                Text("ADB")
                    .font(.caption)
            } else {
                Image(systemName: "xmark.circle")
                Text("Disconnected")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(type == .adb ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
        .cornerRadius(4)
    }
}
