// FineTune/Coordination/AppRowOrderHold.swift
import Foundation

/// Keeps the app list from rearranging under the user's cursor.
///
/// Rows are ordered active-first, idle-last, so pausing an app makes its row jump
/// down the list — right after the user clicked the button on it. The order is
/// therefore held while the popup is on screen and only catches up once things
/// have settled, or once the popup is out of sight.
@Observable
@MainActor
final class AppRowOrderHold {
    /// How long the list waits after the last change before adopting a new order.
    static let holdDuration: Duration = .seconds(10)

    /// Identifiers in the order they should be rendered. Empty means "no hold" —
    /// the natural order is used as-is.
    private var heldIDs: [String] = []
    private var adoptTask: Task<Void, Never>?

    /// Reorders `items` to match the held arrangement. Pure: safe to call while
    /// rendering. Items that were not part of the hold keep their natural order
    /// and sort after the held ones.
    func arrange<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        guard !heldIDs.isEmpty else { return items }

        var position: [String: Int] = [:]
        position.reserveCapacity(heldIDs.count)
        for (index, identifier) in heldIDs.enumerated() {
            position[identifier] = index
        }

        return items.enumerated()
            .sorted { lhs, rhs in
                let left = position[id(lhs.element)] ?? (heldIDs.count + lhs.offset)
                let right = position[id(rhs.element)] ?? (heldIDs.count + rhs.offset)
                return left < right
            }
            .map(\.element)
    }

    /// Freezes the current arrangement — called when the popup appears.
    func beginHold(order ids: [String]) {
        adoptTask?.cancel()
        adoptTask = nil
        heldIDs = ids
    }

    /// Releases the hold so the natural order applies again — called when the
    /// popup is dismissed, where a rearrangement costs the user nothing.
    func endHold() {
        adoptTask?.cancel()
        adoptTask = nil
        heldIDs = []
    }

    /// The underlying order changed while the hold is active. The new order is
    /// adopted once nothing has changed for `holdDuration`, so a burst of changes
    /// settles into a single rearrangement instead of several.
    func noteOrderChanged(to ids: [String]) {
        guard !heldIDs.isEmpty else { return }

        adoptTask?.cancel()
        adoptTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            self?.heldIDs = ids
        }
    }
}
