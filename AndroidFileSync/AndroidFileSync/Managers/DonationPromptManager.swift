import Foundation
import AppKit
internal import Combine

/// Manages a gentle, non-intrusive donation prompt for PayPal.
///
/// Rules:
/// - Waits until the user has used the app for at least 5 sessions AND 7 days.
/// - After first eligible trigger, waits 90 seconds of active use before showing.
/// - If snoozed ("Not Now"), waits 14 days before asking again.
/// - Once the user clicks "Donate" (or "Already Donated"), it is marked done and never shown again.
@MainActor
final class DonationPromptManager: ObservableObject {
    static let shared = DonationPromptManager()

    @Published var shouldShowPrompt = false

    // MARK: - UserDefaults Keys

    private let firstUseDateKey      = "donationPromptFirstUseDate"
    private let sessionCountKey      = "donationPromptSessionCount"
    private let lastPromptDateKey    = "donationPromptLastPromptDate"
    private let completedKey         = "donationPromptCompleted"

    // MARK: - Configuration

    let paypalURL = URL(string: "https://paypal.me/santosh7017")!

    /// Minimum number of app-launch sessions before eligibility.
    private let minimumSessionCount = 5
    /// Minimum days since first use before eligibility.
    private let minimumDaysSinceFirstUse = 7
    /// Delay (seconds) after eligibility check before actually showing the prompt.
    private let promptDelay: TimeInterval = 90
    /// Minimum interval between prompts when snoozed (14 days).
    private let snoozeInterval: TimeInterval = 14 * 24 * 60 * 60

    private var scheduledPromptTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        if UserDefaults.standard.object(forKey: firstUseDateKey) == nil {
            UserDefaults.standard.set(Date(), forKey: firstUseDateKey)
        }
        incrementSession()
        schedulePromptIfEligible()
    }

    // MARK: - Actions

    /// User clicked "Donate" — open PayPal and mark done forever.
    func openPayPalAndMarkDone() {
        UserDefaults.standard.set(true, forKey: completedKey)
        shouldShowPrompt = false
        NSWorkspace.shared.open(paypalURL)
    }

    /// User clicked "Not Now" — snooze for 14 days.
    func snooze() {
        UserDefaults.standard.set(Date(), forKey: lastPromptDateKey)
        shouldShowPrompt = false
    }

    // MARK: - Eligibility

    private var isEligibleForPrompt: Bool {
        // Already donated → never show again
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return false }
        // Already showing
        guard !shouldShowPrompt else { return false }

        // Enough sessions?
        let sessions = UserDefaults.standard.integer(forKey: sessionCountKey)
        guard sessions >= minimumSessionCount else { return false }

        // Enough days since first use?
        if let firstUse = UserDefaults.standard.object(forKey: firstUseDateKey) as? Date {
            let daysSinceFirstUse = Calendar.current.dateComponents([.day], from: firstUse, to: Date()).day ?? 0
            guard daysSinceFirstUse >= minimumDaysSinceFirstUse else { return false }
        }

        // Snoozed recently?
        if let lastPrompt = UserDefaults.standard.object(forKey: lastPromptDateKey) as? Date,
           Date().timeIntervalSince(lastPrompt) < snoozeInterval {
            return false
        }

        return true
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

    private func incrementSession() {
        let current = UserDefaults.standard.integer(forKey: sessionCountKey)
        UserDefaults.standard.set(current + 1, forKey: sessionCountKey)
    }


}

