////
////  DeviceManager.swift
////  AndroidFileSync
////
////  Manages device detection and file operations across ADB and MTP
////
//
//import Foundation
//internal import Combine
//
//@MainActor
//class DeviceManager: ObservableObject {
//    
//    // MARK: - Published Properties
//    
//    @Published var isConnected = false
//    @Published var connectionType: ConnectionType = .none
//    @Published var deviceName = "No Device"
//    @Published var statusMessage = "Waiting for device..."
//    
//    // MARK: - Private Properties
//    
//    private var mtpDevice: MTPManager?
//    private var adbAvailable = false
//    
//    // MARK: - Connection Type
//    
//    enum ConnectionType {
//        case none
//        case mtp
//        case adb
//        case both  // Best scenario - Turbo mode!
//    }
//    
//    // MARK: - Device Detection
//    
//    func detectDevice() async {
//        print("\n🔍 Scanning for Android devices...")
//        
//        // Check ADB
//        print("🔍 Checking ADB connection...")
//        adbAvailable = await ADBManager.isDeviceConnected()
//        print("📱 ADB available: \(adbAvailable)")
//        
//        if adbAvailable {
//            if let serial = await ADBManager.getDeviceSerial() {
//                print("✅ ADB device found: \(serial)")
//            }
//        }
//        
//        // Check MTP
//        print("🔍 Checking MTP connection...")
//        mtpDevice = MTPManager()
//        print("📱 MTP device: \(mtpDevice != nil)")
//        
//        await MainActor.run {
//            if adbAvailable && mtpDevice != nil {
//                connectionType = .both
//                deviceName = mtpDevice?.deviceName ?? "Android Device"
//                isConnected = true
//                statusMessage = "✅ Connected (ADB + MTP)"
//                print("🚀 Using BOTH ADB and MTP!")
//            } else if adbAvailable {
//                connectionType = .adb
//                isConnected = true
//                deviceName = "Android Device"
//                statusMessage = "✅ Connected via ADB"
//                print("⚡ Using ADB only")
//            } else if mtpDevice != nil {
//                connectionType = .mtp
//                deviceName = mtpDevice?.deviceName ?? "Android Device"
//                isConnected = true
//                statusMessage = "✅ Connected (MTP only)"
//                print("📁 Using MTP only")
//            } else {
//                connectionType = .none
//                isConnected = false
//                deviceName = "No Device"
//                statusMessage = "❌ No device found"
//                print("❌ No device detected")
//            }
//        }
//    }
//    
//    // MARK: - File Listing
//    
//    func listFiles(path: String = "/sdcard") async throws -> [UnifiedFile] {
//        switch connectionType {
//        case .both, .adb:
//            // Use ADB (faster and more reliable)
//            let adbFiles = try await ADBManager.listFiles(path: path)
//            return adbFiles.map { UnifiedFile(from: $0) }
//            
//        case .mtp:
//            // Use MTP
//            guard let device = mtpDevice else {
//                throw NSError(domain: "DeviceManager", code: -1,
//                            userInfo: [NSLocalizedDescriptionKey: "No MTP device"])
//            }
//            let mtpFiles = device.listFiles()  // Use default parameters
//            return mtpFiles.map { UnifiedFile(from: $0) }
//            
//        case .none:
//            throw NSError(domain: "DeviceManager", code: -1,
//                        userInfo: [NSLocalizedDescriptionKey: "No device connected"])
//        }
//    }
//    
//    // MARK: - Storage Path
//    
//    func getRealStoragePath() async -> String {
//        let possiblePaths = [
//            "/storage/emulated/0",
//            "/storage/self/primary",
//            "/sdcard"
//        ]
//        
//        for path in possiblePaths {
//            do {
//                let files = try await ADBManager.listFiles(path: path)
//                if !files.isEmpty {
//                    print("✅ Using storage path: \(path)")
//                    return path
//                }
//            } catch {
//                continue
//            }
//        }
//        
//        return "/sdcard"
//    }
//    
//    // MARK: - Download
//    
//    func downloadFile(
//        file: UnifiedFile,
//        to localPath: String,
//        progress: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        guard connectionType == .both || connectionType == .adb else {
//            if connectionType == .mtp {
//                print("⚠️ MTP download not yet fully implemented with progress")
//                // Could implement MTP download here
//                return
//            }
//            throw NSError(domain: "DeviceManager", code: -1,
//                        userInfo: [NSLocalizedDescriptionKey: "ADB required for download"])
//        }
//        
//        print("📥 Starting download: \(file.name)")
//        
//        try await ADBManager.pullFileWithProgress(
//            devicePath: file.path,
//            localPath: localPath,
//            progressCallback: progress
//        )
//        
//        print("✅ Downloaded to: \(localPath)")
//    }
//    
//    // MARK: - Upload
//    
//    func uploadFile(
//        localPath: String,
//        toDirectory: String,
//        fileName: String,
//        progress: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        guard connectionType == .both || connectionType == .adb else {
//            if connectionType == .mtp {
//                print("⚠️ MTP upload not yet fully implemented with progress")
//                return
//            }
//            throw NSError(domain: "DeviceManager", code: -1,
//                        userInfo: [NSLocalizedDescriptionKey: "ADB required for upload"])
//        }
//        
//        let devicePath = toDirectory.hasSuffix("/") ?
//            toDirectory + fileName :
//            toDirectory + "/" + fileName
//        
//        print("📤 Starting upload: \(fileName)")
//        
//        try await ADBManager.pushFileWithProgress(
//            localPath: localPath,
//            devicePath: devicePath,
//            progressCallback: progress
//        )
//        
//        print("✅ Uploaded to: \(devicePath)")
//    }
//    
//    // MARK: - Bulk Operations
//    
//    func downloadDirectory(remotePath: String, localPath: String) async throws {
//        guard connectionType == .both || connectionType == .adb else {
//            throw NSError(domain: "DeviceManager", code: -1,
//                        userInfo: [NSLocalizedDescriptionKey: "ADB required for directory transfer"])
//        }
//        
//        print("🚀 Turbo directory mode: Using tar-over-ADB")
//        
//        try FileManager.default.createDirectory(
//            atPath: localPath,
//            withIntermediateDirectories: true
//        )
//        
//        let command = "cd '\(remotePath)' && tar -cf - . | cat"
//        let (code, _, error) = Shell.run(
//            "adb",
//            args: ["shell", command]
//        )
//        
//        guard code == 0 else {
//            throw NSError(domain: "ADB", code: Int(code),
//                        userInfo: [NSLocalizedDescriptionKey: error])
//        }
//        
//        print("✅ Directory transferred successfully")
//    }
//    
//    // MARK: - Cleanup
//    
//    func disconnect() {
//        mtpDevice = nil
//        adbAvailable = false
//        isConnected = false
//        connectionType = .none
//        statusMessage = "Disconnected"
//    }
//}
//
//
//


