import Foundation
import SwiftUI
internal import Combine
class AppSettings: ObservableObject {
    @AppStorage("defaultDownloadPath") var defaultDownloadPath: String = ""
    @AppStorage("showHiddenFiles") var showHiddenFiles: Bool = false
    @AppStorage("autoRefreshInterval") var autoRefreshInterval: Double = 0
    @AppStorage("transferBufferSize") var transferBufferSize: Int = 8192
    /// If true, app quits by disconnecting all wireless adb sessions.
    /// Turn this off for users who share a single adb server with other apps.
    @AppStorage("disconnectAllWirelessOnQuit") var disconnectAllWirelessOnQuit: Bool = true
}
