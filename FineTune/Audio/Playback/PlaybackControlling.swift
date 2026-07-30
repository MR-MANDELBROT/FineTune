// FineTune/Audio/Playback/PlaybackControlling.swift
import Foundation

/// What a controllable app is currently doing with playback.
///
/// There is deliberately no `stopped` case: an app with nothing loaded has no
/// transport worth offering, and is reported as `nil` instead.
enum PlaybackState: Equatable, Sendable {
    case playing
    case paused
}

/// A way to observe and toggle playback in another app.
///
/// macOS offers no general per-app transport control, so each adapter covers the
/// apps it can actually reach. Adapters must fail closed: when playback cannot be
/// observed, `state(bundleID:)` returns `nil` and the UI simply omits the button
/// rather than showing one that does nothing.
protocol PlaybackControlling: Sendable {
    /// Whether this adapter has a recipe for the given app. Necessary but not
    /// sufficient — capability is confirmed by a state query that actually succeeds.
    nonisolated func handles(bundleID: String) -> Bool

    /// Current playback state, or `nil` if it cannot be determined.
    func state(bundleID: String) async -> PlaybackState?

    /// Toggles between playing and paused. No-op when the app cannot be reached.
    func playPause(bundleID: String) async
}
