//
//  Models.swift
//  AndroidFileSync
//
//  Shared models and protocols
//

import Foundation
import AppKit 

// MARK: - Transfer Progress Protocol

protocol TransferProgressProtocol: Identifiable {
    var fileName: String { get }
    var bytesTransferred: UInt64 { get }
    var totalBytes: UInt64 { get }
    var progress: Double { get }
    var progressPercentage: Int { get }
    var speedText: String { get }
    var isComplete: Bool { get }
    var error: String? { get }
}

// MARK: - Unified File Model
//

struct UnifiedFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
    
    // Direct initializer
    init(name: String, path: String, isDirectory: Bool, size: UInt64, modificationDate: Date? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }
    
    init(from adbFile: ADBFile) {
        self.name = adbFile.name
        self.path = adbFile.path
        self.isDirectory = adbFile.isDirectory
        self.size = adbFile.size
        self.modificationDate = adbFile.modificationDate
    }
}


// MARK: - Helper Functions
func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}
extension NSSavePanel {
    // This single extension will work for both NSSavePanel and its subclass NSOpenPanel
    func configureForPerformance() {
        self.showsHiddenFiles = false
        self.treatsFilePackagesAsDirectories = false
        self.accessoryView = nil // Disabling previews is a major performance win
        
        if let openPanel = self as? NSOpenPanel {
            // Settings specific to opening files
            openPanel.canChooseDirectories = false
            openPanel.canChooseFiles = true
            openPanel.allowsMultipleSelection = true
            openPanel.canCreateDirectories = false
        } else {
            // Settings specific to saving files
            self.canCreateDirectories = true
        }
    }
}

struct ADBFile {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}

