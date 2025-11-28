//
//  MTPManager.swift
//  AndroidFileSync
//
//  Manages MTP (Media Transfer Protocol) device operations
//

import Foundation

// MARK: - MTP Error Types

enum MTPError: LocalizedError {
    case noDeviceFound
    case deviceOpenFailed
    case operationTimeout
    case transferFailed(String)
    case invalidPath
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .noDeviceFound: return "No MTP device found"
        case .deviceOpenFailed: return "Failed to open MTP device"
        case .operationTimeout: return "Operation timed out"
        case .transferFailed(let reason): return "Transfer failed: \(reason)"
        case .invalidPath: return "Invalid file path"
        case .fileNotFound: return "File not found on device"
        }
    }
}

// MARK: - MTP Manager

class MTPManager {
    
    // MARK: - Properties
    
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private(set) var deviceName: String = "Unknown Device"
    private(set) var manufacturer: String = ""
    private(set) var model: String = ""
    private var cachedStorages: [UInt32] = []
    
    // MARK: - Initialization
    
    init?() {
        LIBMTP_Init()
        
        guard let openedDevice = openDevice() else {
            return nil
        }
        
        self.device = openedDevice
        loadDeviceInfo()
        cacheStorages()
        
        print("✅ MTP Connected: \(deviceName)")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Device Detection
    
    static func isDeviceAvailable() -> Bool {
        LIBMTP_Init()
        
        var deviceList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var numDevices: Int32 = 0
        
        defer {
            if deviceList != nil {
                free(deviceList)
            }
        }
        
        let result = LIBMTP_Detect_Raw_Devices(&deviceList, &numDevices)
        return result == LIBMTP_ERROR_NONE && numDevices > 0
    }
    
    // MARK: - File Operations
    
    /// Lists files at root level or in a specific folder
    func listFiles(parentID: UInt32 = 0, storageID: UInt32 = 0) -> [MTPFile] {
        guard device != nil else { return [] }
        
        let storage = storageID == 0 ? cachedStorages.first ?? 0 : storageID
        
        if parentID == 0 {
            return getRootItems(storageID: storage)
        } else {
            return getChildrenOf(folderID: parentID, storageID: storage)
        }
    }
    
    /// Downloads a file from device to Mac
    func downloadFile(fileID: UInt32, to localPath: String) async throws {
        guard let device = device else {
            throw MTPError.deviceOpenFailed
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = LIBMTP_Get_File_To_File(device, fileID, localPath, nil, nil)
                
                if result == 0 {
                    print("✅ Downloaded file ID \(fileID)")
                    continuation.resume()
                } else {
                    print("❌ Failed to download file ID \(fileID)")
                    continuation.resume(throwing: MTPError.transferFailed("Download error code: \(result)"))
                }
            }
        }
    }
    
    /// Uploads a file from Mac to device
    func uploadFile(from localPath: String, to parentID: UInt32) async throws -> UInt32 {
        guard let device = device else {
            throw MTPError.deviceOpenFailed
        }
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localPath) else {
            throw MTPError.fileNotFound
        }
        
        guard let attrs = try? fileManager.attributesOfItem(atPath: localPath),
              let fileSize = attrs[.size] as? UInt64 else {
            throw MTPError.transferFailed("Cannot read file size")
        }
        
        let fileName = (localPath as NSString).lastPathComponent
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var fileMetadata = LIBMTP_file_t()
                fileMetadata.parent_id = parentID
                fileMetadata.storage_id = self.cachedStorages.first ?? 0
                fileMetadata.filesize = fileSize
                fileMetadata.filename = strdup(fileName)
                fileMetadata.filetype = self.detectFileType(fileName: fileName)
                
                defer {
                    if let filename = fileMetadata.filename {
                        free(UnsafeMutableRawPointer(mutating: filename))
                    }
                }
                
                let result = LIBMTP_Send_File_From_File(device, localPath, &fileMetadata, nil, nil)
                
