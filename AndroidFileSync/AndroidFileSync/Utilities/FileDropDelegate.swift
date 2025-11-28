import SwiftUI
import UniformTypeIdentifiers

struct FileDropDelegate: DropDelegate {
    let currentPath: String
    let onFilesDropped: ([URL]) -> Void
    
    func validateDrop(info: DropInfo) -> Bool {
        // Check if the drop contains file URLs
        return info.hasItemsConforming(to: [.fileURL])
    }
    
    func performDrop(info: DropInfo) -> Bool {
        let items = info.itemProviders(for: [.fileURL])
        
        for item in items {
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (urlData, error) in
                if let urlData = urlData as? Data,
                   let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                    DispatchQueue.main.async {
                        onFilesDropped([url])
                    }
                }
            }
        }
        
        return true
    }
    
    func dropEntered(info: DropInfo) {
        // Visual feedback when drag enters
    }
    
    func dropExited(info: DropInfo) {
        // Visual feedback when drag exits
    }
}
