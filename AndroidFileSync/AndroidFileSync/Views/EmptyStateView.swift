//
//  EmptyStateView.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import SwiftUI

struct EmptyStateView: View {
    var isDetecting: Bool = false
    var customMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    var onConnectWiFi: (() -> Void)? = nil

    // USB Claim props
    var isUSBOccupied: Bool = false
    var isClaimingUSB: Bool = false
    var onClaimUSB: (() -> Void)? = nil

    // Diagnostics
    var diagnosticsControl: DiagnosticsControl? = nil

    var body: some View {
        VStack(spacing: 24) {
            // USB Occupied Warning Banner — shown at the top of the homepage
            if isUSBOccupied {
                usbOccupiedWarningBanner
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }

            // Icon with animation
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                if isDetecting {
                    ProgressView()
                        .scaleEffect(1.5)
                } else {
                    Image(systemName: customMessage != nil ? "lock.shield.fill" : "cable.connector.slash")
                        .font(.system(size: 48))
                        .foregroundColor(customMessage != nil ? .orange : .secondary)
                }
            }
            
            // Status text
            VStack(spacing: 8) {
                Text(isDetecting ? "Scanning for Device..." : (customMessage != nil ? "Connection Blocked" : "No Device Connected"))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                
                Text(isDetecting ? "Please wait while we detect your device" : (customMessage ?? "Connect your Android device via USB or WiFi"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            // Instructions
            if !isDetecting {
                instructionsList
            }
            
            // Action buttons
            if !isDetecting {
                HStack(spacing: 12) {
                    if let onRetry = onRetry {
                        Button(action: onRetry) {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityLabel("Try Again")
                    }
                    
                    if let onWiFi = onConnectWiFi {
                        Button(action: onWiFi) {
                            Label("Connection Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityLabel("Connection Settings")
                    }
                }
                .padding(.top, 8)
                
                // Auto-retry hint
                Text("The app will automatically retry in a few seconds")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            // Connection Settings + Report Issue section (always visible)
            bottomActionsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("empty_state_view_\(isDetecting)")
    }

    @ViewBuilder
    private var usbOccupiedWarningBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 3) {
                Text("USB Device Occupied")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text("A USB device is connected but claimed by another app (like Android Studio).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 16)
            
            Button(action: { onClaimUSB?() }) {
                HStack(spacing: 6) {
                    if isClaimingUSB {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "cable.connector")
                    }
                    Text(isClaimingUSB ? "Claiming..." : "Claim USB")
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isClaimingUSB ? Color.blue.opacity(0.6) : Color.blue)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isClaimingUSB)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Connection Settings & Report Issue

    @ViewBuilder
    private var bottomActionsSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                // Connection Settings button — only in scanning state
                // (in the not-detecting state, the main action button already shows this)
                if isDetecting, let onWiFi = onConnectWiFi {
                    Button(action: onWiFi) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                                .font(.subheadline)
                            Text("Connection Settings")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open connection settings")
                }

                // Report an Issue button (popover)
                if let diag = diagnosticsControl {
                    reportIssueButton(diagnosticsControl: diag)
                }
            }
        }
    }

    @ViewBuilder
    private func reportIssueButton(diagnosticsControl: DiagnosticsControl) -> some View {
        ReportIssueInlineView(diagnosticsControl: diagnosticsControl)
    }

    private var instructionsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            instructionRow(number: 1, text: "Enable 'USB Debugging' in Developer Options", icon: "ant.fill")
            instructionRow(number: 2, text: "Connect via USB cable and allow debugging on your phone", icon: "cable.connector")
            instructionRow(number: 3, text: "Or use WiFi — enable Wireless Debugging (Android 11+)", icon: "wifi")
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
    
    private func instructionRow(number: Int, text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
            }
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Inline Report Issue View for Empty State

private struct ReportIssueInlineView: View {
    @ObservedObject var diagnosticsControl: DiagnosticsControl
    @State private var showPopover = false

    private let githubIssueURL = URL(string: "https://github.com/Santosh7017/AndroidFileSync/issues/new")!

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.subheadline)
                Text("Report an Issue")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Report an issue or enable diagnostic logs")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ReportIssuePopoverView(diagnosticsControl: diagnosticsControl)
        }
    }
}
