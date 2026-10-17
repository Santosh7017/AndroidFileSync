//
//  FileTileView.swift
//  AndroidFileSync
//
//  Finder-inspired tile used by the file browser's grid layout.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileTileView: View {
    let file: UnifiedFile
    let isSelected: Bool
    var thumbnailProvider: ThumbnailProvider? = nil
    let fallbackIcon: String
    let fallbackColor: Color
    let detailText: String

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            artwork
                .frame(maxWidth: .infinity)
                .frame(height: 72)

            VStack(spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .top)

                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(tileBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(file.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityValue(detailText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack {
            if file.isDirectory {
                folderArtwork
            } else if let thumbnailProvider {
                FileTileThumbnail(
                    file: file,
                    thumbnailProvider: thumbnailProvider,
                    fallbackIcon: fallbackIcon,
                    fallbackColor: fallbackColor
                )
            } else {
                fallbackArtwork
            }

            if isVideoFile && !file.isDirectory {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.58), in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isHovering && !isSelected
                    ? Color.primary.opacity(0.04)
                    : Color.clear
            )
    }

    private var folderArtwork: some View {
        CategorizedFolderIcon(folderName: file.name, size: 72)
    }

    private var fallbackArtwork: some View {
        FileTileFallbackArtwork(
            fileName: file.name,
            icon: fallbackIcon,
            color: fallbackColor
        )
    }

    private var isVideoFile: Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "m4v", "webm"].contains(ext)
    }
}

/// Observes thumbnail updates independently so an Equatable parent does not
/// prevent tiles from refreshing as images arrive asynchronously.
private struct FileTileThumbnail: View {
    let file: UnifiedFile
    @ObservedObject var thumbnailProvider: ThumbnailProvider
    let fallbackIcon: String
    let fallbackColor: Color

    var body: some View {
        if let thumbnail = thumbnailProvider.thumbnails[file.path] {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: 82, height: 66)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .transition(.opacity.animation(.easeIn(duration: 0.2)))
        } else {
            FileTileFallbackArtwork(
                fileName: file.name,
                icon: fallbackIcon,
                color: fallbackColor
            )
        }
    }
}

private struct FileTileFallbackArtwork: View {
    let fileName: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .font(.system(size: 34))

            if !fileExtension.isEmpty {
                Text(fileExtension)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12), in: Capsule())
            }
        }
    }

    private var fileExtension: String {
        (fileName as NSString).pathExtension.uppercased()
    }
}
