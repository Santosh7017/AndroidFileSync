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
                
                Text(isDetecting ? "Please wait while we detect your device" : "Connect your Android device via USB")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            // Instructions
            if !isDetecting {
                instructionsList
            }
            
            // Retry button
            if !isDetecting, let onRetry = onRetry {
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
    }
    
    private var instructionsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            instructionRow(number: 1, text: "Enable 'File Transfer' mode on your phone", icon: "folder.fill")
            instructionRow(number: 2, text: "Or enable 'USB Debugging' for better performance", icon: "ant.fill")
            instructionRow(number: 3, text: "Make sure ADB is installed on your Mac", icon: "terminal.fill")
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
