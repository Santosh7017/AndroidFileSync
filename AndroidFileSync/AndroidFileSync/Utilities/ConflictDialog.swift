//
//  ConflictDialog.swift
//  AndroidFileSync
//
//  A polished native upload-conflict dialog built with NSPanel.
//  Replaces the raw NSAlert which doesn't handle long filenames well.
//

import AppKit

enum ConflictDialog {

    enum Choice {
        case replace      // Replace / Replace All
        case skip         // Skip Conflicts
        case cancel
    }

    /// Present a styled conflict resolution dialog centered on the app window.
    ///
    /// - Parameters:
    ///   - conflictNames: File names that already exist on the device
    ///   - totalCount: Total files being uploaded (to decide if Skip is shown)
    @MainActor
    static func show(conflictNames: [String], totalCount: Int) -> Choice {

        let isMultiple   = conflictNames.count > 1
        let hasNonConflict = totalCount > conflictNames.count

        // ── Panel ─────────────────────────────────────────────────────────
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        panel.title                       = "File Conflict"
        panel.isMovableByWindowBackground = true
        panel.level                       = .modalPanel

        let content = panel.contentView!

        // ── Warning icon ──────────────────────────────────────────────────
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
                .applying(.init(paletteColors: [.white, .systemOrange]))
            iconView.image = img.withSymbolConfiguration(cfg)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        // ── Title label ───────────────────────────────────────────────────
        let titleLabel = NSTextField(labelWithString: isMultiple
            ? "\(conflictNames.count) files already exist on the device"
            : "\"\(conflictNames[0])\" already exists")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font      = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = 320
        content.addSubview(titleLabel)

        // ── File list (scrollable) ────────────────────────────────────────
        let scrollView  = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .bezelBorder
        scrollView.wantsLayer            = true
        scrollView.layer?.cornerRadius   = 6

        let displayLimit = 15
        let listText: String
        if conflictNames.count > displayLimit {
            let visibleNames = conflictNames.prefix(displayLimit).map { "  \($0)" }
            let remainingCount = conflictNames.count - displayLimit
            listText = (visibleNames + ["  ... and \(remainingCount) more files"]).joined(separator: "\n")
        } else {
            listText = conflictNames.map { "  \($0)" }.joined(separator: "\n")
        }
        
        let textView = NSTextView()
        textView.string        = listText
        textView.isEditable    = false
        textView.isSelectable  = false
        textView.font          = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor     = .secondaryLabelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        content.addSubview(scrollView)

        // ── "Do you want to replace?" label ──────────────────────────────
        let questionLabel = NSTextField(labelWithString: isMultiple
            ? "Do you want to replace the existing files?"
            : "Do you want to replace the existing file?")
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.font      = .systemFont(ofSize: 12)
        questionLabel.textColor = .secondaryLabelColor
        content.addSubview(questionLabel)

        // ── Buttons ───────────────────────────────────────────────────────
        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.bezelStyle    = .rounded
        cancelBtn.keyEquivalent = "\u{1B}"
        content.addSubview(cancelBtn)

        var skipBtn: NSButton? = nil
        if hasNonConflict {
            let btn = NSButton(title: "Skip Conflicts", target: nil, action: nil)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.bezelStyle = .rounded
            content.addSubview(btn)
            skipBtn = btn
        }

        let replaceBtn = NSButton(title: isMultiple ? "Replace All" : "Replace",
                                  target: nil, action: nil)
        replaceBtn.translatesAutoresizingMaskIntoConstraints = false
        replaceBtn.bezelStyle    = .rounded
        replaceBtn.keyEquivalent = "\r"
        content.addSubview(replaceBtn)

        // ── Layout ────────────────────────────────────────────────────────
        let h: CGFloat = 18   // horizontal pad
        let v: CGFloat = 16   // vertical pad

        NSLayoutConstraint.activate([
            // icon — top-left
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: v),
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: h),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),

            // title — right of icon, vertically centred with it
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -h),

            // file list — below title
            scrollView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: h),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -h),
            scrollView.heightAnchor.constraint(equalToConstant: 90),

            // question
            questionLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            questionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: h),
            questionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -h),

            // Replace button — bottom right
            replaceBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -h),
            replaceBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -v),
            replaceBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        if let skip = skipBtn {
            NSLayoutConstraint.activate([
                skip.trailingAnchor.constraint(equalTo: replaceBtn.leadingAnchor, constant: -8),
                skip.bottomAnchor.constraint(equalTo: replaceBtn.bottomAnchor),
                skip.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

                cancelBtn.trailingAnchor.constraint(equalTo: skip.leadingAnchor, constant: -8),
                cancelBtn.bottomAnchor.constraint(equalTo: replaceBtn.bottomAnchor),
                cancelBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            ])
        } else {
            NSLayoutConstraint.activate([
                cancelBtn.trailingAnchor.constraint(equalTo: replaceBtn.leadingAnchor, constant: -8),
                cancelBtn.bottomAnchor.constraint(equalTo: replaceBtn.bottomAnchor),
                cancelBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            ])
        }

        // ── Resize panel to fit question label at bottom ──────────────────
        // Enough height for icon+list+question+buttons+padding
        let totalHeight: CGFloat = v + 30 + 12 + 90 + 10 + 20 + 12 + 32 + v
        panel.setContentSize(NSSize(width: 400, height: totalHeight))

        // ── Centre on app window ──────────────────────────────────────────
        if let appWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let wf = appWindow.frame
            let pf = panel.frame
            panel.setFrameOrigin(NSPoint(x: wf.midX - pf.width / 2,
                                         y: wf.midY - pf.height / 2))
        } else {
            panel.center()
        }

        // ── Wire actions ──────────────────────────────────────────────────
        var result: Choice = .cancel

        let cancelAction = Trampoline { NSApp.stopModal() }
        cancelBtn.target = cancelAction
        cancelBtn.action = #selector(Trampoline.fire)

        let replaceAction = Trampoline { result = .replace; NSApp.stopModal(withCode: .OK) }
        replaceBtn.target = replaceAction
        replaceBtn.action = #selector(Trampoline.fire)

        var skipTrampoline: Trampoline? = nil
        if let skip = skipBtn {
            let t = Trampoline { result = .skip; NSApp.stopModal(withCode: .OK) }
            skip.target = t
            skip.action = #selector(Trampoline.fire)
            skipTrampoline = t
        }
        _ = skipTrampoline  // silence unused warning

        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        return result
    }
}

// MARK: - Trampoline

private final class Trampoline: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
