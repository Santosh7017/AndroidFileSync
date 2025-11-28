//
//  DropCoordinator.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import AppKit
import UniformTypeIdentifiers

class DropCoordinator: NSObject, NSDraggingDestination {
    
    var onFilesDropped: (([URL]) -> Void)?
    
    // MARK: - NSDraggingDestination Methods
    
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Show the "copy" cursor
        return .copy
    }
    
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Handle the dropped files
        let pasteboard = sender.draggingPasteboard
        
        guard let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty else {
            return false
        }
        
        // Pass URLs back to ContentView
        onFilesDropped?(fileURLs)
        
        return true
    }
}
