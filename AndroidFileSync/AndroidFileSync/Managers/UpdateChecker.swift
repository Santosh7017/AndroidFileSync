import Foundation
import AppKit
internal import Combine

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseURL = ""
    @Published var releaseNotes = ""
    
    /// True when an update exists AND the user hasn't dismissed it today
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
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        
        print("🔄 Update check: fetching \(urlString)")
        print("🔄 Current app version: \(currentVersion)")
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("🔄 Update check failed: \(error.localizedDescription)")
                return
            }
            
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("🔄 GitHub API response: HTTP \(httpCode)")
            
            if httpCode == 404 {
                print("🔄 No GitHub releases found. Create one at: https://github.com/\(self.repoOwner)/\(self.repoName)/releases/new")
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                print("🔄 Failed to parse release data")
                return
            }
            
            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let htmlURL = json["html_url"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            
            let hasUpdate = self.isNewer(remote: remoteVersion, current: self.currentVersion)
            print("🔄 Latest release: v\(remoteVersion) | Current: v\(self.currentVersion) | Update available: \(hasUpdate)")
            
            DispatchQueue.main.async {
                self.latestVersion = remoteVersion
                self.releaseURL = htmlURL
                self.releaseNotes = body
                self.updateAvailable = hasUpdate
            }
        }.resume()
    }
    
    /// Compares semantic versions. Returns true if remote > current.
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
