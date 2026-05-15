import Foundation

func shellRun(_ command: String, args: [String]) -> (Int32, String) {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.standardOutput = stdout
    try! process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

let pkg = "com.adobe.scan.android"
let script = "apk=$(pm path \(pkg) 2>/dev/null | grep base.apk | head -n 1 | sed 's/package://'); if [ -z \"$apk\" ]; then apk=$(pm path \(pkg) 2>/dev/null | head -n 1 | sed 's/package://'); fi; echo \"\(pkg)=$apk\""

print("Script: \(script)")
let res = shellRun("/opt/homebrew/bin/adb", args: ["-s", "192.168.1.64:37583", "shell", script])
print("Output: \(res.1)")

