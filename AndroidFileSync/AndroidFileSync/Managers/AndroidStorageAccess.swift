import Foundation

/// All commands are supplied by a runner pinned to one device and ADB server.
/// Keep recovery separate from the UI so firmware failures can be exercised without a phone.
nonisolated struct AndroidStorageAccess {
    typealias Result = (code: Int32, output: String, error: String)
    typealias Runner = @Sendable (String) async -> Result
    typealias Wait = @Sendable () async throws -> Void

    struct Storage: Equatable, Sendable {
        let path: String
        let userID: Int
    }

    enum Failure: LocalizedError {
        case notReady
        case permissionDenied
        case unavailable
        case recoveryFailed
        case firmwareRestricted

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Your device is still starting. Keep it unlocked and try again in a moment."
            case .permissionDenied:
                return "Android is blocking access to your files. Keep your device unlocked and try Fix storage access."
            case .unavailable:
                return "Your device's storage is unavailable. Unlock your device, reconnect it, and try again."
            case .recoveryFailed:
                return "Android is still blocking file access. Restart your device and try again. If this continues, save diagnostics and share the file with us."
            case .firmwareRestricted:
                return "Your device's Android software is blocking file access through this connection. Save diagnostics and share the file with us so we can check which storage connections are available."
            }
        }
    }

    let run: Runner

    // Android 11 vold exposes separate sdcardfs permission views. The public
    // aliases can all reach the same denied mount on older Retroid firmware.
    // https://android.googlesource.com/platform/system/vold/+/refs/heads/android11-release/model/EmulatedVolume.cpp
    static func storagePaths(userID: Int) -> [String] {
        ["/storage/emulated/\(userID)", "/sdcard", "/storage/self/primary", "/mnt/sdcard",
         "/mnt/runtime/write/emulated/\(userID)", "/mnt/runtime/full/emulated/\(userID)",
         "/mnt/runtime/read/emulated/\(userID)", "/mnt/runtime/default/emulated/\(userID)",
         "/mnt/user/\(userID)/primary", "/mnt/user/\(userID)/emulated/\(userID)"]
    }

    /// Recognize only complete storage path components, never similarly named folders.
    private static func location(_ path: String) -> (root: String, canonical: String)? {
        let parts = path.split(separator: "/").map(String.init)
        func root(_ count: Int, user: String) -> (String, String)? {
            guard let userID = Int(user), userID >= 0 else { return nil }
            return ("/" + parts.prefix(count).joined(separator: "/"), "/storage/emulated/\(userID)")
        }
        if parts.count >= 3, parts[0] == "storage", parts[1] == "emulated" {
            return root(3, user: parts[2])
        }
        if parts.count >= 5, parts[0] == "mnt", parts[1] == "runtime",
           ["write", "full", "read", "default"].contains(parts[2]), parts[3] == "emulated" {
            return root(5, user: parts[4])
        }
        if parts.count >= 4, parts[0] == "mnt", parts[1] == "user", parts[3] == "primary" {
            return root(4, user: parts[2])
        }
        if parts.count >= 5, parts[0] == "mnt", parts[1] == "user", parts[3] == "emulated",
           parts[2] == parts[4] {
            return root(5, user: parts[2])
        }
        for alias in ["/sdcard", "/storage/self/primary", "/mnt/sdcard"] {
            if path == alias || path.hasPrefix(alias + "/") { return (alias, "/storage/emulated/0") }
        }
        return nil
    }

    static func storageRoot(for path: String) -> String? { location(path)?.root }

    static func canonicalPath(_ path: String) -> String {
        let absolutePath = path == "sdcard" || path.hasPrefix("sdcard/") ? "/" + path : path
        guard let location = location(absolutePath) else { return path }
        return location.canonical + absolutePath.dropFirst(location.root.count)
    }

    /// MediaStore reports canonical paths; direct I/O must retain the accessible mount.
    static func path(_ canonicalPath: String, through storagePath: String) -> String {
        guard let location = location(storagePath),
              canonicalPath == location.canonical || canonicalPath.hasPrefix(location.canonical + "/") else {
            return canonicalPath
        }
        return location.root + canonicalPath.dropFirst(location.canonical.count)
    }

    static func isPermissionDenied(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("android is blocking")
    }

    static func commandError(_ result: Result, fallback: String) -> String {
        let detail = [result.error, result.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return detail.isEmpty ? fallback : detail
    }

    func resolve(verifyWrites: Bool = false) async throws -> Storage {
        try Task.checkCancellation()
        let user = await run("am get-current-user")
        try Task.checkCancellation()
        guard user.code == 0, let userID = Int(user.output.trimmingCharacters(in: .whitespacesAndNewlines)), userID >= 0 else {
            let error = Self.commandError(user, fallback: "").lowercased()
            if error.contains("can't find service: activity") || error.contains("service activity not found") {
                throw Failure.notReady
            }
            throw Failure.unavailable
        }
        let candidates = Self.storagePaths(userID: userID)
        var denied = false
        for path in candidates {
            try Task.checkCancellation()
            // Discard names: only access errors belong in the diagnostic report.
            // ls on a dangling command-line symlink can succeed by listing the link.
            // Verify the target is a directory before considering it usable.
            let result = await run("test -d '\(path)' && ls -1a '\(path)' >/dev/null")
            try Task.checkCancellation()
            if result.code == 0 {
                let storage = Storage(path: path, userID: userID)
                if !verifyWrites { return storage }
                do {
                    try await verifyWriteAccess(storage)
                    return storage
                } catch is CancellationError { throw CancellationError() }
                catch { denied = true }
            }
            denied = denied || Self.isPermissionDenied(Self.commandError(result, fallback: ""))
        }
        throw denied ? Failure.permissionDenied : Failure.unavailable
    }

    func resolveWhenReady(verifyWrites: Bool = false, attempts: Int = 10,
                          wait: Wait = { try await Task.sleep(nanoseconds: 1_000_000_000) }) async throws -> Storage {
        for attempt in 0..<max(1, attempts) {
            do { return try await resolve(verifyWrites: verifyWrites) }
            catch Failure.notReady {
                guard attempt + 1 < max(1, attempts) else { throw Failure.notReady }
                try await wait()
            }
        }
        throw Failure.notReady
    }

    private func verifyWriteAccess(_ storage: Storage) async throws {
        try Task.checkCancellation()
        // mktemp never overwrites existing files; remove only the file it just created.
        let result = await run("afs_probe=$(mktemp '\(storage.path)/.afs-access-XXXXXXXX') && rm -- \"$afs_probe\"")
        try Task.checkCancellation()
        guard result.code == 0 else { throw Failure.permissionDenied }
    }

    /// Android's documented all-files AppOp, with an Android 10/11 legacy fallback.
    /// Only invoked by the user's Fix storage access button. Failed changes are restored.
    func repair() async throws -> Storage {
        do {
            return try await resolveWhenReady(verifyWrites: true)
        } catch is CancellationError { throw CancellationError() }
        catch Failure.permissionDenied { /* Try the file access setting below. */ }
        catch { throw error }

        // The reporter verified that both AppOps are ineffective on this exact
        // firmware. The useful recovery is a different mount, checked above;
        // do not keep changing permissions that cannot fix its shell group access.
        let build = await run("getprop ro.build.display.id")
        try Task.checkCancellation()
        if build.code == 0, build.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == "RP3_V1.0.0.75_20230110_190901_user" {
            throw Failure.firmwareRestricted
        }

        let sdkResult = await run("getprop ro.build.version.sdk")
        try Task.checkCancellation()
        guard let sdk = Int(sdkResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.recoveryFailed
        }
        var operations: [String] = []
        if sdk >= 30 { operations.append("MANAGE_EXTERNAL_STORAGE") }
        if (29...30).contains(sdk) { operations.append("LEGACY_STORAGE") }

        for operation in operations {
            try Task.checkCancellation()
            let previous = await run("appops get --uid com.android.shell \(operation)")
            try Task.checkCancellation()
            // Never overwrite a setting whose previous value cannot be determined.
            guard previous.code == 0, let mode = Self.appOpMode(previous.output, operation: operation),
                  mode != "allow" else { continue }
            let changed = await run("appops set --uid com.android.shell \(operation) allow")
            if changed.code == 0 {
                do {
                    return try await resolve(verifyWrites: true)
                } catch {
                    // An unstructured task can restore the original setting even when
                    // navigation has cancelled the caller. The runner keeps the original device.
                    let restore = "appops set --uid com.android.shell \(operation) \(mode)"
                    let restored = await Task { await run(restore) }.value
                    if error is CancellationError { throw error }
                    guard restored.code == 0 else { throw Failure.recoveryFailed }
                }
            } else {
                // A timed-out command may have applied before the connection failed.
                let restore = "appops set --uid com.android.shell \(operation) \(mode)"
                _ = await Task { await run(restore) }.value
            }
            try Task.checkCancellation()
        }
        throw Failure.recoveryFailed
    }

    static func appOpMode(_ output: String, operation: String) -> String? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "No operations." { return "default" }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: operation)
            + ":\\s*(allow|ignore|deny|default|foreground)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
}

actor StorageDiagnosticLog {
    private var entries: [String] = []

    func record(_ command: String, result: AndroidStorageAccess.Result) {
        let detail = AndroidStorageAccess.commandError(result, fallback: "(no output)")
        entries.append("\(command)\nExit: \(result.code)\n\(detail.prefix(8000))")
        if entries.count > 160 { entries.removeFirst(entries.count - 160) }
    }

    func report() -> String { entries.joined(separator: "\n\n") }
}
