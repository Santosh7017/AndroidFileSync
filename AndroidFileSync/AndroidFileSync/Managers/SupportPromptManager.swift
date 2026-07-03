import Foundation
import AppKit
internal import Combine

@MainActor
final class SupportPromptManager: ObservableObject {
    static let shared = SupportPromptManager()

    @Published var shouldShowPrompt = false

    private let firstUseDateKey = "supportPromptFirstUseDate"
    private let sessionCountKey = "supportPromptSessionCount"
    private let successfulBatchCountKey = "supportPromptSuccessfulBatchCount"
    private let lastPromptDateKey = "supportPromptLastPromptDate"
    private let feedbackSnoozedUntilSessionKey = "supportPromptFeedbackSnoozedUntilSession"
    private let completedKey = "supportPromptCompleted"

    private let repoURL = URL(string: "https://github.com/Santosh7017/AndroidFileSync")!
    private let feedbackURL = URL(string: "https://github.com/Santosh7017/AndroidFileSync/issues/new")!

    private let promptDelay: TimeInterval = 60
    private let snoozeInterval: TimeInterval = 7 * 24 * 60 * 60
    private let feedbackSnoozeSessions = 10
    // Do not ask on first-use behavior; wait for repeated real usage.
    private let minimumBatchCount = 3
    private let minimumSessionCount = 3
    private var scheduledPromptTask: Task<Void, Never>?

    private init() {
        if UserDefaults.standard.object(forKey: firstUseDateKey) == nil {
            UserDefaults.standard.set(Date(), forKey: firstUseDateKey)
        }
        incrementInteger(forKey: sessionCountKey)
        schedulePromptIfEligible()
    }

    func recordSuccessfulBatch() {
        let current = UserDefaults.standard.integer(forKey: successfulBatchCountKey)
        UserDefaults.standard.set(current + 1, forKey: successfulBatchCountKey)
        schedulePromptIfEligible()
    }

    func openGitHubAndMarkDone() {
        UserDefaults.standard.set(true, forKey: completedKey)
        shouldShowPrompt = false
        NSWorkspace.shared.open(repoURL)
    }

    func openFeedbackAndSnooze() {
        let currentSessions = UserDefaults.standard.integer(forKey: sessionCountKey)
        UserDefaults.standard.set(currentSessions + feedbackSnoozeSessions, forKey: feedbackSnoozedUntilSessionKey)
        shouldShowPrompt = false
        NSWorkspace.shared.open(feedbackURL)
    }

    func snooze() {
        UserDefaults.standard.set(Date(), forKey: lastPromptDateKey)
        shouldShowPrompt = false
    }

    private func schedulePromptIfEligible() {
        guard isEligibleForPrompt else { return }
        guard scheduledPromptTask == nil else { return }

        let delay = promptDelay
        scheduledPromptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.scheduledPromptTask = nil
                guard self.isEligibleForPrompt else { return }
                self.shouldShowPrompt = true
                UserDefaults.standard.set(Date(), forKey: self.lastPromptDateKey)
            }
        }
    }

    private var isEligibleForPrompt: Bool {
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return false }
        guard !shouldShowPrompt else { return false }

        let sessions = UserDefaults.standard.integer(forKey: sessionCountKey)
        let feedbackSnoozedUntilSession = UserDefaults.standard.integer(forKey: feedbackSnoozedUntilSessionKey)
        if sessions < feedbackSnoozedUntilSession {
            return false
        }

        if let lastPrompt = UserDefaults.standard.object(forKey: lastPromptDateKey) as? Date,
           Date().timeIntervalSince(lastPrompt) < snoozeInterval {
            return false
        }

        let batches = UserDefaults.standard.integer(forKey: successfulBatchCountKey)
        return batches >= minimumBatchCount || (sessions >= minimumSessionCount && batches >= 1)
    }

    private func incrementInteger(forKey key: String) {
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(current + 1, forKey: key)
    }
}
