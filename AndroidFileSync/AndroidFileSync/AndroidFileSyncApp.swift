

import SwiftUI

@main
struct AndroidFileSyncApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
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
            if type == .both {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                Text("Turbo")
                    .font(.caption.bold())
            } else if type == .adb {
                Image(systemName: "bolt.fill")
                Text("ADB")
                    .font(.caption)
            } else {
                Image(systemName: "folder.fill")
                Text("MTP")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(type == .both ? Color.yellow.opacity(0.2) : Color.blue.opacity(0.2))
        .cornerRadius(4)
    }
}
