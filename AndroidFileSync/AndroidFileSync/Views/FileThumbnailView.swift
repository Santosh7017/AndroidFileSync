//
//  FileThumbnailView.swift
//  AndroidFileSync
//
//  Inline thumbnail view for file list rows. Shows a cached thumbnail
//  image or falls back to an SF Symbol icon.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FileThumbnailView: View {
    let file: UnifiedFile
    @ObservedObject var thumbnailProvider: ThumbnailProvider
    let fallbackIcon: String
    let fallbackColor: Color
    var size: CGFloat = 26
    
    var body: some View {
        ZStack {
            if let thumb = thumbnailProvider.thumbnails[file.path] {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            } else if file.isDirectory {
                CategorizedFolderIcon(folderName: file.name, size: size)
            } else {
                Image(systemName: fallbackIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(fallbackColor)
                    .font(.system(size: size * 0.58))
                    .frame(width: size, height: size)
            }
        }
        .animation(.easeIn(duration: 0.25), value: thumbnailProvider.thumbnails[file.path] != nil)
    }
}

/// Native macOS folder artwork with a subtle category emblem, matching
/// Finder's specialized Downloads, Music, Pictures, and similar folders.
struct CategorizedFolderIcon: View {
    let folderName: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)

            if let emblem {
                Image(systemName: emblem)
                    .font(.system(size: emblemSize, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.blue.opacity(0.5))
                    .offset(y: size * 0.1)
            }
        }
        .frame(width: size, height: size)
    }

    private var emblemSize: CGFloat {
        size <= 32 ? size * 0.29 : size * 0.24
    }

    private var emblem: String? {
        switch folderName.lowercased() {
        case "dcim", "camera": return "camera.fill"
        case "download", "downloads": return "arrow.down"
        case "pictures", "photos": return "photo.fill"
        case "music": return "music.note"
        case "movies", "videos": return "film.fill"
        case "documents": return "doc.fill"
        case "alarms": return "alarm.fill"
        case "ringtones": return "bell.fill"
        case "notifications": return "bell.badge.fill"
        case "podcasts": return "mic.fill"
        case "audiobooks": return "book.fill"
        case "android": return "gear"
        default: return nil
        }
    }
}
