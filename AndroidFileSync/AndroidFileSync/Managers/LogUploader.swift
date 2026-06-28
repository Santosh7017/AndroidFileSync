//
//  LogUploader.swift
//  AndroidFileSync
//
//  Created for Samsung Camera Fix Diagnostic Log Uploads
//

internal import Combine
import Foundation

class LogUploader: ObservableObject {
    static let shared = LogUploader()

    private let token = ""
    private let owner = "Santosh7017"
    private let repo = "AndroidFileSync"
    private let issueNumber = 11

    @Published var isUploading = false
    @Published var uploadSuccess = false
    @Published var errorMessage: String? = nil

    /// In-memory flag — resets each app launch. Prevents repeated prompts within a session.
    private(set) var hasUploadedThisSession = false

    /// Whether the current build is a beta build.
    /// Checks for `AFSBetaBuild = YES` in Info.plist, or version string containing "beta".
    static var isBetaBuild: Bool {
        // if let betaFlag = Bundle.main.infoDictionary?["AFSBetaBuild"] as? String,
        //    betaFlag.uppercased() == "YES" {
        //     return true
        // }
        // let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        // return version.lowercased().contains("beta")
        return true
    }

    // MARK: - Public API

    func uploadLogs() {
        guard !isUploading else { return }

        isUploading = true
        errorMessage = nil
        uploadSuccess = false

        guard let logURL = AppLogger.logFileURL else {
            isUploading = false
            errorMessage = "Log file URL is nil"
            return
        }

        do {
            let logContent = try String(contentsOf: logURL, encoding: .utf8)
            let trimmedLog = String(logContent.suffix(60000))

            let appVersion =
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
            let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString

            let deviceModel = extractLogValue(from: logContent, label: "Device Model")
            let manufacturer = extractLogValue(from: logContent, label: "Manufacturer")
            let androidVersion = extractLogValue(from: logContent, label: "Android Version")
            let sdkLevel = extractLogValue(from: logContent, label: "SDK Level")
            let connectionType = extractLogValue(from: logContent, label: "Connection")
            let lsCount = extractLogValue(from: logContent, label: "ls file count")
            let mediaStoreCount = extractLogValue(from: logContent, label: "MediaStore total count")

            // Build summary for the issue comment
            let summary = """
                ## 📋 Auto Diagnostic Report

                - **App Version:** \(appVersion) (\(buildNumber))
                - **macOS Version:** \(systemVersion)
                - **Device:** \(manufacturer) \(deviceModel)
                - **Android:** \(androidVersion) (SDK \(sdkLevel))
                - **Connection:** \(connectionType)
                - **Timestamp:** \(Date().description)

                ### Camera Folder Result
                - ls file count: \(lsCount)
                - MediaStore total count: \(mediaStoreCount)
                """

            // Build the full log file content (includes summary header + raw logs)
            let fileContent = """
                =====================================
                AndroidFileSync Diagnostic Report
                =====================================
                App Version: \(appVersion) (\(buildNumber))
                macOS Version: \(systemVersion)
                Device: \(manufacturer) \(deviceModel)
                Android: \(androidVersion) (SDK \(sdkLevel))
                Connection: \(connectionType)
                Timestamp: \(Date().description)

                Camera Folder:
                  ls file count: \(lsCount)
                  MediaStore total count: \(mediaStoreCount)
                =====================================

                \(trimmedLog)
                """

            // Step 1: Upload the log file to the repo
            uploadLogFile(content: fileContent, summary: summary)

        } catch {
            isUploading = false
            errorMessage = "Failed to read log file: \(error.localizedDescription)"
        }
    }

    // MARK: - File Upload (Contents API)

