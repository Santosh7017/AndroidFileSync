import Foundation

struct Shell {
    /// Dedicated ADB server port used by this app to avoid interfering with other tools.
    /// Any adb process started by app commands will use this private server.
    private static let appADBServerPort = 56037

    /// When true, all ADB commands are routed to the default server (port 5037).
    /// This allows the app to piggyback on an existing server that already owns the
    /// USB transport (e.g. Android Studio), so both tools can coexist without conflict.
    static var useDefaultServer: Bool = false

    /// The environment used for all standard ADB commands.
    /// Automatically routes to the default server (5037) when `useDefaultServer` is true,
    /// or to our private server (56037) otherwise.
    static var activeADBEnvironment: [String: String] {
        useDefaultServer ? defaultADBEnvironment : adbEnvironment
    }

    /// Environment variables applied to ALL processes launched by Shell.
    /// We isolate adb to a private server and disable adb's automatic mDNS auto-connect
    /// so the app controls when connections are established.
    static var adbEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_ADB_SERVER_PORT"] = String(appADBServerPort)
        env["ADB_SERVER_PORT"] = String(appADBServerPort)
        env["ADB_MDNS_AUTO_CONNECT"] = "0"
        return env
    }

    /// Environment for talking to the default adb server. This is used only for
    /// targeted USB transport recovery when another adb server is holding USB.
    static var defaultADBEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        env.removeValue(forKey: "ADB_SERVER_PORT")
        env["ADB_MDNS_AUTO_CONNECT"] = "0"
        return env
    }
    static func run(_ command: String, args: [String]) -> (Int32, String, String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = activeADBEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        
        return (process.terminationStatus, output, error)
    }
    
    // Truly async run using continuation and termination handler
    // Drains stdout/stderr dynamically to prevent pipe buffer deadlock under large outputs.
    // Handles Swift Task cancellation by terminating the running Process.
    static func runAsync(_ command: String, args: [String]) async -> (Int32, String, String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = activeADBEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        
        return await withTaskCancellationHandler {
            return await withCheckedContinuation { continuation in
                var outputData = Data()
                var errorData = Data()
                var hasResumed = false
                let lock = NSLock()
                
                func finish(status: Int32, flushRemaining: Bool) {
                    lock.lock()
                    if !hasResumed {
                        hasResumed = true
                        
                        stdoutHandle.readabilityHandler = nil
                        stderrHandle.readabilityHandler = nil
                        
                        if flushRemaining {
                            outputData.append(stdoutHandle.readDataToEndOfFile())
                            errorData.append(stderrHandle.readDataToEndOfFile())
                        }
                        
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        let error = String(data: errorData, encoding: .utf8) ?? ""
                        
                        continuation.resume(returning: (status, output, error))
                    }
                    lock.unlock()
                }
                
                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    lock.lock()
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        outputData.append(data)
                    }
                    lock.unlock()
                }
                
                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    lock.lock()
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        errorData.append(data)
                    }
                    lock.unlock()
                }
                
                process.terminationHandler = { proc in
                    finish(status: proc.terminationStatus, flushRemaining: true)
                }
                
                if Task.isCancelled {
                    finish(status: -999, flushRemaining: false)
                    return
                }
                
                do {
                    try process.run()
                } catch {
                    finish(status: -1, flushRemaining: false)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
    
    // Async run with timeout - drains stdout/stderr while the process is running
    // so large responses (for example MediaStore `content query` output) do not
    // deadlock after filling the pipe buffer.
    static func runAsyncWithTimeout(
        _ command: String,
        args: [String],
        timeoutSeconds: Double,
        environment: [String: String]? = nil
    ) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
            process.environment = environment ?? activeADBEnvironment
            process.standardOutput = stdout
            process.standardError = stderr
            
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            
            var outputData = Data()
            var errorData = Data()
            var hasResumed = false
            var didTimeout = false
            let lock = NSLock()
            
            func finish(status: Int32, flushRemaining: Bool, extraErrorMessage: String? = nil) {
                var result: (Int32, String, String)?
                
                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    
                    if flushRemaining {
                        outputData.append(stdoutHandle.readDataToEndOfFile())
                        errorData.append(stderrHandle.readDataToEndOfFile())
                    }
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    var error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    if let extraErrorMessage, !extraErrorMessage.isEmpty {
                        error = error.isEmpty ? extraErrorMessage : error + "\n" + extraErrorMessage
                    }
                    
                    if didTimeout {
                        let timeoutMessage = "Command timed out after \(Int(timeoutSeconds)) seconds"
                        error = error.isEmpty ? timeoutMessage : error + "\n" + timeoutMessage
                    }
                    
                    result = (didTimeout ? -1 : status, output, error)
                }
                lock.unlock()
                
                if let result {
                    continuation.resume(returning: result)
                }
            }
            
            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                lock.lock()
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outputData.append(data)
                }
                lock.unlock()
            }
            
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                lock.lock()
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errorData.append(data)
                }
                lock.unlock()
            }
            
            // Timeout timer
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                var shouldTerminate = false
                
                lock.lock()
                if !hasResumed && process.isRunning {
                    didTimeout = true
                    shouldTerminate = true
                }
                lock.unlock()
                
                guard shouldTerminate else { return }
                
                process.terminate()
                
                // Give Process a moment to deliver its termination handler so we can
                // flush any remaining bytes. If it still refuses to die, force-kill it
                // and return the partial output captured so far.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    finish(status: -1, flushRemaining: false)
                }
            }
            
            process.terminationHandler = { proc in
                finish(status: proc.terminationStatus, flushRemaining: true)
            }
            
            do {
                try process.run()
            } catch {
                finish(status: -1, flushRemaining: false, extraErrorMessage: error.localizedDescription)
            }
        }
    }
    
    static func bash(_ command: String) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run("/bin/bash", args: ["-c", command])
                continuation.resume(returning: result)
            }
        }
    }
    
    // New: Run with progress tracking - reads stderr for ADB progress
    static func runWithProgress(
        _ command: String,
        args: [String],
        progressCallback: @escaping (String) -> Void
    ) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args
                process.environment = activeADBEnvironment
                process.standardOutput = stdout
                process.standardError = stderr
                
                var outputData = Data()
                var errorData = Data()
                
                // ADB outputs progress to STDERR, not STDOUT!
                let stderrHandle = stderr.fileHandleForReading
                
                // Read stderr in background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let data = stderrHandle.availableData
                        if data.isEmpty { break }
                        
                        errorData.append(data)
                        
                        // Send progress updates
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            DispatchQueue.main.async {
                                progressCallback(text)
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    // Get final output
                    outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    continuation.resume(returning: (process.terminationStatus, output, error))
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                }
            }
        }
    }
    
    // New: Run with progress tracking and cancellation support
    static func runWithProgressCancellable(
        _ command: String,
        args: [String],
        progressCallback: @escaping (String) -> Void,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async -> (Int32, String, String, Process) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args
                process.environment = activeADBEnvironment
                process.standardOutput = stdout
                process.standardError = stderr
                
                var outputData = Data()
                var errorData = Data()
                var hasResumed = false
                let resumeLock = NSLock()
                
                // ADB outputs progress to STDERR, not STDOUT!
                let stderrHandle = stderr.fileHandleForReading
                
                // Read stderr in background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let data = stderrHandle.availableData
                        if data.isEmpty { break }
                        
                        errorData.append(data)
                        
                        // Send progress updates
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            DispatchQueue.main.async {
                                progressCallback(text)
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                    
                    // Start cancellation monitor AFTER process starts running
                    DispatchQueue.global(qos: .userInitiated).async {
                        
                        while process.isRunning {
                            if cancellationCheck() {
                                let pid = process.processIdentifier
                                print("🛑 Shell: Cancellation detected! Killing PID \(pid) with SIGKILL...")
                                
                                // Use SIGKILL for immediate termination (ADB may ignore SIGTERM)
                                kill(pid, SIGKILL)
                                
                                print("🛑 Shell: SIGKILL sent to PID \(pid)")
                                break
                            }
                            // Check every 100ms for quick response
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    }
                    
                    process.waitUntilExit()
                    
                    resumeLock.lock()
                    if !hasResumed {
                        hasResumed = true
                        // Get final output
                        outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                        
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        let error = String(data: errorData, encoding: .utf8) ?? ""
                        
                        resumeLock.unlock()
                        continuation.resume(returning: (process.terminationStatus, output, error, process))
                    } else {
                        resumeLock.unlock()
                    }
                } catch {
                    resumeLock.lock()
                    if !hasResumed {
                        hasResumed = true
                        resumeLock.unlock()
                        continuation.resume(returning: (-1, "", error.localizedDescription, process))
                    } else {
                        resumeLock.unlock()
                    }
                }
            }
        }
    }

}
