//
//  VideoPlayerView.swift
//  AndroidFileSync
//
//  NSViewRepresentable wrapper for AVPlayerView — provides native macOS
//  video playback controls inline in the preview panel.
//

import SwiftUI
import AVKit

/// Native AVPlayerView wrapper for inline video playback in the preview panel.
/// Auto-plays on appear, shows native macOS transport controls.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        let player = AVPlayer(url: url)
        
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        
        // Auto-play with slight delay for smooth transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            player.volume = 0.5
            player.play()
        }
        
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Only update if URL changed
        if let currentItem = nsView.player?.currentItem,
           let asset = currentItem.asset as? AVURLAsset,
           asset.url == url {
            return
        }
        
        // New URL — replace player
        nsView.player?.pause()
        let player = AVPlayer(url: url)
        nsView.player = player
        player.volume = 0.5
        player.play()
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