                if result == 0 {
                    print("✅ Uploaded \(fileName)")
                    continuation.resume(returning: fileMetadata.item_id)
                } else {
                    print("❌ Failed to upload \(fileName)")
                    continuation.resume(throwing: MTPError.transferFailed("Upload error code: \(result)"))
                }
            }
        }
    }
    
    // MARK: - Storage Operations
    
    func getStorages() -> [UInt32] {
        return cachedStorages
    }
    
    func getStorageInfo(storageID: UInt32) -> (freeSpace: UInt64, capacity: UInt64)? {
        guard let device = device else { return nil }
        
        var storagePtr = device.pointee.storage
        while storagePtr != nil {
            if let storage = storagePtr?.pointee, storage.id == storageID {
                return (storage.FreeSpaceInBytes, storage.MaxCapacity)
            }
            storagePtr = storagePtr?.pointee.next
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func openDevice() -> UnsafeMutablePointer<LIBMTP_mtpdevice_t>? {
        var deviceList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var numDevices: Int32 = 0
        
        defer {
            if deviceList != nil {
                free(deviceList)
            }
        }
        
        let result = LIBMTP_Detect_Raw_Devices(&deviceList, &numDevices)
        
        guard result == LIBMTP_ERROR_NONE,
              numDevices > 0,
              let devices = deviceList else {
            print("❌ No MTP device found")
            return nil
        }
        
        print("📱 Found \(numDevices) MTP device(s)")
        
        return LIBMTP_Open_Raw_Device_Uncached(&devices.pointee)
    }
    
    private func loadDeviceInfo() {
        guard let device = device else { return }
        
        // Device name
        if let namePtr = LIBMTP_Get_Friendlyname(device) {
            deviceName = String(cString: namePtr)
            free(namePtr)
        }
        
        // Manufacturer
        if let mfgPtr = LIBMTP_Get_Manufacturername(device) {
            manufacturer = String(cString: mfgPtr)
            print("📱 Manufacturer: \(manufacturer)")
            free(mfgPtr)
        }
        
        // Model
        if let modelPtr = LIBMTP_Get_Modelname(device) {
            model = String(cString: modelPtr)
            print("📱 Model: \(model)")
            free(modelPtr)
        }
    }
    
    private func cacheStorages() {
        guard let device = device else { return }
        
        var storageIDs: [UInt32] = []
        var storagePtr = device.pointee.storage
        
        while storagePtr != nil {
            if let storage = storagePtr?.pointee {
                storageIDs.append(storage.id)
                print("💾 Storage ID: \(storage.id)")
            }
            storagePtr = storagePtr?.pointee.next
        }
        
        cachedStorages = storageIDs.isEmpty ? [0] : storageIDs
    }
    
    private func getSimpleFileListing(storageID: UInt32) -> [MTPFile] {
        guard let device = device else { return [] }
        
        print("🔄 Getting file listing from storage \(storageID)...")
        
        var files: [MTPFile] = []
        var fileList = LIBMTP_Get_Filelisting_With_Callback(device, nil, nil)
        
        defer {
            // Free the file list to prevent memory leak
            if fileList != nil {
                LIBMTP_destroy_file_t(fileList)
            }
        }
        
        while fileList != nil {
            if let file = fileList?.pointee {
                files.append(MTPFile(from: file))
            }
            fileList = fileList?.pointee.next
        }
        
        print("📦 Total files found: \(files.count)")
        return files
    }
    
     func getRootItems(storageID: UInt32=0) -> [MTPFile] {
        let allFiles = getSimpleFileListing(storageID: storageID)
        
        let parentIDs = allFiles.map { $0.parentID }
        let minParentID = parentIDs.min() ?? 0
        
        let rootItems = allFiles.filter { $0.parentID == minParentID }
        
        print("📁 Root items: \(rootItems.count)")
        return rootItems
    }
    
    private func getChildrenOf(folderID: UInt32, storageID: UInt32=0) -> [MTPFile] {
        let allFiles = getSimpleFileListing(storageID: storageID)
        let children = allFiles.filter { $0.parentID == folderID }
        
        print("📁 Children of folder \(folderID): \(children.count)")
        return children
    }
    
    private func detectFileType(fileName: String) -> LIBMTP_filetype_t {
        let ext = (fileName as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg": return LIBMTP_FILETYPE_JPEG
        case "png": return LIBMTP_FILETYPE_PNG
        case "mp3": return LIBMTP_FILETYPE_MP3
        case "mp4": return LIBMTP_FILETYPE_MP4
        case "pdf": return LIBMTP_FILETYPE_UNKNOWN
        case "txt": return LIBMTP_FILETYPE_TEXT
        default: return LIBMTP_FILETYPE_UNKNOWN
        }
    }
    
    private func cleanup() {
        if let device = device {
            LIBMTP_Release_Device(device)
            print("🔌 Disconnected from MTP device")
        }
        device = nil
    }
}

// MARK: - MTP File Model

struct MTPFile: Identifiable {
    let id: UInt32
    let parentID: UInt32
    let name: String
    let size: UInt64
    let isFolder: Bool
    let modificationDate: Date
    let storageID: UInt32
    
    init(from mtpFile: LIBMTP_file_struct) {
        self.id = mtpFile.item_id
        self.parentID = mtpFile.parent_id
        self.storageID = mtpFile.storage_id
        
        if let filenamePtr = mtpFile.filename {
            self.name = String(cString: filenamePtr)
        } else {
            self.name = "Unnamed"
        }
        
        self.size = mtpFile.filesize
        self.isFolder = mtpFile.filetype == LIBMTP_FILETYPE_FOLDER
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(mtpFile.modificationdate))
    }
}
