enum LogLevel {
    case debug, info, warning, error
}

class AppLogger {
    static func log(_ message: String, level: LogLevel = .info) {
        let prefix: String
        switch level {
        case .debug: prefix = "🔍"
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        }
        print("\(prefix) \(message)")
    }
}
