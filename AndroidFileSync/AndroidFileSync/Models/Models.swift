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
    
    // MARK: - Sortable Properties for Table
    var sortableDate: Date {
        modificationDate ?? Date.distantPast
    }
    
    // Groups files by media category for Type sort: Folders → Images → Videos → Audio → Docs → Other
    var sortableType: String {
        if isDirectory { return "0_Folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff":
            return "1_Image_" + ext
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv":
            return "2_Video_" + ext
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            return "3_Audio_" + ext
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md":
            return "4_Document_" + ext
        case "zip", "rar", "7z", "tar", "gz":
            return "5_Archive_" + ext
        case "apk":
            return "6_App_" + ext
        default:
            return "7_Other_" + ext
        }
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

