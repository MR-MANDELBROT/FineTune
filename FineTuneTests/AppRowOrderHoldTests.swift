// FineTuneTests/AppRowOrderHoldTests.swift
//
// Verifies rows keep their positions while the popup is open, so pausing an app
// does not yank its row out from under the cursor.

import Testing
import Foundation
@testable import FineTune

@Suite("AppRowOrderHold")
@MainActor
struct AppRowOrderHoldTests {
    private func arrange(_ hold: AppRowOrderHold, _ ids: [String]) -> [String] {
        hold.arrange(ids, id: { $0 })
    }

    @Test("without a hold the natural order is used")
    func passesThroughWhenIdle() {
        let hold = AppRowOrderHold()

        #expect(arrange(hold, ["a", "b", "c"]) == ["a", "b", "c"])
    }

    @Test("a held order survives the underlying list being reordered")
    func heldOrderWins() {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b", "c"])

        // "a" paused and dropped to the bottom of the natural order.
        #expect(arrange(hold, ["b", "c", "a"]) == ["a", "b", "c"])
    }

    @Test("apps that appear while held sort after the held ones")
    func newAppsGoLast() {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b"])

        #expect(arrange(hold, ["new", "b", "a"]) == ["a", "b", "new"])
    }

    @Test("apps that go away are simply absent")
    func removedAppsDropOut() {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b", "c"])

        #expect(arrange(hold, ["c", "a"]) == ["a", "c"])
    }

    @Test("releasing the hold restores the natural order")
    func endHoldReleases() {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b", "c"])
        #expect(arrange(hold, ["c", "b", "a"]) == ["a", "b", "c"])

        hold.endHold()

        #expect(arrange(hold, ["c", "b", "a"]) == ["c", "b", "a"])
    }

    @Test("a fresh hold replaces the previous arrangement")
    func beginHoldReplaces() {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b"])
        hold.beginHold(order: ["b", "a"])

        #expect(arrange(hold, ["a", "b"]) == ["b", "a"])
    }

    @Test("a change with no hold active does not start holding")
    func changesAreIgnoredWhileReleased() {
        let hold = AppRowOrderHold()

        hold.noteOrderChanged(to: ["c", "b", "a"])

        #expect(arrange(hold, ["a", "b", "c"]) == ["a", "b", "c"])
    }

    @Test("the new order is adopted once the hold window passes")
    func adoptsAfterHoldWindow() async throws {
        let hold = AppRowOrderHold()
        hold.beginHold(order: ["a", "b", "c"])
        hold.noteOrderChanged(to: ["c", "b", "a"])

        // Still held immediately after the change — that is the whole point.
        #expect(arrange(hold, ["c", "b", "a"]) == ["a", "b", "c"])

        try await Task.sleep(for: AppRowOrderHold.holdDuration + .seconds(1))

        #expect(arrange(hold, ["c", "b", "a"]) == ["c", "b", "a"])
    }
}
