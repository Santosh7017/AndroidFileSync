import Foundation
import AppKit

struct QuickAccessItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let path: String
    let color: String
    
    static let commonFolders: [QuickAccessItem] = [
        QuickAccessItem(name: "Internal Storage", icon: "internaldrive.fill", path: "/storage/emulated/0", color: "blue"),
        QuickAccessItem(name: "Camera", icon: "camera.fill", path: "/storage/emulated/0/DCIM", color: "purple"),
//        QuickAccessItem(name: "Screenshots", icon: "camera.viewfinder", path: "/storage/emulated/0/DCIM/Screenshots", color: "orange"),
        QuickAccessItem(name: "Downloads", icon: "arrow.down.circle.fill", path: "/storage/emulated/0/Download", color: "green"),
        QuickAccessItem(name: "Pictures", icon: "photo.fill", path: "/storage/emulated/0/Pictures", color: "pink"),
        QuickAccessItem(name: "Music", icon: "music.note", path: "/storage/emulated/0/Music", color: "red"),
        QuickAccessItem(name: "Movies", icon: "film.fill", path: "/storage/emulated/0/Movies", color: "cyan"),
        QuickAccessItem(name: "Documents", icon: "doc.fill", path: "/storage/emulated/0/Documents", color: "yellow"),
//        QuickAccessItem(name: "WhatsApp", icon: "bubble.left.and.bubble.right.fill", path: "/storage/emulated/0/WhatsApp", color: "green"),
//        QuickAccessItem(name: "Bluetooth", icon: "bluetooth", path: "/storage/emulated/0/bluetooth", color: "blue")
    ]
}

extension String {
    var color: NSColor {
        switch self {
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "pink": return .systemPink
        case "red": return .systemRed
        case "cyan": return .systemCyan
        case "yellow": return .systemYellow
        default: return .systemGray
        }
    }
}
