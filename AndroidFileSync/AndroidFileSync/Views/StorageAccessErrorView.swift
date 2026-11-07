import SwiftUI

struct StorageAccessErrorView: View {
    let message: String
    let canRepair: Bool
    let isRepairing: Bool
    let isLoading: Bool
    let onRepair: () -> Void
    let onRetry: () -> Void
    let onSaveDiagnostics: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(canRepair ? "File access is blocked" : "Couldn't open this folder")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            if canRepair {
                Text("Fix storage access allows shared file access through Android debugging, including other debugging apps you use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                if canRepair {
                    Button(action: onRepair) {
                        HStack {
                            if isRepairing { ProgressView().controlSize(.small) }
                            Text(isRepairing ? "Fixing file access…" : "Fix storage access")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(isLoading ? "Checking files…" : "Try again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .disabled(isRepairing || isLoading)
            Button("Save diagnostics…", action: onSaveDiagnostics)
                .buttonStyle(.link)
                .disabled(isRepairing || isLoading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
