//
//  EmptyStateView.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Device Connected")
                .font(.title2)
            
            Text("Connect your Android device via USB")
                .font(.body)
                .foregroundColor(.secondary)
            
            instructionsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var instructionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            instructionRow(number: 1, text: "Enable 'File Transfer' mode on your phone")
            instructionRow(number: 2, text: "Or enable 'USB Debugging' for better performance")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func instructionRow(number: Int, text: String) -> some View {
        HStack {
            Image(systemName: "\(number).circle.fill")
            Text(text)
        }
    }
}
