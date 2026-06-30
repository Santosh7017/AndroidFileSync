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

            let hasUpdate = self.isNewer(remote: remoteVersion, current: self.currentVersion)
            print("🔄 Latest release: v\(remoteVersion) | Pre-release: \(preRelease) | Current: v\(self.currentVersion) | Update available: \(hasUpdate)")

            DispatchQueue.main.async {
                self.latestVersion = remoteVersion
                self.releaseURL = htmlURL
                self.releaseNotes = body
                self.isPreRelease = preRelease
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
}
