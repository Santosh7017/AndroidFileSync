import Foundation

/// Owns subprocesses for the app's lifetime. Once quitting starts, only explicit
/// cleanup commands may launch; an in-flight reconnect cannot restart ADB.
nonisolated enum AppProcessLifecycle {
    private static let lock = NSLock()
    private static var terminating = false
    private static var processes: [ObjectIdentifier: Process] = [:]

    static var isTerminating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminating
    }

    static func run(_ process: Process, allowDuringTermination: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating || allowDuringTermination else { throw CancellationError() }
        // Launch and registration share the shutdown lock, so a queued process
        // cannot slip through after beginTermination has collected its children.
        try process.run()
        if !allowDuringTermination {
            processes[ObjectIdentifier(process)] = process
        }
    }

    static func didExit(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    static func beginTermination() {
        lock.lock()
        guard !terminating else { lock.unlock(); return }
        terminating = true
        let children = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in children where process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            for process in children where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Owns a command across launch, cancellation, timeout, and pipe completion.
/// All mutable state is protected by the lock; callers may cancel before launch.
nonisolated final class CommandProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var stopped: (Int32, String)?
    private var continuation: CheckedContinuation<(Int32, String, String), Never>?
    private var completed = false
    private let allowDuringTermination: Bool
    private let onOutput: (@Sendable (Data) -> Void)?

    init(command: String, args: [String], environment: [String: String], allowDuringTermination: Bool = false,
         onOutput: (@Sendable (Data) -> Void)? = nil) {
        self.allowDuringTermination = allowDuringTermination
        self.onOutput = onOutput
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
    }

    func start(timeout: Double?, continuation: CheckedContinuation<(Int32, String, String), Never>) {
        lock.lock()
        self.continuation = continuation
        let previousStop = stopped
        lock.unlock()
        if let previousStop {
            finish(code: previousStop.0, message: previousStop.1)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { self.launch(timeout: timeout) }
    }

    private func launch(timeout: Double?) {
        let readers = DispatchGroup()
        lock.lock()
        guard stopped == nil else {
            let stop = stopped!
            lock.unlock()
            finish(code: stop.0, message: stop.1)
            return
        }
        process.terminationHandler = { [self] process in
            AppProcessLifecycle.didExit(process)
            readers.notify(queue: .global(qos: .utility)) { [self] in
                finish(code: process.terminationStatus)
                process.terminationHandler = nil
            }
        }
        // Reserve readers before launching: very short commands can exit immediately.
        readers.enter()
        readers.enter()
        do {
            try AppProcessLifecycle.run(process, allowDuringTermination: allowDuringTermination)
            lock.unlock()
        } catch {
            lock.unlock()
            readers.leave()
            readers.leave()
            finish(code: error is CancellationError ? -999 : -1, message: error.localizedDescription)
            return
        }
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    lock.lock()
                    if isError {
                        // A long-lived watcher must not accumulate unbounded diagnostics.
                        error.append(onOutput == nil ? data : data.prefix(max(0, 65_536 - error.count)))
                    } else if onOutput == nil { output.append(data) }
                    let deliver = !completed && stopped == nil
                    lock.unlock()
                    if !isError, deliver { onOutput?(data) }
                }
                readers.leave()
            }
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                self?.stop(code: -1, message: "Command timed out after \(timeout) seconds")
            }
        }
    }

    func cancel() { stop(code: -999, message: "Command cancelled") }

    private func stop(code: Int32, message: String) {
        lock.lock()
        guard !completed, stopped == nil else { lock.unlock(); return }
        stopped = (code, message)
        let isRunning = process.isRunning
        if isRunning { process.terminate() }
        lock.unlock()
        finish(code: code, message: message)
        if isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }

    private func finish(code: Int32, message: String = "") {
        if !process.isRunning { process.terminationHandler = nil }
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        let finalCode = stopped?.0 ?? code
        let finalMessage = stopped?.1 ?? message
        let out = String(data: output, encoding: .utf8) ?? String(data: output, encoding: .isoLatin1) ?? ""
        var err = String(data: error, encoding: .utf8) ?? String(data: error, encoding: .isoLatin1) ?? ""
        if !finalMessage.isEmpty { err += (err.isEmpty ? "" : "\n") + finalMessage }
        lock.unlock()
        continuation.resume(returning: (finalCode, out, err))
    }
}
