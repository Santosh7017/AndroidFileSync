// Managers/AppManager.swift
// All ADB operations for Android app management

import Foundation
import AppKit
internal import Combine
import UniformTypeIdentifiers

@MainActor
class AppManager: ObservableObject {

    // MARK: - Published State

    @Published var apps: [AppInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var statusMessage: String = ""
    /// Per-package size info — populated lazily after list loads
    @Published var appSizes: [String: AppSizeInfo] = [:]
    @Published var isFetchingSizes = false

    struct AppSizeInfo {
        let codeBytes: Int64
        let dataBytes: Int64
        let cacheBytes: Int64
        /// True when measured via fallback (missing internal /data/data/ — needs root)
        var isApproximate: Bool = false

        var totalBytes: Int64 { codeBytes + dataBytes + cacheBytes }

        /// Prefix shown on the size badge when approximate
        var badgePrefix: String { isApproximate ? "≥ " : "" }

        /// Human-readable breakdown matching Android Settings terminology.
        var summary: String {
            let approxNote = isApproximate ? "  · excl. internal" : ""
            if codeBytes > 0 && dataBytes > 0 {
                return "App: \(formatBytes(codeBytes))  ·  Data: \(formatBytes(dataBytes))\(approxNote)"
            } else if codeBytes > 0 {
                return "App: \(formatBytes(codeBytes))\(approxNote)"
            } else if dataBytes > 0 {
                return "Data: \(formatBytes(dataBytes))\(approxNote)"
            }
            return ""
        }

        private func formatBytes(_ bytes: Int64) -> String {
            let mb = Double(bytes) / 1_048_576
            if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
            if mb >= 1    { return String(format: "%.0f MB", mb) }
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
    }

    /// True when sizes come from fallback strategy (internal data not measured)
    @Published var sizesAreApproximate = false

    // MARK: - Fetch App Sizes (lazy, called after list is shown)

    /// Fetches per-package storage usage. Uses a cascade of strategies
    /// to handle different Android versions and manufacturer ROMs (including MIUI/Xiaomi).
    func fetchAppSizes() async {
        guard !apps.isEmpty else { return }
        await MainActor.run { isFetchingSizes = true }

        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            await MainActor.run { isFetchingSizes = false }
            return
        }

        // Strategy 1: dumpsys diskstats (exact — includes internal data)
        var sizes = await parseDiskStats(adbPath: adbPath)
        var isApprox = false
        print("📦 AppSizes strategy 1 (diskstats): \(sizes.count) entries")

        // Strategy 2: cmd package list packages --show-size (Android 10+)
        if sizes.isEmpty {
            sizes = await parseCmdPackageSize(adbPath: adbPath)
            print("📦 AppSizes strategy 2 (cmd package): \(sizes.count) entries")
        }

        // Strategy 3: external storage only — misses internal /data/data/ (needs root)
        if sizes.isEmpty {
            sizes = await parseAPKSizesFallback(adbPath: adbPath)
            isApprox = !sizes.isEmpty   // mark as approximate — internal data excluded
            // Tag every entry so the UI can show ≥ prefix
            sizes = sizes.mapValues { info in
                AppSizeInfo(codeBytes: info.codeBytes,
                            dataBytes: info.dataBytes,
                            cacheBytes: info.cacheBytes,
                            isApproximate: true)
            }
            print("📦 AppSizes strategy 3 (fallback, approx): \(sizes.count) entries")
        }

        await MainActor.run {
            self.appSizes = sizes
            self.sizesAreApproximate = isApprox
            self.isFetchingSizes = false
        }
    }

    // MARK: Strategy 1 — dumpsys diskstats (handles AOSP & MIUI variants)

    private func parseDiskStats(adbPath: String) async -> [String: AppSizeInfo] {
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "dumpsys", "diskstats"])
        )
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }

        var sizes: [String: AppSizeInfo] = [:]
        var inPackageSection = false

        // Section header variants across Android versions and MIUI
        let sectionHeaders = ["package sizes", "app sizes", "pkg sizes", "application sizes"]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            // Detect section start
            if !inPackageSection {
                if sectionHeaders.contains(where: { lower.hasPrefix($0) }) {
                    inPackageSection = true
                }
                continue
            }

            // Stop at next section (empty line or new section heading)
            if trimmed.isEmpty { continue }

            // Parse "com.package.name: code data cache"
            // Also handles "com.package.name  code data cache" (space separator, no colon)
            var pkg = ""
            var numString = ""

            if trimmed.contains(":") {
                let colonIdx = trimmed.firstIndex(of: ":")!
                pkg = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                numString = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            } else {
                // Space-separated format: first token is package name
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4 else { continue }
                pkg = String(parts[0])
                numString = parts.dropFirst().joined(separator: " ")
            }

            guard pkg.contains(".") else { continue } // must look like a package name
            let nums = numString.split(separator: " ", omittingEmptySubsequences: true)
                              .compactMap { Int64($0) }
            guard nums.count >= 1 else { continue }

            let code  = nums.count >= 1 ? nums[0] : 0
            let data  = nums.count >= 2 ? nums[1] : 0
            let cache = nums.count >= 3 ? nums[2] : 0
            sizes[pkg] = AppSizeInfo(codeBytes: code, dataBytes: data, cacheBytes: cache)
        }

        return sizes
    }

    // MARK: Strategy 2 — cmd package list packages (Android 10+)

    private func parseCmdPackageSize(adbPath: String) async -> [String: AppSizeInfo] {
        // This flag exists on Android 10+: outputs size info per package
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "cmd", "package", "list", "packages", "--show-size"])
        )
        var sizes: [String: AppSizeInfo] = [:]
        // Output: "package:com.example.app  size:12345"
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            let tokens = trimmed.components(separatedBy: "  ")
            guard tokens.count >= 2 else { continue }
            let pkg = String(tokens[0].dropFirst("package:".count))
            let sizeStr = tokens[1].replacingOccurrences(of: "size:", with: "")
            if let bytes = Int64(sizeStr) {
                sizes[pkg] = AppSizeInfo(codeBytes: bytes, dataBytes: 0, cacheBytes: 0)
            }
        }
        return sizes
    }

    // MARK: Strategy 3 — Full accessible storage (APK + external data + OBB)
    // No root required. Covers: APK file, /Android/data/<pkg>/, /Android/obb/<pkg>/
    // Missing: internal /data/data/<pkg>/ (requires root) — typically only a few MB.

    private func parseAPKSizesFallback(adbPath: String) async -> [String: AppSizeInfo] {

        // ── Phase 1: 3 fast parallel calls ────────────────────────────────────
        // (a) APK paths
        async let apkFetch = Shell.runAsync(adbPath,
            args: ADBManager.deviceArgs(["shell", "pm", "list", "packages", "-f"]))
        // (b) Which packages have external data dirs (ls is instant, no I/O scan)
        async let dataLsFetch = Shell.runAsync(adbPath,
            args: ADBManager.deviceArgs(["shell", "ls", "-1",
                "/storage/emulated/0/Android/data/"]))
        // (c) Which packages have OBB dirs
        async let obbLsFetch = Shell.runAsync(adbPath,
            args: ADBManager.deviceArgs(["shell", "ls", "-1",
                "/storage/emulated/0/Android/obb/"]))

        let (_, apkOut, _)    = await apkFetch
        let (_, dataLsOut, _) = await dataLsFetch
        let (_, obbLsOut, _)  = await obbLsFetch

        // ── Parse APK paths ───────────────────────────────────────────────────
        var pathMap: [String: String] = [:]  // pkg -> apk path
        for line in apkOut.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            let rest = String(trimmed.dropFirst("package:".count))
            guard let eqIdx = rest.lastIndex(of: "=") else { continue }
            let apkPath = String(rest[..<eqIdx])
            let pkg     = String(rest[rest.index(after: eqIdx)...])
            if !pkg.isEmpty { pathMap[pkg] = apkPath }
        }
        guard !pathMap.isEmpty else { return [:] }

        // ── Parse ls output → set of known package names ──────────────────────
        func parseLS(_ out: String) -> Set<String> {
            Set(out.components(separatedBy: .newlines)
                   .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                   .filter { $0.contains(".") && !$0.isEmpty })
        }
        let packagesWithData = parseLS(dataLsOut)
        let packagesWithOBB  = parseLS(obbLsOut)

        // ── Phase 2: APK stat + targeted du (only for packages that have dirs) ─
        // Run all 3 in parallel: stat-batches, data-du-batches, obb-du-batches
        async let apkSizesTask  = batchStatAPKs(pathMap: pathMap, adbPath: adbPath)
        async let dataSizesTask = batchDU(
            packages: Array(packagesWithData.filter { pathMap[$0] != nil || true }),
            basePath: "/storage/emulated/0/Android/data",
            adbPath: adbPath)
        async let obbSizesTask  = batchDU(
            packages: Array(packagesWithOBB),
            basePath: "/storage/emulated/0/Android/obb",
            adbPath: adbPath)

        let apkSizes  = await apkSizesTask
        let dataSizes = await dataSizesTask
        let obbSizes  = await obbSizesTask

        // ── Combine ───────────────────────────────────────────────────────────
        var sizes: [String: AppSizeInfo] = [:]
        for pkg in pathMap.keys {
            let code = apkSizes[pkg]  ?? 0
            let data = dataSizes[pkg] ?? 0
            let obb  = obbSizes[pkg]  ?? 0
            sizes[pkg] = AppSizeInfo(
                codeBytes:  code,
                dataBytes:  data + obb,   // external data + OBB game files
                cacheBytes: 0             // internal cache: needs root
            )
        }
        return sizes
    }

    // du -sk on the APK *parent directory* — captures base.apk + all split APKs + native libs.
    // This matches "App size" in Android Settings exactly.
    private func batchStatAPKs(pathMap: [String: String], adbPath: String) async -> [String: Int64] {
        var result: [String: Int64] = [:]

        // Build a map: pkg -> parent directory of base.apk
        // e.g. /data/app/~~xxx==/com.pubg.imobile-xxx/base.apk  →  /data/app/~~xxx==/com.pubg.imobile-xxx
        var dirMap: [String: String] = [:]
        for (pkg, apkPath) in pathMap {
            let dir = (apkPath as NSString).deletingLastPathComponent
            if !dir.isEmpty { dirMap[pkg] = dir }
        }
        guard !dirMap.isEmpty else { return [:] }

        // Use batchDU with pkg → dir pairs.
        // We can't use batchDU directly (it uses last path component as key),
        // so we use the echo-prefix trick: output "PKG KB" per line.
        let entries = Array(dirMap)
        let batchSize = 20
        for batchStart in stride(from: 0, to: entries.count, by: batchSize) {
            let batch = Array(entries[batchStart..<min(batchStart + batchSize, entries.count)])
            // "echo PKG $(du -sk DIR 2>/dev/null | cut -f1)"
            let cmds = batch.map { (pkg, dir) in
                "echo \"\(pkg) $(timeout 5 du -sk '\(dir)' 2>/dev/null | cut -f1 || echo 0)\""
            }.joined(separator: "; ")

            let (_, out, _) = await Shell.runAsync(adbPath,
                args: ADBManager.deviceArgs(["shell", cmds]))

            for line in out.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                              .split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2, let kb = Int64(parts[1]), kb > 0 else { continue }
                result[String(parts[0])] = kb * 1024  // KB → bytes
            }
        }
        return result
    }

    // du -sk only the packages that actually have a directory, in batches of 20
    // Uses `timeout 8` per batch to prevent hanging on large dirs.
    private func batchDU(packages: [String], basePath: String, adbPath: String) async -> [String: Int64] {
        guard !packages.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        let batchSize = 20
        for batchStart in stride(from: 0, to: packages.count, by: batchSize) {
            let batch = Array(packages[batchStart..<min(batchStart + batchSize, packages.count)])
            // Build: timeout 8 du -sk /path/pkg1 /path/pkg2 ... 2>/dev/null
            let paths = batch.map { "\(basePath)/\($0)" }.joined(separator: " ")
            let cmd = "timeout 8 du -sk \(paths) 2>/dev/null"
            let (_, out, _) = await Shell.runAsync(adbPath,
                args: ADBManager.deviceArgs(["shell", cmd]))
            // Output: "1234\t/storage/.../Android/data/com.example.app"
            for line in out.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                              .split(separator: "\t", omittingEmptySubsequences: true)
                guard parts.count == 2,
                      let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                let pkg = (String(parts[1]) as NSString).lastPathComponent
                result[pkg] = kb * 1024  // KB → bytes
            }
        }
        return result
    }

    private func pmArgs(for filter: AppFilter) -> [String] {
        switch filter {
        case .all:      return ["shell", "pm", "list", "packages", "-u"]
        case .user:     return ["shell", "pm", "list", "packages", "-3"]
        case .system:   return ["shell", "pm", "list", "packages", "-s", "-u"]
        case .disabled: return ["shell", "pm", "list", "packages", "-u"] // Will be filtered in code
        }
    }

    /// Fetches apps from the device using `pm list packages`.
    /// Fast path: parallel ADB calls, no per-app round trips.
    func fetchApps(filter: AppFilter) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            apps = []
            statusMessage = "Loading apps..."
        }

        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            await setError("ADB not found. Please reconnect your device.")
            return
        }

        // Run queries in parallel to get full state
        async let mainFetch = Shell.runAsync(adbPath, args: ADBManager.deviceArgs(pmArgs(for: filter)))
        async let sysFetch  = Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "pm", "list", "packages", "-s", "-u"]))
        async let allFetch  = Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "pm", "list", "packages"])) // only installed/enabled
        async let allUFetch = Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "pm", "list", "packages", "-u"])) // everything
        async let disFetch  = Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "pm", "list", "packages", "-d"])) // explicitly disabled

        let (_, mainOut, _) = await mainFetch
        let (_, sysOut,  _) = await sysFetch
        let (_, allOut,  _) = await allFetch
        let (_, allUOut, _) = await allUFetch
        let (_, disOut,  _) = await disFetch

        let systemPackages = parsePackageList(sysOut)
        let installedPackages = parsePackageList(allOut)
        let allPossiblePackages = parsePackageList(allUOut)
        
        // "Disabled" = explicitly disabled (-d) OR uninstalled for user (in -u but not in normal list)
        var disabledPackages = parsePackageList(disOut)
        let uninstalledForUser = allPossiblePackages.subtracting(installedPackages)
        disabledPackages.formUnion(uninstalledForUser)

        var packageNames = parsePackageList(mainOut)

        if filter == .disabled {
            packageNames = disabledPackages
        }

        guard !packageNames.isEmpty else {
            await MainActor.run {
                self.isLoading = false
                self.statusMessage = "No apps found."
            }
            return
        }

        let result: [AppInfo] = packageNames.sorted().map { pkg in
            let isSystem: Bool
            switch filter {
            case .system:   isSystem = true
            case .user:     isSystem = false
            case .all:      isSystem = systemPackages.contains(pkg)
            case .disabled: isSystem = systemPackages.contains(pkg)
            }
            return AppInfo(
                id: pkg,
                packageName: pkg,
                displayName: AppInfo.labelFrom(package: pkg),
                versionName: "",
                isSystemApp: isSystem,
                isEnabled: !disabledPackages.contains(pkg)
            )
        }

        await MainActor.run {
            self.apps = result
            self.isLoading = false
            self.statusMessage = "\(result.count) apps"
        }

        // Fetch real labels + icons in the background (non-blocking)
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchRealLabels(adbPath: adbPath)
            await self?.fetchIcons(adbPath: adbPath)
        }
    }

    // MARK: - Real App Labels

    /// Published icon cache keyed by package name.
    @Published var appIcons: [String: NSImage] = [:]

    /// Fetches real human-readable labels using `pm dump <pkg>`.
    /// `nonLocalizedLabel` is null at application level for most apps (uses resource IDs),
    /// but is often set at activity level. We scan all nonLocalizedLabel occurrences and
    /// take the first non-null, non-hex one.
    private func fetchRealLabels(adbPath: String) async {
        let packages = await MainActor.run { apps.map(\.packageName) }
        guard !packages.isEmpty else { return }

        var labelMap: [String: String] = [:]
        let chunkSize = 15  // smaller chunks = more reliable shell output

        for chunk in stride(from: 0, to: packages.count, by: chunkSize)
            .map({ Array(packages[$0..<min($0 + chunkSize, packages.count)]) }) {

            // Emit "PKG_START:<pkg>" before each dump so we can parse boundaries.
            // grep nonLocalizedLabel — activity-level entries often have real strings.
            let script = chunk.map { pkg in
                "echo PKG_START:\(pkg); pm dump \(pkg) 2>/dev/null | grep nonLocalizedLabel | grep -v 'null' | head -2"
            }.joined(separator: "; ")

            let (_, output, _) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["shell", script])
            )

            var currentPkg = ""
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.hasPrefix("PKG_START:") {
                    currentPkg = String(trimmed.dropFirst("PKG_START:".count))
                    continue
                }

                guard !currentPkg.isEmpty, labelMap[currentPkg] == nil else { continue }

                // Line looks like: "      nonLocalizedLabel=Adobe Scan"
                if let eqRange = trimmed.range(of: "nonLocalizedLabel=") {
                    let value = String(trimmed[eqRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip resource IDs (0x...) and "null"
                    if !value.isEmpty && !value.hasPrefix("0x") && value.lowercased() != "null" {
                        labelMap[currentPkg] = value
                    }
                }
            }
        }

        // For packages still missing a label, apply smart derivation from package name
        for pkg in packages where labelMap[pkg] == nil {
            labelMap[pkg] = AppInfo.smartLabel(from: pkg)
        }

        await MainActor.run {
            self.apps = self.apps.map { app in
                if let label = labelMap[app.packageName], !label.isEmpty,
                   label != AppInfo.labelFrom(package: app.packageName) || true {
                    return AppInfo(id: app.id, packageName: app.packageName,
                                  displayName: label, versionName: app.versionName,
                                  isSystemApp: app.isSystemApp, isEnabled: app.isEnabled)
                }
                return app
            }
        }
    }

    // MARK: - App Icon Fetching

    /// Fetches the launcher icon for each loaded app.
    /// Uses a per-package `pm path <pkg>` call (emitted as `pkg=path` pairs)
    /// so failed lookups don't corrupt the mapping for subsequent packages.
    /// Extracts best PNG icon via base64 piping over ADB.
    func fetchIcons(adbPath: String, maxIcons: Int = 120) async {
        let packages = await MainActor.run { apps.map(\.packageName) }
        guard !packages.isEmpty else { return }

        // ── Step 1: Get APK paths. Emit as "pkg=path" lines so we can parse reliably ──
        let chunkSize = 20
        var apkPaths: [String: String] = [:]

        for chunk in stride(from: 0, to: min(packages.count, maxIcons), by: chunkSize)
            .map({ Array(packages[$0..<min($0 + chunkSize, min(packages.count, maxIcons))]) }) {

            // Each "pm path <pkg>" prints "package:/path/to/base.apk" or nothing.
            // Split APKs print multiple lines. We only want base.apk (or the first one if base is missing).
            let script = chunk.map { pkg in
                "apk=$(pm path \(pkg) 2>/dev/null | grep base.apk | head -n 1 | sed 's/package://'); if [ -z \"$apk\" ]; then apk=$(pm path \(pkg) 2>/dev/null | head -n 1 | sed 's/package://'); fi; echo \"\(pkg)=$apk\""
            }.joined(separator: "; ")

            let (_, output, _) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["shell", script])
            )

            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // Format: "com.example.app=/data/app/.../base.apk"
                // The package name is everything before the FIRST "="
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    let pkg = String(trimmed[..<eqIdx])
                    let path = String(trimmed[trimmed.index(after: eqIdx)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !pkg.isEmpty && !path.isEmpty {
                        apkPaths[pkg] = path
                    }
                }
            }
        }

        // ── Step 2: For each APK, find best icon PNG and pull it via base64 ──
        let alreadyCached = await MainActor.run { Set(appIcons.keys) }

        for (pkg, apkPath) in apkPaths where !alreadyCached.contains(pkg) {
            guard !apkPath.isEmpty else { continue }

            // List zip contents, grep for common launcher icon names
            let zipCmd = "unzip -l '\(apkPath)' 2>/dev/null | grep -i 'ic_launcher' | grep '\\.png' | grep -v night"
            let (_, zipList, _) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["shell", zipCmd])
            )

            // Prefer higher-density icons
            let densityOrder = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "drawable"]
            var bestIconPath: String?
            var bestScore = Int.max

            for line in zipList.components(separatedBy: .newlines) {
                let cols = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let iconPath = cols.last, iconPath.hasSuffix(".png") else { continue }
                let score = densityOrder.firstIndex(where: { iconPath.contains($0) }) ?? densityOrder.count
                if score < bestScore { bestScore = score; bestIconPath = iconPath }
            }

            // If no PNG found, try adaptive icon foreground (some apps only have vector + adaptive)
            if bestIconPath == nil {
                let adaptCmd = "unzip -l '\(apkPath)' 2>/dev/null | grep -i 'ic_launcher' | grep '\\.png' | head -1"
                let (_, adaptOut, _) = await Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", adaptCmd]))
                bestIconPath = adaptOut.components(separatedBy: .newlines).first(where: { $0.contains(".png") })
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).last }
            }

            guard let iconPath = bestIconPath, !iconPath.isEmpty else { continue }

            // Pull icon as base64 to safely transfer binary over ADB shell
            let b64Cmd = "unzip -p '\(apkPath)' '\(iconPath)' 2>/dev/null | base64"
            let (_, b64Out, _) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["shell", b64Cmd])
            )

            let cleaned = b64Out.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined()
            guard !cleaned.isEmpty,
                  let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
                  data.count > 100,  // sanity check: real PNGs are at least 100 bytes
                  let image = NSImage(data: data)
            else { continue }

            await MainActor.run { self.appIcons[pkg] = image }
        }
    }



    // MARK: - Uninstall
    
    /// Uninstall a user-installed app completely.
    func uninstall(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["uninstall", package])
        )
        let success = output.contains("Success")
        return (success, success ? "Uninstalled successfully." : output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Disable a system app for the current user (does not require root).
    /// The app is hidden/removed from launcher but not deleted from the system partition.
    func disableSystemApp(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "pm", "uninstall", "-k", "--user", "0", package])
        )
        let success = output.trimmingCharacters(in: .whitespacesAndNewlines) == "Success"
        return (success, success ? "App disabled for current user." : output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Re-enable a previously disabled system app.
    func enableApp(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "pm", "install-existing", package])
        )
        let success = output.lowercased().contains("success") || output.lowercased().contains("installed")
        return (success, success ? "App re-enabled." : output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - APK Backup

    /// Extracts the APK of a given package from the device and saves it to a Mac folder.
    func backupAPK(package: String, displayName: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()

        // Step 1: Get the APK path on device
        let (_, pathOut, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "pm", "path", package])
        )
        // Output: "package:/data/app/....apk"
        guard let apkDevicePath = pathOut
            .components(separatedBy: "package:")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apkDevicePath.isEmpty else {
            return (false, "Could not find APK path on device.")
        }

        // Step 2: Ask user where to save
        let panel = NSSavePanel()
        panel.title = "Save APK Backup"
        panel.nameFieldStringValue = "\(displayName).apk"
        panel.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]

        guard await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) == .OK,
              let saveURL = panel.url else {
            return (false, "Backup cancelled.")
        }

        // Step 3: Pull the file
        let (_, pullOut, pullErr) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["pull", apkDevicePath, saveURL.path])
        )
        let success = pullOut.contains("pulled") || pullErr.isEmpty
        return (success, success ? "APK saved to \(saveURL.lastPathComponent)" : pullErr)
    }

    // MARK: - Install APK

    /// Install an APK from the Mac onto the device.
    func installAPK(from url: URL) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (_, output, err) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["install", "-r", url.path])
        )
        let success = output.contains("Success")
        return (success, success ? "Installed successfully." : (err.isEmpty ? output : err))
    }

    // MARK: - Clear App Data

    /// Clears all app data AND cache (equivalent to Settings → App Info → Clear Data).
    func clearData(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "pm", "clear", package])
        )
        let success = output.trimmingCharacters(in: .whitespacesAndNewlines) == "Success"
        return (success, success ? "Data & cache cleared." : output)
    }

    /// Clears only the external cache directory (no root required).
    /// Note: internal cache (/data/data/<pkg>/cache) requires root to clear individually;
    /// use clearData() to wipe everything including internal cache.
    func clearCache(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        // External cache is accessible without root
        let extCache = "/storage/emulated/0/Android/data/\(package)/cache"
        let (_, out, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "rm", "-rf", extCache])
        )
        // rm -rf has no output on success
        let hadError = out.lowercased().contains("permission denied") || out.lowercased().contains("error")
        if hadError {
            return (false, "Could not clear cache: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (true, "External cache cleared.")
    }

    // MARK: - Force Stop

    func forceStop(package: String) async -> (Bool, String) {
        let adbPath = ADBManager.getADBPath()
        let (code, _, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "am", "force-stop", package])
        )
        return (code == 0, code == 0 ? "App stopped." : "Failed to stop app.")
    }

    // MARK: - Batch Uninstall

    func batchUninstall(packages: [String]) async -> [String: Bool] {
        var results: [String: Bool] = [:]
        for pkg in packages {
            let (success, _) = await uninstall(package: pkg)
            results[pkg] = success
        }
        return results
    }

    // MARK: - Helpers

    private func parsePackageList(_ output: String) -> Set<String> {
        var result = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("package:") {
                let pkg = String(trimmed.dropFirst("package:".count))
                if !pkg.isEmpty { result.insert(pkg) }
            }
        }
        return result
    }



    private func setError(_ msg: String) async {
        await MainActor.run {
            self.isLoading = false
            self.errorMessage = msg
            self.statusMessage = ""
        }
    }
}
