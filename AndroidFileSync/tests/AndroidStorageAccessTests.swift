import Foundation

private actor DeviceFixture {
    var userID = 0
    var sdk = 30
    var readablePaths: Set<String> = []
    var writablePaths: Set<String> = []
    var workingOperation: String?
    var modes = ["MANAGE_EXTERNAL_STORAGE": "default", "LEGACY_STORAGE": "ignore"]
    var commands: [String] = []
    var cancelAfterAllow = false
    var unknownSnapshot = false
    var firmware = "test_firmware"
    var serviceFailuresRemaining = 0
    var readinessWaits = 0
    var nonDirectoryPaths: Set<String> = []

    func configure(readable: Set<String> = [], writable: Set<String> = [], operation: String? = nil,
                   user: Int = 0, sdk: Int = 30, cancel: Bool = false, unknown: Bool = false,
                   firmware: String = "test_firmware", serviceFailures: Int = 0,
                   nonDirectories: Set<String> = []) {
        readablePaths = readable
        writablePaths = writable
        workingOperation = operation
        userID = user
        self.sdk = sdk
        cancelAfterAllow = cancel
        unknownSnapshot = unknown
        self.firmware = firmware
        serviceFailuresRemaining = serviceFailures
        nonDirectoryPaths = nonDirectories
    }

    func command(_ command: String) -> AndroidStorageAccess.Result {
        commands.append(command)
        if command == "am get-current-user" {
            if serviceFailuresRemaining > 0 {
                serviceFailuresRemaining -= 1
                return (20, "cmd: Can't find service: activity", "")
            }
            return (0, "\(userID)\n", "")
        }
        if command == "getprop ro.build.version.sdk" { return (0, "\(sdk)\n", "") }
        if command == "getprop ro.build.display.id" { return (0, firmware + "\n", "") }
        let fixed = workingOperation.map { modes[$0] == "allow" } ?? false
        if command.hasPrefix("test -d '") {
            let path = String(command.dropFirst("test -d '".count).prefix { $0 != "'" })
            if nonDirectoryPaths.contains(path) { return (1, "", "") }
            return readablePaths.contains(path) || fixed
                ? (0, "", "") : (1, "", "ls: \(path): Permission denied\n")
        }
        if command.hasPrefix("afs_probe=") {
            let works = fixed || writablePaths.contains { command.contains("'\($0)/.afs-access-") }
            return works ? (0, "", "") : (1, "", "mktemp: Permission denied")
        }
        if command.hasPrefix("appops get --uid com.android.shell ") {
            let operation = String(command.split(separator: " ").last!)
            if unknownSnapshot { return (0, "Unrecognized firmware output", "") }
            return (0, "Uid mode: \(operation): \(modes[operation] ?? "default")\n", "")
        }
        if command.hasPrefix("appops set --uid com.android.shell ") {
            let parts = command.split(separator: " ")
            modes[String(parts[4])] = String(parts[5])
            if cancelAfterAllow && parts[5] == "allow" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return (0, "", "")
        }
        return (1, "", "Unexpected command: \(command)")
    }

    func snapshot() -> ([String], [String: String]) { (commands, modes) }
    func waited() { readinessWaits += 1 }
    func waitCount() -> Int { readinessWaits }
}

@main
struct AndroidStorageAccessTests {
    static func require(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }

    private static func access(_ device: DeviceFixture) -> AndroidStorageAccess {
        AndroidStorageAccess { await device.command($0) }
    }

