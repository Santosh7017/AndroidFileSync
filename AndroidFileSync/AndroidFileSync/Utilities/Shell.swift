import Foundation

struct Shell {
    static func run(_ command: String, args: [String]) -> (Int32, String, String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
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
    static func runAsync(_ command: String, args: [String]) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = stderr
            
            process.terminationHandler = { process in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""
                
                continuation.resume(returning: (process.terminationStatus, output, error))
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
    
    // Async run with timeout - kills process if it takes too long
    static func runAsyncWithTimeout(_ command: String, args: [String], timeoutSeconds: Double) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = stderr
            
            var hasResumed = false
            let lock = NSLock()
            
            // Timeout timer
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                lock.lock()
                defer { lock.unlock() }
                
                if !hasResumed && process.isRunning {
                    process.terminate()
                    hasResumed = true
                    continuation.resume(returning: (-1, "", "Command timed out after \(Int(timeoutSeconds)) seconds"))
                }
            }
            
            process.terminationHandler = { proc in
                lock.lock()
                defer { lock.unlock() }
                
                if !hasResumed {
                    hasResumed = true
                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    continuation.resume(returning: (proc.terminationStatus, output, error))
                }
            }
            
            do {
                try process.run()
            } catch {
                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                }
                lock.unlock()
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
                        print("🔍 Shell: Cancellation monitor started for PID \(process.processIdentifier)")
                        
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
                        print("🔍 Shell: Cancellation monitor exited")
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

