import Foundation

/// Keeps the range anchor separate from the moving end of a keyboard selection.
struct FileSelectionNavigator {
    private(set) var anchorID: String?
    private(set) var focusedID: String?
    private var lastSelection: Set<String> = []

    mutating func setMarqueeSelection(_ selection: Set<String>, anchorID: String?, focusedID: String?) {
        self.anchorID = anchorID ?? focusedID
        self.focusedID = focusedID
        lastSelection = selection
    }

    mutating func select(_ id: String, in ids: [String], selection: Set<String>,
                         extending: Bool, toggling: Bool) -> Set<String> {
        synchronize(selection, in: ids)
        guard let index = ids.firstIndex(of: id) else { return selection }

        var result: Set<String>
        if extending, let anchorID, let anchorIndex = ids.firstIndex(of: anchorID) {
            result = Set(ids[min(anchorIndex, index)...max(anchorIndex, index)])
            if toggling { result.formUnion(selection) }
        } else if toggling {
            result = selection
            if !result.insert(id).inserted { result.remove(id) }
            anchorID = id
        } else {
            result = [id]
            anchorID = id
        }
        focusedID = id
        lastSelection = result
        return result
    }

    mutating func move(by offset: Int, in ids: [String], selection: Set<String>,
                       extending: Bool) -> Set<String> {
        guard !ids.isEmpty, offset != 0 else { return selection }
        synchronize(selection, in: ids)

        let currentIndex = focusedID.flatMap { ids.firstIndex(of: $0) }
        let targetIndex = currentIndex.map { min(max($0 + offset, 0), ids.count - 1) }
            ?? (offset > 0 ? 0 : ids.count - 1)
        let targetID = ids[targetIndex]

        if !extending || anchorID == nil { anchorID = focusedID ?? targetID }
        let result: Set<String>
        if extending, let anchorID, let anchorIndex = ids.firstIndex(of: anchorID) {
            result = Set(ids[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)])
        } else {
            result = [targetID]
            anchorID = targetID
        }
        focusedID = targetID
        lastSelection = result
        return result
    }

    private mutating func synchronize(_ selection: Set<String>, in ids: [String]) {
        // A click in the native table, Select All, or clearing selection starts
        // a new range. Resolve IDs against the current sorted/filtered listing.
        if selection != lastSelection {
            let added = selection.subtracting(lastSelection)
            focusedID = ids.first { added.contains($0) } ?? ids.first { selection.contains($0) }
            anchorID = focusedID
            lastSelection = selection
        }
        if let anchorID, !ids.contains(anchorID) { self.anchorID = nil }
        if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
    }
}
