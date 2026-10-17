enum LogLevel {
    case debug, info, warning, error
}

internal import Combine
import Foundation

/// Module-wide print gate for release builds. Keeps existing `print(...)` call sites
/// but silences them unless diagnostics is explicitly enabled.
@inline(__always)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    guard DiagnosticsControl.isEnabled else { return }
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
}

final class DiagnosticsControl: ObservableObject {
    static let shared = DiagnosticsControl()
    static let userDefaultsKey = "diagnosticsControlEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool ?? false
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    private init() {
        self.isEnabled = Self.isEnabled
    }
}

class AppLogger {
    private static let logQueue = DispatchQueue(label: "com.santosh.AndroidFileSync.logQueue")
    private static var cachedLogFileURL: URL?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static var isEnabled: Bool {
        DiagnosticsControl.isEnabled
    }

    static var logFileURL: URL? {
        guard isEnabled else { return nil }
        if let cachedLogFileURL { return cachedLogFileURL }

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = appSupport.appendingPathComponent("AndroidFileSync", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
            let fileURL = appDir.appendingPathComponent("app.log")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            }
            cachedLogFileURL = fileURL
            return fileURL
        } catch {
            return nil
        }
    }

    /// Adds a session separator to the log file and rotates if needed.
    static func addSessionSeparator() {
        guard isEnabled else { return }
        logQueue.async {
            guard let url = logFileURL else { return }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? UInt64,
               fileSize > 1_048_576 {
                if let data = try? Data(contentsOf: url) {
                    let keepBytes = 512_000
                    let startOffset = max(0, data.count - keepBytes)
                    let trimmedData = data[startOffset...]
                    if let newlineIdx = trimmedData.firstIndex(of: UInt8(ascii: "\n")) {
                        let cleanData = trimmedData[(trimmedData.index(after: newlineIdx))...]
                        try? cleanData.write(to: url)
                    } else {
                        try? trimmedData.write(to: url)
                    }
                }
            }

            let ts = timestampFormatter.string(from: Date())
            let separator = "\n\n" + String(repeating: "═", count: 72) + "\n"
                + "  NEW SESSION — \(ts)\n"
                + String(repeating: "═", count: 72) + "\n\n"

            if let data = separator.data(using: .utf8),
               let fileHandle = try? FileHandle(forWritingTo: url) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            }
        }
    }

    static func log(_ message: @autoclosure () -> String, level: LogLevel = .info) {
        guard isEnabled else { return }

        let prefix: String
        switch level {
        case .debug: prefix = "🔍"
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        }

        let ts = timestampFormatter.string(from: Date())
        let logString = "[\(ts)] \(prefix) \(message())"
        print(logString)

        logQueue.async {
            guard let url = logFileURL else { return }
            let line = logString + "\n"
            if let data = line.data(using: .utf8),
               let fileHandle = try? FileHandle(forWritingTo: url) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            }
        }
    }
}
