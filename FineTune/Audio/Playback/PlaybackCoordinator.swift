// FineTune/Audio/Playback/PlaybackCoordinator.swift
import AppKit

/// Tracks which running apps expose controllable playback, and drives them.
///
/// Candidates come from `NSWorkspace`, not from FineTune's audio list, so an app that
/// has been sitting paused since before launch is still discovered — that is what lets
/// a paused app earn an idle row in the first place.
@Observable
@MainActor
final class PlaybackCoordinator {
    /// Last known playback state per bundle ID. Only apps that answered a state query
    /// appear here, which makes membership the capability check.
    private(set) var states: [String: PlaybackState] = [:]

    private let adapters: [any PlaybackControlling]
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false

    /// Polling cadence while the popup is on screen. Playback state changes from
    /// outside FineTune (media keys, the app's own UI) should show up promptly.
    private static let pollInterval: Duration = .seconds(2)

    /// Settling time after a toggle before reading the state back.
    private static let toggleSettleDelay: Duration = .milliseconds(300)

    /// Bundle IDs to consider on each refresh. Injectable so tests can drive the
    /// coordinator without a real workspace.
    private let runningBundleIDs: @MainActor () -> Set<String>

    init(
        adapters: [any PlaybackControlling] = [AppleScriptPlaybackAdapter()],
        runningBundleIDs: @escaping @MainActor () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    ) {
        self.adapters = adapters
        self.runningBundleIDs = runningBundleIDs
    }

    // MARK: - Queries

    /// Current playback state, or `nil` when the app offers nothing to control.
    func state(for bundleID: String?) -> PlaybackState? {
        guard let bundleID else { return nil }
        return states[bundleID]
    }

    // MARK: - Commands

    func toggle(bundleID: String?) {
        guard let bundleID, let adapter = adapter(for: bundleID) else { return }

        // Flip optimistically so the icon answers the click immediately; the refresh
        // below corrects it if the app disagreed.
        if let current = states[bundleID] {
            states[bundleID] = current == .playing ? .paused : .playing
        }

        Task { [weak self] in
            await adapter.playPause(bundleID: bundleID)
            try? await Task.sleep(for: Self.toggleSettleDelay)
            await self?.refresh()
        }
    }

    // MARK: - Polling

    /// Starts or stops the refresh loop. Driven by popup visibility: querying apps is
    /// what triggers macOS's automation prompt, and that belongs in a moment the user
    /// initiated rather than out of the blue in the background.
    func setPolling(_ active: Bool) {
        guard active else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Re-reads playback state for every running app an adapter can reach.
    ///
    /// The previous snapshot is deliberately kept while polling is stopped, so the
    /// idle list is already correct the moment the popup opens.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var next: [String: PlaybackState] = [:]
        for bundleID in runningBundleIDs() {
            guard let adapter = adapter(for: bundleID) else { continue }
            if let state = await adapter.state(bundleID: bundleID) {
                next[bundleID] = state
            }
        }
        states = next
    }

    private func adapter(for bundleID: String) -> (any PlaybackControlling)? {
        adapters.first { $0.handles(bundleID: bundleID) }
    }
}
