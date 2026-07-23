import Foundation

// MARK: - Transfer Concurrency Constants
// Change these values in ONE place to affect both DownloadManager and UploadManager.

/// Maximum concurrent transfers for wireless (WiFi/ADB over TCP) connections.
/// WiFi ADB is TCP-based and fragile at high concurrency — keep this conservative.
let kWirelessMaxConcurrent = 7

/// Maximum concurrent transfers for wired (USB) connections.
/// USB handles high concurrency well via direct physical link.
let kWiredMaxConcurrent = 12

/// Wireless solo cap when the app is busy with file operations (copy/move/delete).
/// Reduced to avoid bus contention between transfer and file-management ADB commands.
let kWirelessSoloBusyCap = 5

/// Wireless dual-direction cap per side (half of total WiFi budget).
let kWirelessDualCap = 4

/// Wireless dual-direction cap per side when the app is busy.
let kWirelessDualBusyCap = 3

/// Wired dual-direction cap per side (half of total USB budget).
let kWiredDualCap = 6

/// Wired dual-direction cap per side when the app is busy.
let kWiredDualBusyCap = 5

/// Wired solo cap when the app is busy.
let kWiredSoloBusyCap = 10

/// WiFi stagger delay (nanoseconds) between dispatching consecutive ADB processes.
/// Gives ADB's TCP transport time to stabilize each new wireless connection.
let kWiFiStaggerDelayNs: UInt64 = 200_000_000 // 200ms

/// Delay (nanoseconds) after a connection error before retrying.
let kConnectionRetryDelayNs: UInt64 = 500_000_000 // 500ms

/// Delay (nanoseconds) for the offline-wait loop before re-checking connection.
let kOfflineCheckIntervalNs: UInt64 = 1_000_000_000 // 1 second

/// Post-reconnection stabilization delay (nanoseconds).
/// After WiFi reconnects, ADB needs a brief cooldown before new transfers are reliable.
let kReconnectStabilizationDelayNs: UInt64 = 1_500_000_000 // 1.5 seconds
