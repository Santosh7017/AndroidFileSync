//
//  FileThumbnailView.swift
//  AndroidFileSync
//
//  Inline thumbnail view for file list rows. Shows a cached thumbnail
//  image or falls back to an SF Symbol icon.
//

import SwiftUI

@MainActor
struct FileThumbnailView: View {
    let file: UnifiedFile
    @ObservedObject var thumbnailProvider: ThumbnailProvider
    let fallbackIcon: String
    let fallbackColor: Color
    
    var body: some View {
        ZStack {
            if let thumb = thumbnailProvider.thumbnails[file.path] {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            } else {
                Image(systemName: fallbackIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(fallbackColor)
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
            }
        }
        .animation(.easeIn(duration: 0.25), value: thumbnailProvider.thumbnails[file.path] != nil)
    }
}