//
//  DeviceManager.swift
//  (DEFINITIVE DETECTION FIX)
//

import Foundation
internal import Combine

@MainActor
class DeviceManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isConnected = false
    @Published var isDetecting = true // Start in "detecting" state
    @Published var connectionType: ConnectionType = .none
    @Published var deviceName = "No Device"
    @Published var statusMessage = "Scanning for devices..."
    
    private var mtpDevice: MTPManager?
    private var adbAvailable = false
    
    enum ConnectionType: String {
        case none = "None"
        case mtp = "MTP"
        case adb = "ADB"
        case both = "Turbo (ADB + MTP)"
    }
    
    // MARK: - Core Logic
    
    func detectDevice() async {
        print("🕵️‍♂️ Starting device detection...")
        
        // Ensure UI shows "detecting" state
        if !isDetecting {
            await MainActor.run { self.isDetecting = true }
        }
        
        // Check for ADB devices
        adbAvailable = await ADBManager.isDeviceConnected()
        print("🕵️‍♂️ ADB check complete. Device found: \(adbAvailable)")
        
        // Check for MTP devices (this has a failable initializer)
        mtpDevice = MTPManager()
        print("🕵️‍♂️ MTP check complete. Device found: \(mtpDevice != nil)")
        
        // Update the state on the main thread
        await MainActor.run {
            if adbAvailable && mtpDevice != nil {
                self.connectionType = .both
                self.deviceName = mtpDevice?.deviceName ?? "Android Device"
                self.statusMessage = "Connected via \(self.connectionType.rawValue)"
                self.isConnected = true
            } else if adbAvailable {
                self.connectionType = .adb
                self.deviceName = "Android Device (ADB)"
                self.statusMessage = "Connected via ADB"
                self.isConnected = true
            } else if mtpDevice != nil {
                self.connectionType = .mtp
                self.deviceName = mtpDevice?.deviceName ?? "MTP Device"
                self.statusMessage = "Connected via MTP"
                self.isConnected = true
            } else {
                self.connectionType = .none
                self.deviceName = "No Device"
                self.statusMessage = "No device detected. Please connect your device."
                self.isConnected = false
            }
            
            // Detection is complete, hide the initial loading screen
            self.isDetecting = false
            print("🕵️‍♂️ Detection finished. Final state: isConnected = \(self.isConnected)")
        }
    }
    
    // Inside DeviceManager

    func listFiles(path: String = "/sdcard") async throws -> [UnifiedFile] {
        switch connectionType {
        case .both, .adb:
            let adbFiles = try await ADBManager.listFiles(path: path)
            return adbFiles.map { UnifiedFile(from: $0) }

        case .mtp:
            guard let device = mtpDevice else {
                throw NSError(
                    domain: "DeviceManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No MTP device"]
                )
            }
            let mtpFiles = device.getRootItems()
            return mtpFiles.map { UnifiedFile(from: $0) }

        case .none:
            throw NSError(
                domain: "DeviceManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No device connected"]
            )
        }
    }

    
    func getRealStoragePath() async -> String {
        // ... This function should remain as it was ...
        return "/storage/emulated/0" // Default fallback
    }
}