    static func main() async throws {
        let empty = DeviceFixture()
        await empty.configure(readable: ["/storage/emulated/0"], writable: ["/storage/emulated/0"])
        let emptyStorage = try await access(empty).repair()
        require(emptyStorage.path == "/storage/emulated/0", "Empty accessible storage must work")
        let emptyCommands = await empty.snapshot().0
        require(!emptyCommands.contains { $0.hasPrefix("appops set") }, "Healthy storage must not change permissions")

        let alias = DeviceFixture()
        await alias.configure(readable: ["/sdcard"], writable: ["/sdcard"])
        let aliasStorage = try await access(alias).repair()
        require(aliasStorage.path == "/sdcard", "Recover through an accessible alias")
        require(await alias.snapshot().1["MANAGE_EXTERNAL_STORAGE"] == "default", "Alias recovery must preserve AppOps")

        let writableAlias = DeviceFixture()
        await writableAlias.configure(readable: ["/storage/emulated/0", "/sdcard"], writable: ["/sdcard"])
        let writableStorage = try await access(writableAlias).repair()
        require(writableStorage.path == "/sdcard", "Read-only first candidate must not hide a writable alias")

        let profile = DeviceFixture()
        await profile.configure(readable: ["/storage/emulated/10"], user: 10)
        let profileStorage = try await access(profile).resolve()
        require(profileStorage.userID == 10 && profileStorage.path == "/storage/emulated/10", "Respect the active Android user")

        let retroid = DeviceFixture()
        await retroid.configure(operation: "MANAGE_EXTERNAL_STORAGE")
        let recovered = try await access(retroid).repair()
        require(recovered.path == "/storage/emulated/0", "All-files access should recover denied storage")
        let recoveredState = await retroid.snapshot()
        require(recoveredState.1["MANAGE_EXTERNAL_STORAGE"] == "allow", "Keep a verified working permission")
        require(recoveredState.1["LEGACY_STORAGE"] == "ignore", "Do not change unnecessary permissions")
        require(recoveredState.0.contains { $0.hasPrefix("afs_probe=") }, "Verify writes before reporting success")

        let legacy = DeviceFixture()
        await legacy.configure(operation: "LEGACY_STORAGE")
        _ = try await access(legacy).repair()
        let legacyState = await legacy.snapshot()
        require(legacyState.1["MANAGE_EXTERNAL_STORAGE"] == "default", "Restore unsuccessful all-files change")
        require(legacyState.1["LEGACY_STORAGE"] == "allow", "Support Android 11 legacy firmware")

        let blocked = DeviceFixture()
        do {
            _ = try await access(blocked).repair()
            fatalError("Blocked firmware must not report recovery")
        } catch AndroidStorageAccess.Failure.recoveryFailed { }
        let blockedState = await blocked.snapshot()
        require(blockedState.1["MANAGE_EXTERNAL_STORAGE"] == "default" && blockedState.1["LEGACY_STORAGE"] == "ignore",
                "Restore every unsuccessful change")

        let readOnly = DeviceFixture()
        await readOnly.configure(readable: ["/storage/emulated/0"])
        do {
            _ = try await access(readOnly).repair()
            fatalError("Read access alone must not count as a fix")
        } catch AndroidStorageAccess.Failure.recoveryFailed { }

        let unknown = DeviceFixture()
        await unknown.configure(unknown: true)
        do { _ = try await access(unknown).repair(); fatalError("Unknown firmware must fail clearly") }
        catch AndroidStorageAccess.Failure.recoveryFailed { }
        let unknownCommands = await unknown.snapshot().0
        require(!unknownCommands.contains { $0.hasPrefix("appops set") }, "Preserve settings when snapshot is unknown")

        let cancelled = DeviceFixture()
        await cancelled.configure(operation: "MANAGE_EXTERNAL_STORAGE", cancel: true)
        let task = Task { try await access(cancelled).repair() }
        do { _ = try await task.value; fatalError("Cancellation must propagate") }
        catch is CancellationError { }
        require(await cancelled.snapshot().1["MANAGE_EXTERNAL_STORAGE"] == "default", "Restore permissions on cancellation")

        let oldAndroid = DeviceFixture()
        await oldAndroid.configure(sdk: 28)
        do { _ = try await access(oldAndroid).repair(); fatalError("Unsupported firmware must fail clearly") }
        catch AndroidStorageAccess.Failure.recoveryFailed { }
        let oldCommands = await oldAndroid.snapshot().0
        require(!oldCommands.contains { $0.hasPrefix("appops set") }, "Do not send unsupported operations")

        require(AndroidStorageAccess.commandError((1, "ls: Permission denied\n", ""), fallback: "Generic") == "ls: Permission denied",
                "Preserve errors redirected to stdout")
        require(AndroidStorageAccess.appOpMode("No operations.\n", operation: "MANAGE_EXTERNAL_STORAGE") == "default",
                "Support unset AppOps")
        require(AndroidStorageAccess.appOpMode("LEGACY_STORAGE: foreground; time=+3s", operation: "LEGACY_STORAGE") == "foreground",
                "Preserve explicit modes")
        // Reproduce the new Retroid report: the public aliases remain denied
        // even after AppOps changes, but a separate sdcardfs view may work.
        let retroidFirmware = "RP3_V1.0.0.75_20230110_190901_user"
        let runtimeWrite = "/mnt/runtime/write/emulated/0"
        let runtimeFull = "/mnt/runtime/full/emulated/0"
        let runtimeRead = "/mnt/runtime/read/emulated/0"
        let retroidMount = DeviceFixture()
        await retroidMount.configure(readable: [runtimeWrite], writable: [runtimeWrite], firmware: retroidFirmware)
        let runtimeStorage = try await access(retroidMount).repair()
        require(runtimeStorage.path == runtimeWrite, "Use a writable runtime view when all public aliases are denied")
        require(await retroidMount.snapshot().0.allSatisfy { !$0.hasPrefix("appops set") },
                "Retroid mount recovery must not depend on ineffective AppOps changes")

        let fullMount = DeviceFixture()
        await fullMount.configure(readable: [runtimeWrite, runtimeFull], writable: [runtimeFull], firmware: retroidFirmware)
        require(try await access(fullMount).repair().path == runtimeFull, "Verify the full mount when the write view is read-only")

        let restrictedFirmware = DeviceFixture()
        await restrictedFirmware.configure(firmware: retroidFirmware)
        do { _ = try await access(restrictedFirmware).repair(); fatalError("Do not claim recovery when every mount is denied") }
        catch AndroidStorageAccess.Failure.firmwareRestricted { }
        require(await restrictedFirmware.snapshot().0.allSatisfy { !$0.hasPrefix("appops set") },
                "Do not repeat the permission experiments disproved by the reporter's log")

        let readMount = DeviceFixture()
        await readMount.configure(readable: [runtimeRead], firmware: retroidFirmware)
        require(try await access(readMount).resolve().path == runtimeRead, "Allow browsing through a readable view")
        do { _ = try await access(readMount).repair(); fatalError("A read-only mount is not a complete transfer fix") }
        catch AndroidStorageAccess.Failure.firmwareRestricted { }

        let starting = DeviceFixture()
        await starting.configure(readable: ["/storage/emulated/0", "/sdcard"], writable: ["/storage/emulated/0"], serviceFailures: 2)
        let startupStorage = try await access(starting).resolveWhenReady(verifyWrites: true, attempts: 3,
                                                                       wait: { await starting.waited() })
        require(startupStorage.path == "/storage/emulated/0", "Wait for Android's activity service before selecting a mount")
        require(await starting.waitCount() == 2, "Retry only while Android is starting")
        let startupCommands = await starting.snapshot().0
        require(Array(startupCommands.prefix(3)) == Array(repeating: "am get-current-user", count: 3),
                "Do not accept /sdcard while the Android service is missing")

        let dangling = DeviceFixture()
        await dangling.configure(readable: ["/sdcard", runtimeWrite], writable: [runtimeWrite],
                                 nonDirectories: ["/sdcard"])
        require(try await access(dangling).resolve().path == runtimeWrite,
                "A command-line symlink that ls can print is not a usable directory")

        let pathCases = [
            (runtimeWrite + "/DCIM/photo.jpg", "/storage/emulated/0/DCIM/photo.jpg"),
            (runtimeFull + "/Download", "/storage/emulated/0/Download"),
            ("/mnt/runtime/read/emulated/10/Music/song.mp3", "/storage/emulated/10/Music/song.mp3"),
            ("/mnt/user/0/primary/Pictures", "/storage/emulated/0/Pictures"),
            ("/mnt/user/10/emulated/10/Documents", "/storage/emulated/10/Documents"),
            ("/sdcard/Pictures", "/storage/emulated/0/Pictures")
        ]
        for (mountPath, canonical) in pathCases {
            require(AndroidStorageAccess.canonicalPath(mountPath) == canonical, "Normalize mounts for MediaStore: \(mountPath)")
            let root = AndroidStorageAccess.storageRoot(for: mountPath)!
            require(AndroidStorageAccess.path(canonical, through: root) == mountPath,
                    "Keep downloads and previews on the accessible mount: \(mountPath)")
        }
        require(AndroidStorageAccess.canonicalPath("/sdcard-backup/file") == "/sdcard-backup/file",
                "Do not rewrite similarly named directories")
        require(AndroidStorageAccess.path("/storage/1234-ABCD/file", through: runtimeWrite) == "/storage/1234-ABCD/file",
                "Do not redirect SD-card I/O to internal storage")
        print("Passed 22 storage-access scenarios.")
    }
}
