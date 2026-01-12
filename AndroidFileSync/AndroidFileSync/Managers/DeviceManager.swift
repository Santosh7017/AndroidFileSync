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
    
    private var adbAvailable = false
    
    enum ConnectionType: String {
        case none = "None"
        case adb = "ADB"
    }
    
    // MARK: - Core Logic
    
    func detectDevice() async {
        
        // Ensure UI shows "detecting" state
        if !isDetecting {
            await MainActor.run { self.isDetecting = true }
        }
        
        // Check for ADB devices
        adbAvailable = await ADBManager.isDeviceConnected()
        
        // Update the state on the main thread
        await MainActor.run {
            if adbAvailable {
                self.connectionType = .adb
                self.deviceName = "Android Device"
                self.statusMessage = "Connected via ADB"
                self.isConnected = true
            } else {
                self.connectionType = .none
                self.deviceName = "No Device"
                self.statusMessage = "No device detected. Please connect your device."
                self.isConnected = false
            }
            
            // Detection is complete, hide the initial loading screen
            self.isDetecting = false
        }
    }
    
    func listFiles(path: String = "/sdcard") async throws -> [UnifiedFile] {
        guard adbAvailable else {
            throw NSError(
                domain: "DeviceManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No device connected"]
            )
        }
        
        let adbFiles = try await ADBManager.listFiles(path: path)
        return adbFiles.map { UnifiedFile(from: $0) }
    }
    
    func getRealStoragePath() async -> String {
        return "/storage/emulated/0" // Default fallback
    }
}

