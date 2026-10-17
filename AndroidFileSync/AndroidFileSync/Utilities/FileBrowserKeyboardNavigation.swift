import AppKit
import SwiftUI

/// Owns browser clicks, marquee selection, and keyboard selection together.
struct FileBrowserKeyboardNavigation: NSViewRepresentable {
    var isGrid: Bool
    var onMove: (MoveCommandDirection, NSEvent.ModifierFlags) -> Int?
    var itemFrames: [Int: CGRect] = [:]
    var selectedIndexes: Set<Int> = []
    var isEnabled: Bool = true
    var onClick: ((Int?, NSEvent.ModifierFlags) -> Void)? = nil
    var onOpen: ((Int) -> Void)? = nil
    var onDrag: ((Set<Int>, Int?, Int?) -> Void)? = nil
    var onMarqueeChange: ((CGRect?) -> Void)? = nil

    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeyboardView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ view: KeyboardView, context: Context) {
        view.isGrid = isGrid
        view.itemFrames = itemFrames
        view.selectedIndexes = selectedIndexes
        view.isEnabled = isEnabled
        view.onMove = onMove
        view.onClick = onClick
        view.onOpen = onOpen
        view.onDrag = onDrag
        view.onMarqueeChange = onMarqueeChange
    }

    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) {
        view.removeMonitor()
    }

    final class KeyboardView: NSView {
        var isGrid = false
        var isEnabled = true
        var itemFrames: [Int: CGRect] = [:]
        var selectedIndexes: Set<Int> = []
        var onMove: ((MoveCommandDirection, NSEvent.ModifierFlags) -> Int?)?
        var onClick: ((Int?, NSEvent.ModifierFlags) -> Void)?
        var onOpen: ((Int) -> Void)?
        var onDrag: ((Set<Int>, Int?, Int?) -> Void)?
        var onMarqueeChange: ((CGRect?) -> Void)?
        private var monitor: Any?
        private var dragOrigin: CGPoint?
        private var dragAnchor: Int?
        private var dragBaseSelection: Set<Int> = []
        private var didDrag = false
        private var pendingOpenIndex: Int?

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dragOrigin = nil
            pendingOpenIndex = nil
        }

        private func tableView() -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            let scope = convert(bounds, to: nil)
            func find(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView,
                   scope.intersects(table.convert(table.visibleRect, to: nil)) { return table }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return find(in: content)
        }

        private func frames() -> [Int: CGRect] {
            if isGrid { return itemFrames }
            guard let table = tableView() else { return [:] }
            let visibleRows = table.rows(in: table.visibleRect)
            guard visibleRows.location != NSNotFound else { return [:] }
            return Dictionary(uniqueKeysWithValues: (visibleRows.location..<NSMaxRange(visibleRows)).map {
                ($0, table.convert(table.rect(ofRow: $0), to: self))
            })
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window, window.isKeyWindow,
                  event.window == nil || event.window === window,
                  NSApp.modalWindow == nil, window.attachedSheet == nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let point = convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseDown {
                guard bounds.contains(point) else { return event }
                if let content = window.contentView {
                    var target = content.hitTest(content.convert(event.locationInWindow, from: nil))
                    while let view = target {
                        if view is NSScroller { return event }
                        target = view.superview
                    }
                }
                // Column headers retain their native sorting and resizing.
                if !isGrid, let table = tableView(),
                   table.convert(point, from: self).y < 0 { return event }
                let index = frames().first { $0.value.contains(point) }?.key
                window.makeFirstResponder(self)
                dragOrigin = point
                dragAnchor = index
                dragBaseSelection = flags.intersection([.shift, .command]).isEmpty ? [] : selectedIndexes
                didDrag = false
                pendingOpenIndex = event.clickCount == 2 && flags.intersection([.shift, .command, .option, .control]).isEmpty
                    ? index : nil
                onClick?(index, flags)
                return nil
            }
            if event.type == .leftMouseDragged, let origin = dragOrigin {
                guard didDrag || hypot(point.x - origin.x, point.y - origin.y) > 3 else { return nil }
                didDrag = true
                pendingOpenIndex = nil
                let rectangle = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                                       width: max(abs(point.x - origin.x), 1), height: max(abs(point.y - origin.y), 1))
                let itemFrames = frames()
                let intersecting = itemFrames.filter { $0.value.intersects(rectangle) }
                let indexes = Set(intersecting.keys).union(dragBaseSelection)
                let nearest = intersecting.min {
                    hypot($0.value.midX - point.x, $0.value.midY - point.y)
                        < hypot($1.value.midX - point.x, $1.value.midY - point.y)
                }?.key
                let anchor = dragAnchor ?? intersecting.min {
                    hypot($0.value.midX - origin.x, $0.value.midY - origin.y)
                        < hypot($1.value.midX - origin.x, $1.value.midY - origin.y)
                }?.key
                onDrag?(indexes, anchor, nearest)
                onMarqueeChange?(rectangle)
                return nil
            }
            if event.type == .leftMouseUp, let origin = dragOrigin {
                // A quick selection click followed by a drag can have clickCount
                // 2. Wait for release so movement can cancel opening the item.
                let openIndex = pendingOpenIndex.flatMap { index in
                    !didDrag && hypot(point.x - origin.x, point.y - origin.y) <= 3
                        && frames()[index]?.contains(point) == true ? index : nil
                }
                dragOrigin = nil
                pendingOpenIndex = nil
                onMarqueeChange?(nil)
                window.makeFirstResponder(self)
                if let openIndex { onOpen?(openIndex) }
                return nil
            }
            guard event.type == .keyDown,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                  window.firstResponder === self || (!isGrid && window.firstResponder === tableView()),
                  flags.intersection([.command, .option, .control]).isEmpty else { return event }
            let direction: MoveCommandDirection
            switch event.keyCode {
            case 126: direction = .up
            case 125: direction = .down
            case 123 where isGrid: direction = .left
            case 124 where isGrid: direction = .right
            default: return event
            }
            if let row = onMove?(direction, flags), !isGrid { tableView()?.scrollRowToVisible(row) }
            return nil
        }
    }
}

struct FileBrowserItemFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
