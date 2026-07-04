import Foundation
import AppKit
internal import Combine

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseURL = ""
    @Published var releaseNotes = ""
    @Published var isPreRelease = false
    @Published var dmgURL = ""
    @Published var isUpdating = false
    @Published var updateStatusMessage = ""
    @Published var updateCompleted = false

    var isHomebrewInstall: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/opt/homebrew/Caskroom/androidfilesync") ||
               fm.fileExists(atPath: "/usr/local/Caskroom/androidfilesync")
    }

    var isBetaChannel: Bool {
        get {
            if UserDefaults.standard.object(forKey: "betaChannel") == nil {
                return currentVersion.lowercased().contains("-beta")
            }
            return UserDefaults.standard.bool(forKey: "betaChannel")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "betaChannel")
            objectWillChange.send()
        }
    }

    var shouldShowBanner: Bool {
        guard updateAvailable else { return false }
        if let dismissedDate = UserDefaults.standard.object(forKey: "updateDismissedDate") as? Date {
            return !Calendar.current.isDateInToday(dismissedDate)
        }
        return true
    }

    func dismissForToday() {
        UserDefaults.standard.set(Date(), forKey: "updateDismissedDate")
        objectWillChange.send()
    }

    private let repoOwner = "Santosh7017"
    private let repoName = "AndroidFileSync"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        if isBetaChannel {
            checkBetaChannel()
        } else {
            checkStableChannel()
        }
    }

    private func checkStableChannel() {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        fetchRelease(from: urlString, pickFirst: false)
    }

    private func checkBetaChannel() {
        // /releases returns ALL releases including pre-releases, sorted newest first
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=10"
        fetchRelease(from: urlString, pickFirst: true)
    }

    private func fetchRelease(from urlString: String, pickFirst: Bool) {
        guard let url = URL(string: urlString) else { return }

        let channel = isBetaChannel ? "beta" : "stable"
        print("🔄 Update check [\(channel)]: fetching \(urlString)")
        print("🔄 Current app version: \(currentVersion)")

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error = error {
                print("🔄 Update check failed: \(error.localizedDescription)")
                return
            }

            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("🔄 GitHub API response: HTTP \(httpCode)")

            if httpCode == 404 {
                print("🔄 No GitHub releases found.")
                return
            }

            guard let data else { return }

            // Beta: array of releases. Stable: single release object.
            let releaseJSON: [String: Any]?
            if pickFirst {
                let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
                releaseJSON = releases?.first
            } else {
                releaseJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

            guard let json = releaseJSON,
                  let tagName = json["tag_name"] as? String else {
                print("🔄 Failed to parse release data")
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let htmlURL = json["html_url"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            let preRelease = json["prerelease"] as? Bool ?? false
            
            var foundDmgURL = ""
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                       let downloadURL = asset["browser_download_url"] as? String {
                        foundDmgURL = downloadURL
                        break
                    }
                }
            }

            let hasUpdate = self.isNewer(remote: remoteVersion, current: self.currentVersion)
            print("🔄 Latest release: v\(remoteVersion) | Pre-release: \(preRelease) | Current: v\(self.currentVersion) | Update available: \(hasUpdate) | DMG URL: \(foundDmgURL)")

            DispatchQueue.main.async {
                self.latestVersion = remoteVersion
                self.releaseURL = htmlURL
                self.releaseNotes = body
                self.isPreRelease = preRelease
                self.dmgURL = foundDmgURL
                self.updateAvailable = hasUpdate
            }
        }.resume()
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let cleanRemote = remote.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let cleanCurrent = current.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        
        if cleanRemote == cleanCurrent { return false }
        
        let rComponents = cleanRemote.components(separatedBy: "-")
        let cComponents = cleanCurrent.components(separatedBy: "-")
        
        let rVersion = rComponents[0]
        let cVersion = cComponents[0]
        
        let versionComparison = rVersion.compare(cVersion, options: .numeric)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }
        
        // A release with NO suffix is newer than a release WITH a suffix (e.g. 2.3.1 > 2.3.1-beta)
        if rComponents.count == 1 && cComponents.count > 1 {
            return true
        }
        if rComponents.count > 1 && cComponents.count == 1 {
            return false
        }
        
        // If both have suffixes, compare them numerically (e.g. "beta.2" vs "beta.1")
        if rComponents.count > 1 && cComponents.count > 1 {
            return rComponents[1].compare(cComponents[1], options: .numeric) == .orderedDescending
        }
        
        return false
    }

    func openReleasePage() {
        guard let url = URL(string: releaseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func performAutoUpdate() {
        guard !isUpdating else { return }
        
        isUpdating = true
        updateStatusMessage = "Starting update..."
        
        if isHomebrewInstall {
            performHomebrewUpgrade()
        } else if !dmgURL.isEmpty {
            performDMGAutoUpdate()
        } else {
            openReleasePage()
            isUpdating = false
        }
    }

    private func performHomebrewUpgrade() {
        Task {
            await MainActor.run {
                self.updateStatusMessage = "Upgrading via Homebrew..."
            }
            
            let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                ? "/opt/homebrew/bin/brew"
                : "/usr/local/bin/brew"
            
            let (code, output, error) = await Shell.runAsync(brewPath, args: ["upgrade", "androidfilesync"])
            
            await MainActor.run {
                if code == 0 || output.contains("already installed") || error.contains("already installed") {
                    self.promptForRestart()
                } else {
                    print("⚠️ Homebrew upgrade failed: \(error)")
                    self.openReleasePage()
                    self.isUpdating = false
                }
            }
        }
    }

    private func performDMGAutoUpdate() {
        guard let url = URL(string: dmgURL) else {
            openReleasePage()
            isUpdating = false
            return
        }
        
        Task {
            await MainActor.run {
                self.updateStatusMessage = "Downloading DMG update..."
            }
            
            do {
                let (tempLocation, _) = try await URLSession.shared.download(from: url)
                let targetDMG = NSTemporaryDirectory() + "AndroidFileSync_Update.dmg"
                try? FileManager.default.removeItem(atPath: targetDMG)
                try FileManager.default.moveItem(at: tempLocation, to: URL(fileURLWithPath: targetDMG))
                
                await MainActor.run {
                    self.updateStatusMessage = "Mounting & Installing..."
                }
                
                let mountPoint = "/Volumes/AndroidFileSync_Update_Mount"
                _ = await Shell.runAsync("/usr/bin/hdiutil", args: ["detach", mountPoint, "-force"])
                
                let (attachCode, _, _) = await Shell.runAsync("/usr/bin/hdiutil", args: ["attach", targetDMG, "-mountpoint", mountPoint, "-nobrowse", "-quiet"])
                
                if attachCode == 0 {
                    let sourceApp = mountPoint + "/AndroidFileSync.app"
                    let targetApp = Bundle.main.bundlePath
                    
                    if FileManager.default.fileExists(atPath: sourceApp) {
                        let (copyCode, _, _) = await Shell.runAsync("/usr/bin/ditto", args: [sourceApp, targetApp])
                        _ = await Shell.runAsync("/usr/bin/hdiutil", args: ["detach", mountPoint, "-force"])
                        try? FileManager.default.removeItem(atPath: targetDMG)
                        
                        if copyCode == 0 {
                            await MainActor.run {
                                self.promptForRestart()
                            }
                            return
                        }
                    }
                    _ = await Shell.runAsync("/usr/bin/hdiutil", args: ["detach", mountPoint, "-force"])
                }
                
                await MainActor.run {
                    NSWorkspace.shared.open(URL(fileURLWithPath: targetDMG))
                    self.isUpdating = false
                }
            } catch {
                await MainActor.run {
                    print("⚠️ DMG update failed: \(error.localizedDescription)")
                    self.openReleasePage()
                    self.isUpdating = false
                }
            }
        }
    }

    @Published var updateReadyToRestart = false

    @MainActor
    func promptForRestart() {
        self.isUpdating = false
        self.updateCompleted = true
        self.updateReadyToRestart = true
        self.updateStatusMessage = "v\(latestVersion) ready — restart to apply"
        
        let alert = NSAlert()
        alert.messageText = "Update Installed Successfully"
        alert.informativeText = "AndroidFileSync v\(latestVersion) has been installed.\n\nThe application needs to restart to apply the update.\n\nWould you like to restart now, or wait until your work is done?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Restart Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            self.relaunchApp()
        }
    }

    func relaunchApp() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", appPath]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
