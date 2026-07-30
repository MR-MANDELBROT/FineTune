// FineTune/Audio/Playback/PlaybackControlling.swift
import Foundation

/// What a controllable app is currently doing with playback.
///
/// There is deliberately no `stopped` case: an app with nothing loaded has no
/// transport worth offering, and is simply absent from an adapter's report.
enum PlaybackState: Equatable, Sendable {
    case playing
    case paused
}

/// A way to observe and toggle playback in other apps.
///
/// macOS offers no general per-app transport control, so each adapter covers the
/// apps it can actually reach, and the coordinator layers them.
///
/// Adapters report what they can reach rather than answering "can you handle this
/// bundle ID?", because not every mechanism knows its own scope up front —
/// MediaRemote only learns which app it can drive by asking. Adapters must fail
/// closed: an app that cannot be observed is left out of the report entirely, and
/// the UI then omits the button rather than showing one that does nothing.
protocol PlaybackControlling: Sendable {
    /// Playback state for every app this adapter can currently reach, keyed by
    /// bundle ID. `runningBundleIDs` is the set of apps currently running, which
    /// adapters may use to avoid probing apps that are not there.
    func reachableStates(among runningBundleIDs: Set<String>) async -> [String: PlaybackState]

    /// Toggles between playing and paused. No-op when the app cannot be reached.
    func playPause(bundleID: String) async
}
