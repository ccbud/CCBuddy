import AppKit

/// Source indices are the reader's existing logical identities, not table positions: pairing a
/// tool result can remove a projected row without changing the identity of its visible owner.
struct ConversationNativeReaderRowMap {
    private(set) var sourceIndices: [Int] = []
    private(set) var rowBySource: [Int: Int] = [:]

    struct Change: Equatable {
        let removed: IndexSet
        let inserted: IndexSet
        var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
    }

    mutating func replace(with next: [Int]) -> Change {
        var removed = IndexSet()
        var inserted = IndexSet()
        var oldRow = 0
        var newRow = 0
        // Both projections are in source order. A linear merge avoids general edit-distance
        // work for a large transcript; the bottom spacer keeps its own trailing identity.
        while oldRow < sourceIndices.count || newRow < next.count {
            if oldRow == sourceIndices.count {
                inserted.insert(newRow)
                newRow += 1
            } else if newRow == next.count {
                removed.insert(oldRow)
                oldRow += 1
            } else if sourceIndices[oldRow] == next[newRow] {
                oldRow += 1
                newRow += 1
            } else if sourceIndices[oldRow] < next[newRow] {
                removed.insert(oldRow)
                oldRow += 1
            } else {
                inserted.insert(newRow)
                newRow += 1
            }
        }
        sourceIndices = next
        rowBySource = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($1, $0) })
        return Change(removed: removed, inserted: inserted)
    }

    func row(nearestTo sourceIndex: Int) -> Int? {
        guard !sourceIndices.isEmpty else { return nil }
        if let row = rowBySource[sourceIndex] { return row }
        var lower = 0
        var upper = sourceIndices.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sourceIndices[middle] < sourceIndex { lower = middle + 1 } else { upper = middle }
        }
        // If pairing removes the old anchor, retain its preceding visible owner when possible.
        return max(0, lower - 1)
    }
}

struct ConversationNativeReaderAnchor: Equatable {
    let sourceIndex: Int
    let offsetWithinRow: CGFloat

    func origin(rowOrigin: CGFloat, rowHeight: CGFloat, maximumOrigin: CGFloat) -> CGFloat {
        let offset = min(max(0, offsetWithinRow), max(0, rowHeight - 1))
        return min(max(0, maximumOrigin), max(0, rowOrigin + offset))
    }
}

/// Geometry changes do not erase an estimate. A long row keeps its last measured height until
/// the new width/font is actually laid out, avoiding a transient 96-point row that loses offset.
struct ConversationNativeReaderHeights {
    private var measured: [Int: CGFloat] = [:]

    func estimate(for source: Int) -> CGFloat { measured[source] ?? 96 }

    mutating func retainSources(_ sources: [Int: Int], resetting: Bool) {
        if resetting { measured.removeAll(keepingCapacity: true) }
        else { measured = measured.filter { sources[$0.key] != nil } }
    }

    @discardableResult
    mutating func record(_ height: CGFloat, for source: Int) -> Bool {
        guard measured[source] != height else { return false }
        measured[source] = height
        return true
    }
}

/// No transcript or rendered content is retained here. Scope changes discard all old choices;
/// same-scope append/re-pairing keeps only the state of surviving source rows.
final class ConversationNativeReaderInteractionStore {
    private var scope: ConversationScrollInputScope?
    private var rows: [Int: ConversationMessageInteractionState] = [:]

    @discardableResult
    func update(scope: ConversationScrollInputScope, sourceIndices: [Int]) -> Bool {
        let changedScope = self.scope != scope
        if changedScope {
            rows.removeAll(keepingCapacity: true)
        } else {
            let retained = Set(sourceIndices)
            rows = rows.filter { retained.contains($0.key) }
        }
        self.scope = scope
        return changedScope
    }

    func state(for sourceIndex: Int) -> ConversationMessageInteractionState {
        if let state = rows[sourceIndex] { return state }
        let state = ConversationMessageInteractionState()
        rows[sourceIndex] = state
        return state
    }

    var retainedRowCount: Int { rows.count }
}

/// Keep one trackpad gesture (including its momentum/terminal events) on its chosen axis.
/// Discrete mouse wheels have no phases and are classified independently. Shift-wheel remains
/// the standard horizontal-scroll shortcut, even when the event reports a vertical delta.
struct ConversationNestedScrollRouting {
    private var routesToReader: Bool?
    var hasForwardedGesture: Bool { routesToReader == true }

    mutating func reset() { routesToReader = nil }

    mutating func forwards(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                           momentumPhase: NSEvent.Phase, shift: Bool,
                           overHorizontalContent: Bool) -> Bool {
        let vertical = !shift && overHorizontalContent && abs(deltaY) > abs(deltaX)
        guard !phase.isEmpty || !momentumPhase.isEmpty else {
            reset()
            return vertical
        }
        if phase.contains(.began) || phase.contains(.mayBegin) { reset() }
        if routesToReader == nil, deltaX != 0 || deltaY != 0 { routesToReader = vertical }
        let forward = routesToReader ?? false
        if phase.contains(.cancelled) || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
            reset()
        }
        return forward
    }
}
