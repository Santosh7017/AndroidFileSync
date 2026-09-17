//
//  FilePreviewPanel.swift
//  AndroidFileSync
//
//  In-app QuickLook-style preview panel — shows instant thumbnails for images/videos
//  without pulling the entire file. Styled after macOS QuickLook with vibrancy,
//  spring animations, and native material effects.
//

import SwiftUI

// MARK: - Preview Panel

struct FilePreviewPanel: View {
    @ObservedObject var previewManager: FilePreviewManager
    
    @State private var appeared = false
    @State private var imageScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Dimmed backdrop — click to dismiss
            Color.black
                .opacity(appeared ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close preview")
            
            // Floating panel
            panelContent
                .frame(maxWidth: 820, maxHeight: 620)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 40, y: 12)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .scaleEffect(appeared ? 1.0 : 0.88)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .onExitCommand { dismiss() }
    }
    
    // MARK: - Panel Layout
    
    private var panelContent: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomToolbar
        }
    }
    
    // MARK: - Title Bar
    
    private var titleBar: some View {
        HStack(spacing: 8) {
            // Category icon
            categoryIcon
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            
            // File name
            Text(previewManager.previewFile?.name ?? "Preview")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // File size badge
            if let file = previewManager.previewFile, file.size > 0 {
                Text(formatBytes(file.size))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            
            // Close
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - Category Icon
    
    @ViewBuilder
    private var categoryIcon: some View {
        let category = previewManager.previewFile.map {
            PreviewFileCategory(extension: $0.pathExtension)
        } ?? .unknown
        
        Image(systemName: category.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor(for: category))
    }
    
    private func iconColor(for category: PreviewFileCategory) -> Color {
        switch category {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .document: return .orange
        case .unknown: return .gray
        }
    }
    
    // MARK: - Content Area
    
    @ViewBuilder
    private var contentArea: some View {
        switch previewManager.previewContent {
        case .loading:
            loadingView
        case .image(let nsImage):
            imagePreview(nsImage)
        case .videoThumbnail(let nsImage):
            videoPreview(nsImage)
        case .audioIcon:
            audioPreview
        case .documentIcon(let ext):
            documentPreview(ext)
        case .error(let message):
            errorView(message)
        }
    }
    
    // MARK: - Loading
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            
            Text("Loading preview…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Image Preview
    
    private func imagePreview(_ nsImage: NSImage) -> some View {
        GeometryReader { geo in
            let fitted = fittedSize(image: nsImage.size, container: geo.size)
            
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: fitted.width * imageScale,
                        height: fitted.height * imageScale
                    )
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    imageScale = imageScale > 1.0 ? 1.0 : 2.5
                }
            }
            .accessibilityLabel("Image preview. Double-click to zoom.")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
    
    /// Calculate the largest size that fits the image inside the container without upscaling.
    private func fittedSize(image: NSSize, container: CGSize) -> CGSize {
        let scale = min(
            container.width / image.width,
            container.height / image.height,
            1.0
        )
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    
    // MARK: - Video Preview
    
    private func videoPreview(_ thumbnail: NSImage) -> some View {
        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Play button overlay
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.25), radius: 10)
                    
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
                
                Text("Open in App to play")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .background(Color.black.opacity(0.05))
        .accessibilityLabel("Video thumbnail preview")
    }
    
    // MARK: - Audio Preview
    
    private var audioPreview: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.pink)
            
            fileInfoStack
            
            Text("Open in App to play audio")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Audio file preview")
    }
    
    // MARK: - Document Preview
    
    private func documentPreview(_ ext: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: documentSymbol(for: ext))
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            
            fileInfoStack
            
            if !ext.isEmpty {
                Text(ext.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// Shared file name + size + date stack
    @ViewBuilder
    private var fileInfoStack: some View {
        if let file = previewManager.previewFile {
            VStack(spacing: 4) {
                Text(file.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                Text(formatBytes(file.size))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                
                if let date = file.modificationDate {
                    Text(date, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    private func documentSymbol(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":                              return "doc.richtext"
        case "txt", "md", "rtf":                 return "doc.text"
        case "html", "htm":                      return "globe"
        case "json", "xml", "csv":               return "tablecells"
        case "xls", "xlsx":                      return "tablecells"
        case "ppt", "pptx":                      return "rectangle.on.rectangle"
        case "swift", "java", "py", "js", "ts",
             "c", "cpp", "h", "css":             return "chevron.left.forwardslash.chevron.right"
        default:                                 return "doc"
        }
    }
    
    // MARK: - Error View
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
            
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Bottom Toolbar
    
    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            // Category badge
            if let file = previewManager.previewFile {
                let category = PreviewFileCategory(extension: file.pathExtension)
                Text(category.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            
            Spacer()
            
            // Full pull progress indicator
            if previewManager.isLoadingFullFile {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(previewManager.fullFilePullProgress)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            
            // Open in external app
            Button {
                previewManager.openInExternalApp()
            } label: {
                Label("Open in App", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
            .disabled(previewManager.isLoadingFullFile)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - Dismiss
    
    private func dismiss() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            previewManager.dismissPreview()
        }
    }
}