    /// Uploads the log as a file to `diagnostics/` in the repo via the GitHub Contents API,
    /// then posts a summary comment with a link to the file.
    private func uploadLogFile(content: String, summary: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = dateFormatter.string(from: Date())
        let filename = "diagnostic_\(timestamp).log"
        let filePath = "diagnostics/\(filename)"

        let contentsURL = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(filePath)"
        guard let url = URL(string: contentsURL) else {
            isUploading = false
            errorMessage = "Invalid file upload URL"
            return
        }

        // Base64-encode the file content (required by GitHub Contents API)
        let base64Content = Data(content.utf8).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyGitHubHeaders(to: &request)

        let body: [String: Any] = [
            "message": "📋 Diagnostic report: \(filename)",
            "content": base64Content,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            isUploading = false
            errorMessage = "Failed to serialize file upload body"
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                // Network error — fall back to inline comment
                AppLogger.log(
                    "⚠️ [LogUploader] File upload network error: \(error.localizedDescription), falling back to inline",
                    level: .warning)
                self.postInlineComment(summary: summary, logContent: content)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 201, let data = data {
                // File created successfully — extract the download URL
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let contentObj = json["content"] as? [String: Any],
                    let downloadURL = contentObj["download_url"] as? String,
                    let htmlURL = contentObj["html_url"] as? String
                {

                    AppLogger.log("✅ [LogUploader] Log file uploaded: \(htmlURL)", level: .info)

                    // Post a clean summary comment with the file link
                    let commentBody = """
                        \(summary)

                        ### 📎 Log File
                        [⬇️ Download \(filename)](\(downloadURL))

                        [View on GitHub](\(htmlURL))
                        """
                    self.postComment(markdown: commentBody)
                } else {
                    // File created but couldn't parse response — post comment with raw link
                    let rawURL =
                        "https://github.com/\(self.owner)/\(self.repo)/blob/main/\(filePath)"
                    let commentBody = """
                        \(summary)

                        ### 📎 Log File
                        [View log file](\(rawURL))
                        """
                    self.postComment(markdown: commentBody)
                }
            } else {
                // File upload failed (likely missing Contents:write permission) — fall back
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLogger.log(
                    "⚠️ [LogUploader] File upload failed (HTTP \(statusCode)): \(responseBody). Falling back to inline.",
                    level: .warning)
                self.postInlineComment(summary: summary, logContent: content)
            }
        }.resume()
    }

    // MARK: - Fallback: Inline Comment with Collapsed Log

    /// Posts the full log inline as a collapsed `<details>` section.
    /// Used when the file upload fails (e.g., token lacks Contents:write).
    private func postInlineComment(summary: String, logContent: String) {
        let commentBody = """
            \(summary)

            <details>
            <summary>📎 Click to expand full diagnostic log</summary>

            ```text
            \(logContent)
            ```

            </details>
            """
        postComment(markdown: commentBody)
    }

    // MARK: - Issue Comment

    private func postComment(markdown: String) {
        let issueCommentsURL =
            "https://api.github.com/repos/\(owner)/\(repo)/issues/\(issueNumber)/comments"
        guard let url = URL(string: issueCommentsURL) else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.errorMessage = "Invalid endpoint URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyGitHubHeaders(to: &request)

        let body: [String: Any] = ["body": markdown]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            DispatchQueue.main.async {
                self.isUploading = false
                self.errorMessage =
                    "Failed to serialize request body: \(error.localizedDescription)"
            }
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            DispatchQueue.main.async {
                self.isUploading = false
                if statusCode == 201 {
                    self.uploadSuccess = true
                    self.hasUploadedThisSession = true
                    AppLogger.log(
                        "✅ [LogUploader] Diagnostic report posted to issue #\(self.issueNumber)",
                        level: .info)
                } else {
                    let errorMsg: String
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        errorMsg = "HTTP \(statusCode): \(responseString)"
                    } else {
                        errorMsg = "HTTP \(statusCode)"
                    }
                    self.errorMessage = errorMsg
                    AppLogger.log("❌ [LogUploader] Comment post failed: \(errorMsg)", level: .error)
                }
            }
        }.resume()
    }

    // MARK: - Helpers

    private func applyGitHubHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AndroidFileSync-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    /// Extracts a diagnostic value from log content.
    /// Looks for lines like `[DIAG] Device Model: Samsung SM-S928B`
    private func extractLogValue(from logContent: String, label: String) -> String {
        for line in logContent.components(separatedBy: .newlines).reversed() {
            if line.contains(label) {
                if let range = line.range(of: "\(label):") {
                    let value = String(line[range.upperBound...]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !value.isEmpty && value != "(empty)" { return value }
                }
                if let lastColon = line.lastIndex(of: ":") {
                    let afterColon = String(line[line.index(after: lastColon)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if afterColon.contains(label) {
                        if let labelRange = afterColon.range(of: label) {
                            let remainder = String(afterColon[labelRange.upperBound...])
                                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                            if !remainder.isEmpty && remainder != "(empty)" { return remainder }
                        }
                    }
                }
            }
        }
        return "Unknown"
    }
}
