//
//  ReportIssuePopoverView.swift
//  AndroidFileSync
//

import SwiftUI
import AppKit

struct ReportIssuePopoverView: View {
    @ObservedObject var diagnosticsControl: DiagnosticsControl

    private let githubIssueURL = URL(string: "https://github.com/Santosh7017/AndroidFileSync/issues/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                Text("Report an Issue")
                    .font(.headline)
            }

            Divider()

            // Logging toggle
            Toggle(isOn: Binding(
                get: { diagnosticsControl.isEnabled },
                set: { diagnosticsControl.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Logging")
                        .font(.subheadline.weight(.medium))
                    Text("Collect diagnostic logs to help troubleshoot issues. No private data is collected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            // View Logs button (only when logging enabled)
            if diagnosticsControl.isEnabled {
                Button {
                    if let url = AppLogger.logFileURL {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    }
                } label: {
                    Label("View Logs in Finder", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }

            Divider()

            // Report Issue button
            Button {
                NSWorkspace.shared.open(githubIssueURL)
            } label: {
                HStack {
                    Spacer()
                    Label("Report Issue on GitHub", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(16)
        .frame(width: 280)
    }
}
