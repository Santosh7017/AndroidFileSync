//
//  EmptyStateView.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import SwiftUI

struct EmptyStateView: View {
    var isDetecting: Bool = false
    var onRetry: (() -> Void)? = nil
    var onConnectWiFi: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon with animation
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                if isDetecting {
                    ProgressView()
                        .scaleEffect(1.5)
                } else {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                }
            }
            
            // Status text
            VStack(spacing: 8) {
                Text(isDetecting ? "Scanning for Device..." : "No Device Connected")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                
                Text(isDetecting ? "Please wait while we detect your device" : "Connect your Android device via USB or WiFi")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            // Instructions
            if !isDetecting {
                instructionsList
            }
            
            // Action buttons
            if !isDetecting {
                HStack(spacing: 16) {
                    if let onRetry = onRetry {
                        Button(action: onRetry) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Try Again")
                            }
                            .font(.system(.body, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Try Again")
                    }
                    
                    if let onWiFi = onConnectWiFi {
                        Button(action: onWiFi) {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi")
                                Text("Connect via WiFi")
                            }
                            .font(.system(.body, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [.green, .green.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Connect via WiFi")
                    }
                }
                .padding(.top, 8)
                
                // Auto-retry hint
                Text("The app will automatically retry in a few seconds")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .id("empty_state_view_\(isDetecting)")
    }
    
    private var instructionsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            instructionRow(number: 1, text: "Enable 'USB Debugging' in Developer Options", icon: "ant.fill")
            instructionRow(number: 2, text: "Connect via USB cable and allow debugging on your phone", icon: "cable.connector")
            instructionRow(number: 3, text: "Or use WiFi — enable Wireless Debugging (Android 11+)", icon: "wifi")
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
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

