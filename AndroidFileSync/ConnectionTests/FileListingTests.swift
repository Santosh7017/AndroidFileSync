import Foundation

extension ConnectionTests {
    static func testFileListing() async throws {
        let path = "/storage/emulated/0/Download"
        let names = ["report.pdf", "archive.zip", "installer.apk", "旅程, summer's notes.txt"]
        let rows = names.enumerated().map { "Row: \($0.offset) _display_name=\($0.element), _id=\($0.offset + 1)" }
            .joined(separator: "\n") + "\n"
        let metadata = names.map { "-rw-rw----|1024|1700000000|\($0)" }.joined(separator: "\n") + "\n"

        func prepare(ls: [String: Any], provider: String = "", find: String = "") throws {
            ConnectionTestDefaults.shared.reset()
            ADBManager.activeDeviceSerial = "LISTING-PHONE"
            Shell.useDefaultServer = false
            try fixture([
                "live": ["LISTING-PHONE": "LISTING-PHONE"],
                "shellResponses": [
                    "ls -1a": ls,
                    "find ": ["output": find],
                    "content query --uri \"content://media/external/file": ["output": provider],
                    "cd '": ["output": metadata],
                ],
            ])
        }

        func shellCommands() throws -> [String] {
            try commands().filter { $0["command"] as? String == "shell" }
                .compactMap { ($0["args"] as? [String])?.dropFirst().joined(separator: " ") }
        }

        func queryFilters() throws -> [String] {
            try commands().compactMap { command in
                guard let words = command["shellWords"] as? [String],
                      let index = words.firstIndex(of: "--where"), index + 1 < words.count else { return nil }
                return words[index + 1]
            }
        }

        // Ordinary Downloads browsing stays on direct I/O.
        try prepare(ls: ["output": ".\n..\n" + names.joined(separator: "\n") + "\n"])
        let direct = try await ADBManager.listFiles(path: path)
        check(Set(direct.map(\.name)) == Set(names), "Direct Downloads listing retains every file")
        check(!(try shellCommands()).contains { $0.hasPrefix("content query") },
              "A nonempty direct listing needs no provider queries")

        // Reproduce the report: exit 0, zero entries, but documents exist in MediaStore.
        try prepare(ls: ["output": ".\n..\n"], provider: rows)
        var progressive: [ADBFile] = []
        let recovered = try await ADBManager.listFiles(path: path) { progressive.append(contentsOf: $0) }
        check(Set(recovered.map(\.name)) == Set(names), "Empty ls recovers PDFs, archives, APKs and Unicode names")
        check(progressive.count == names.count, "Provider results reach progressive browsing")
        check(recovered.allSatisfy { $0.path == path + "/" + $0.name && $0.size == 1024 },
              "Recovered entries retain their download paths and metadata")
        check((try queryFilters()).contains("relative_path='Download/' AND _id>0"),
              "Provider query targets the Android Download directory")

        // A failed direct read also uses the same all-files provider.
        try prepare(ls: ["code": 1, "error": "ls: \(path): Permission denied\n"], provider: rows)
        let denied = try await ADBManager.listFiles(path: path)
        check(denied.count == names.count, "Permission-denied Downloads listing uses the fallback")

        // Firmware can emit an error into stdout while returning exit 0.
        try prepare(ls: ["output": "ls: \(path): Operation not permitted\n"],
                    find: names.map { path + "/" + $0 }.joined(separator: "\n") + "\n")
        let found = try await ADBManager.listFiles(path: path)
        check(found.count == names.count, "A zero-exit stdout error can recover with find")

        // When recovery fails, the UI must receive the original access error.
        try prepare(ls: ["output": "ls: \(path): Permission denied\n"])
        do {
            _ = try await ADBManager.listFiles(path: path)
            check(false, "Failed recovery must throw instead of presenting an empty folder")
        } catch {
            check(AndroidStorageAccess.isPermissionDenied(error.localizedDescription),
                  "Failed recovery preserves the actionable permission error")
        }
        try prepare(ls: ["error": "Permission denied\n"])
        do {
            _ = try await ADBManager.listFiles(path: "/storage/emulated/0/Documents")
            check(false, "A stderr access error with exit 0 must throw for ordinary folders too")
        } catch {
            check(AndroidStorageAccess.isPermissionDenied(error.localizedDescription),
                  "A zero-exit stderr access error remains visible")
        }

        try prepare(ls: ["output": ""], provider: "No result found.\n")
        let empty = try await ADBManager.listFiles(path: path)
        check(empty.isEmpty, "An empty Downloads folder stays empty")
        check(!(try shellCommands()).contains { $0.contains("media.scanner scan") },
              "A successful empty listing avoids the scan and delayed retry")

        try prepare(ls: ["output": ""], provider: rows)
        let similarlyNamed = try await ADBManager.listFiles(path: "/storage/emulated/0/Downloaded")
        let similarlyNamedCommands = try shellCommands()
        check(similarlyNamed.isEmpty && !similarlyNamedCommands.contains { $0.hasPrefix("content query") },
              "Similarly named folders do not activate the Downloads fallback")

        try prepare(ls: ["output": ""], provider: rows)
        let nested = try await ADBManager.listFiles(path: "/sdcard/Download/Work")
        let nestedFilters = try queryFilters()
        check(nested.count == names.count && nestedFilters.contains("relative_path='Download/Work/' AND _id>0"),
              "Downloads subfolders and the sdcard alias use the correct provider filter")

        try prepare(ls: ["output": ""], provider: rows)
        let specialFolder = "Work's \"notes\" $(echo literal) `echo literal`"
        let special = try await ADBManager.listFiles(path: path + "/" + specialFolder)
        let expectedFilter = "relative_path='Download/" + specialFolder.replacingOccurrences(of: "'", with: "''") + "/' AND _id>0"
        let specialFilters = try queryFilters()
        check(special.count == names.count && specialFilters.contains(expectedFilter),
              "Download folder names reach SQL literally through shell quoting")
    }
}
