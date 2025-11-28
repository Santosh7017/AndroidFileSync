import Foundation
import SwiftUI
internal import Combine
class AppSettings: ObservableObject {
    @AppStorage("defaultDownloadPath") var defaultDownloadPath: String = ""
    @AppStorage("showHiddenFiles") var showHiddenFiles: Bool = false
    @AppStorage("autoRefreshInterval") var autoRefreshInterval: Double = 0
    @AppStorage("transferBufferSize") var transferBufferSize: Int = 8192
}
