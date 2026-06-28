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
        get { UserDefaults.standard.bool(forKey: "betaChannel") }
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
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    func openReleasePage() {
        guard let url = URL(string: releaseURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
