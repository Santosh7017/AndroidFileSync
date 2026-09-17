import AppKit
import SwiftUI

@main
struct SelectionTests {
    @MainActor
    static func main() {
        let ids = ["folder-a", "file-b", "folder-c", "file-d", "file-e", "folder-f"]
        var navigator = FileSelectionNavigator()
        var selection = navigator.select(ids[2], in: ids, selection: [], extending: false, toggling: false)
        selection = navigator.move(by: 1, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[2...3]))
        selection = navigator.move(by: 1, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[2...4]))
        selection = navigator.move(by: -1, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[2...3]), "Reversing the arrow must shrink the range")
        selection = navigator.move(by: -1, in: ids, selection: selection, extending: true)
        assert(selection == [ids[2]])
        selection = navigator.move(by: -1, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[1...2]), "Selection must extend past the original anchor")
        selection = navigator.move(by: -1, in: ids, selection: selection, extending: false)
        assert(selection == [ids[0]])
        selection = navigator.move(by: -1, in: ids, selection: selection, extending: true)
        assert(selection == [ids[0]], "Up at the first item must stay in bounds")

        navigator = FileSelectionNavigator()
        selection = navigator.move(by: 1, in: ids, selection: [], extending: true)
        assert(selection == [ids[0]])
        selection = navigator.move(by: 1, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[0...1]))
        selection = navigator.move(by: 1, in: ids, selection: [ids[3]], extending: true)
        assert(selection == Set(ids[3...4]), "A new native table click must reset the anchor")
        selection = navigator.move(by: -1, in: ids, selection: [], extending: true)
        assert(selection == [ids.last!], "Clearing selection must reset the previous range")
        selection = navigator.move(by: 1, in: [], selection: [], extending: true)
        assert(selection.isEmpty)

        navigator = FileSelectionNavigator()
        selection = navigator.select(ids[0], in: ids, selection: [], extending: false, toggling: false)
        selection = navigator.move(by: 3, in: ids, selection: selection, extending: true)
        assert(selection == Set(ids[0...3]), "Down in a grid moves by a row")
        selection = navigator.move(by: -3, in: ids, selection: selection, extending: true)
        assert(selection == [ids[0]])
        selection = navigator.select(ids[4], in: ids, selection: selection, extending: true, toggling: false)
        selection = navigator.select(ids[1], in: ids, selection: selection, extending: true, toggling: false)
        assert(selection == Set(ids[0...1]), "Shift-click must shrink the same range")
        let reversed = Array(ids.reversed())
        selection = navigator.move(by: -1, in: reversed, selection: selection, extending: true)
        assert(selection == Set(ids[0...2]), "Sorting must resolve the anchor by ID")
        let filtered = [ids[2], ids[3], ids[4]]
        selection = navigator.move(by: 1, in: filtered, selection: selection, extending: true)
        assert(selection == Set(ids[2...3]), "Filtering away the anchor must start at the visible focus")
        selection = navigator.select(ids[4], in: filtered, selection: selection, extending: false, toggling: true)
        assert(selection.contains(ids[4]))
        selection = navigator.select(ids[4], in: filtered, selection: selection, extending: false, toggling: true)
        assert(!selection.contains(ids[4]))
        print("PASS: range growth/reversal, boundaries, native clicks, clearing, grid rows, sorting/filtering, Command-click")

        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let table = NSTableView(frame: root.bounds)
        let dataSource = TableDataSource()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name")))
        table.dataSource = dataSource
        table.reloadData()
        root.addSubview(table)
        let keyboard = FileBrowserKeyboardNavigation.KeyboardView(frame: root.bounds)
        root.addSubview(keyboard)
        var moves: [(MoveCommandDirection, NSEvent.ModifierFlags)] = []
        keyboard.onMove = { direction, flags in moves.append((direction, flags)); return nil }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = .shift) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "",
                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = [],
                   clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: keyboard.convert(point, to: nil), modifierFlags: flags,
                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                              eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        var clickedRow: Int?
        keyboard.onClick = { row, _ in clickedRow = row }
        let origin = keyboard.convert(NSPoint(x: 30, y: table.rect(ofRow: 2).midY), from: table)
        assert(keyboard.handle(mouse(.leftMouseDown, origin)) == nil && clickedRow == 2)
        assert(window.firstResponder === keyboard)
        var dragged: Set<Int> = []
        keyboard.onDrag = { indexes, _, _ in dragged = indexes }
        let down = keyboard.convert(NSPoint(x: 90, y: table.rect(ofRow: 4).midY), from: table)
        assert(keyboard.handle(mouse(.leftMouseDragged, down)) == nil && dragged == [2, 3, 4])
        let up = keyboard.convert(NSPoint(x: 90, y: table.rect(ofRow: 1).midY), from: table)
        assert(keyboard.handle(mouse(.leftMouseDragged, up)) == nil && dragged == [1, 2],
               "Reversing a list drag must discard rows beyond the current rectangle")
        assert(keyboard.handle(mouse(.leftMouseUp, up)) == nil)
        func verifyOpening(at origin: CGPoint) {
            var opened: [Int] = []
            keyboard.onOpen = { opened.append($0) }
            let moved = CGPoint(x: origin.x + 8, y: origin.y + 5)
            assert(keyboard.handle(mouse(.leftMouseDown, origin)) == nil)
            assert(keyboard.handle(mouse(.leftMouseUp, origin)) == nil && opened.isEmpty)
            assert(keyboard.handle(mouse(.leftMouseDown, origin, clicks: 2)) == nil && opened.isEmpty,
                   "The second click must wait for mouse release before opening")
            assert(keyboard.handle(mouse(.leftMouseDragged, moved, clicks: 2)) == nil && opened.isEmpty)
            assert(keyboard.handle(mouse(.leftMouseDragged, origin, clicks: 2)) == nil)
            assert(keyboard.handle(mouse(.leftMouseUp, origin, clicks: 2)) == nil && opened.isEmpty,
                   "A small drag must cancel opening even when the pointer returns to its start")
            assert(keyboard.handle(mouse(.leftMouseDown, origin, clicks: 2)) == nil && opened.isEmpty)
            assert(keyboard.handle(mouse(.leftMouseUp, origin, clicks: 2)) == nil && opened.count == 1,
                   "A completed double-click must still open exactly once")
            assert(keyboard.handle(mouse(.leftMouseDown, origin, .shift, clicks: 2)) == nil)
            assert(keyboard.handle(mouse(.leftMouseUp, origin, .shift, clicks: 2)) == nil && opened.count == 1)
            assert(keyboard.handle(mouse(.leftMouseDown, origin, clicks: 2)) == nil)
            assert(keyboard.handle(mouse(.leftMouseUp, moved, clicks: 2)) == nil && opened.count == 1,
                   "Movement on mouse release must cancel opening even without a drag event")
        }
        verifyOpening(at: origin)
        for _ in 0..<4 { assert(keyboard.handle(key(125)) == nil) }
        assert(moves.count == 4 && moves.allSatisfy { $0.0 == .down && $0.1.contains(.shift) })
        assert(keyboard.handle(key(126)) == nil && moves.count == 5)
        assert(keyboard.handle(key(125, .command)) != nil && moves.count == 5)
        assert(keyboard.handle(key(123)) != nil && moves.count == 5)

        keyboard.isGrid = true
        keyboard.itemFrames = [
            0: CGRect(x: 10, y: 10, width: 90, height: 70),
            1: CGRect(x: 110, y: 10, width: 90, height: 70),
            2: CGRect(x: 10, y: 100, width: 90, height: 70),
            3: CGRect(x: 110, y: 100, width: 90, height: 70)
        ]
        assert(keyboard.handle(mouse(.leftMouseDown, CGPoint(x: 5, y: 5))) == nil)
        assert(keyboard.handle(mouse(.leftMouseDragged, CGPoint(x: 205, y: 175))) == nil && dragged == [0, 1, 2, 3])
        assert(keyboard.handle(mouse(.leftMouseDragged, CGPoint(x: 105, y: 85))) == nil && dragged == [0],
               "Reversing a tile marquee must shrink the selected group")
        assert(keyboard.handle(mouse(.leftMouseUp, CGPoint(x: 105, y: 85))) == nil)
        verifyOpening(at: CGPoint(x: 35, y: 35))
        assert(keyboard.handle(key(125)) == nil && moves.count == 6)
        assert(keyboard.handle(key(124)) == nil && moves.count == 7)
        assert(window.makeFirstResponder(table))
        assert(keyboard.handle(key(125)) != nil && moves.count == 7)
        let editor = NSTextView(frame: root.bounds)
        root.addSubview(editor)
        assert(window.makeFirstResponder(editor))
        assert(keyboard.handle(key(125)) != nil && moves.count == 7)
        keyboard.removeMonitor()
        window.close()
        print("PASS: repeated Shift + arrows, list and tile drag reversal, responder ownership, text editing, and double-click/drag distinction")
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

private final class TableDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 6 }
}
