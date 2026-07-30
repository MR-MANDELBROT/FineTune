// FineTuneTests/PlaybackCoordinatorTests.swift
//
// Verifies the coordinator only reports apps it can actually reach, so the UI never
// draws a transport button that does nothing.

import Testing
import Foundation
@testable import FineTune

// MARK: - Mock adapter

/// Stands in for the AppleScript adapter. An actor for the same reason the real one
/// is: `PlaybackControlling` is Sendable and its methods are async.
actor MockPlaybackAdapter: PlaybackControlling {
    /// Apps this adapter claims a recipe for — deliberately separable from the apps
    /// that actually answer, so tests can model a recipe that fails at runtime.
    nonisolated let handled: Set<String>

    private var states: [String: PlaybackState]
    private(set) var toggleCounts: [String: Int] = [:]

    init(states: [String: PlaybackState], handled: Set<String>? = nil) {
        self.states = states
        self.handled = handled ?? Set(states.keys)
    }

    func reachableStates(among runningBundleIDs: Set<String>) async -> [String: PlaybackState] {
        var result: [String: PlaybackState] = [:]
        for bundleID in runningBundleIDs where handled.contains(bundleID) {
            if let state = states[bundleID] { result[bundleID] = state }
        }
        return result
    }

    func state(bundleID: String) async -> PlaybackState? {
        states[bundleID]
    }

    func playPause(bundleID: String) async {
        toggleCounts[bundleID, default: 0] += 1
        if let current = states[bundleID] {
            states[bundleID] = current == .playing ? .paused : .playing
        }
    }
}

// MARK: - Tests

@Suite("PlaybackCoordinator")
@MainActor
struct PlaybackCoordinatorTests {
    private func makeCoordinator(
        states: [String: PlaybackState],
        handled: Set<String>? = nil,
        running: Set<String>
    ) -> (PlaybackCoordinator, MockPlaybackAdapter) {
        let adapter = MockPlaybackAdapter(states: states, handled: handled)
        let coordinator = PlaybackCoordinator(
            adapters: [adapter],
            runningBundleIDs: { running }
        )
        return (coordinator, adapter)
    }

    @Test("refresh records state for running apps the adapter reaches")
    func refreshRecordsReachableApps() async {
        let (coordinator, _) = makeCoordinator(
            states: ["com.test.player": .paused],
            running: ["com.test.player"]
        )

        await coordinator.refresh()

        #expect(coordinator.state(for: "com.test.player") == .paused)
    }

    @Test("apps no adapter handles report no state")
    func unhandledAppsReportNothing() async {
        let (coordinator, _) = makeCoordinator(
            states: ["com.test.player": .playing],
            running: ["com.test.player", "com.test.silent"]
        )

        await coordinator.refresh()

        #expect(coordinator.state(for: "com.test.silent") == nil)
    }

    @Test("a recipe that fails at runtime yields no state, not a broken button")
    func failingRecipeYieldsNoState() async {
        // Handled, running — but the adapter cannot actually read it.
        let (coordinator, _) = makeCoordinator(
            states: [:],
            handled: ["com.test.unreachable"],
            running: ["com.test.unreachable"]
        )

        await coordinator.refresh()

        #expect(coordinator.state(for: "com.test.unreachable") == nil)
    }

    @Test("apps that are not running are dropped on refresh")
    func stoppedAppsAreDropped() async {
        let (coordinator, _) = makeCoordinator(
            states: ["com.test.player": .playing],
            running: ["com.test.player"]
        )
        await coordinator.refresh()
        #expect(coordinator.state(for: "com.test.player") == .playing)

        let quitCoordinator = PlaybackCoordinator(
            adapters: [MockPlaybackAdapter(states: ["com.test.player": .playing])],
            runningBundleIDs: { [] }
        )
        await quitCoordinator.refresh()

        #expect(quitCoordinator.state(for: "com.test.player") == nil)
    }

    @Test("nil bundle ID reports no state")
    func nilBundleIDReportsNothing() {
        let (coordinator, _) = makeCoordinator(states: [:], running: [])

        #expect(coordinator.state(for: nil) == nil)
    }

    @Test("toggle flips the icon immediately rather than waiting on the app")
    func toggleFlipsOptimistically() async {
        let (coordinator, _) = makeCoordinator(
            states: ["com.test.player": .playing],
            running: ["com.test.player"]
        )
        await coordinator.refresh()

        coordinator.toggle(bundleID: "com.test.player")

        // Checked synchronously: the optimistic flip lands before the async round trip.
        #expect(coordinator.state(for: "com.test.player") == .paused)
    }

    @Test("toggling an unreachable app does nothing")
    func toggleIgnoresUnreachableApps() async {
        let (coordinator, adapter) = makeCoordinator(
            states: ["com.test.player": .playing],
            running: ["com.test.player"]
        )
        await coordinator.refresh()

        coordinator.toggle(bundleID: "com.test.absent")

        #expect(await adapter.toggleCounts["com.test.absent"] == nil)
        #expect(coordinator.state(for: "com.test.absent") == nil)
    }

    @Test("adapter reports the flipped state after a toggle")
    func adapterFlipsState() async {
        let adapter = MockPlaybackAdapter(states: ["com.test.player": .playing])

        await adapter.playPause(bundleID: "com.test.player")

        #expect(await adapter.state(bundleID: "com.test.player") == .paused)
        #expect(await adapter.toggleCounts["com.test.player"] == 1)
    }
}
