// FineTune/Audio/Playback/PlaybackCoordinator.swift
import AppKit
import os

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

    /// Fired when the set of controllable apps changes. The process monitor listens so
    /// an app discovered as paused earns its idle row immediately — otherwise the row
    /// would only appear on the next periodic refresh, long after the user looked.
    var onControllableAppsChanged: (() -> Void)?

    private let adapters: [any PlaybackControlling]
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FineTune",
        category: "PlaybackCoordinator"
    )

    /// Polling cadence while the popup is on screen. Playback state changes from
    /// outside FineTune (media keys, the app's own UI) should show up promptly.
    private static let pollInterval: Duration = .seconds(2)

    /// Settling time after a toggle before reading the state back.
    private static let toggleSettleDelay: Duration = .milliseconds(300)

    /// Bundle IDs to consider on each refresh. Injectable so tests can drive the
    /// coordinator without a real workspace.
    private let runningBundleIDs: @MainActor () -> Set<String>

    /// Which adapter produced each app's state, so a toggle goes back to the same
    /// mechanism that reported it.
    private var owners: [String: any PlaybackControlling] = [:]

    /// AppleScript first: it addresses apps individually and precisely. MediaRemote
    /// then fills in whatever is left, which is at most the one app owning the Now
    /// Playing session.
    static func defaultAdapters() -> [any PlaybackControlling] {
        var adapters: [any PlaybackControlling] = [AppleScriptPlaybackAdapter()]
        if let mediaRemote = MediaRemotePlaybackAdapter() {
            adapters.append(mediaRemote)
        }
        return adapters
    }

    init(
        adapters: [any PlaybackControlling] = PlaybackCoordinator.defaultAdapters(),
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
        guard let bundleID, let adapter = owners[bundleID] else { return }

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
        logger.debug("setPolling(\(active, privacy: .public))")
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

        let running = runningBundleIDs()

        var next: [String: PlaybackState] = [:]
        var nextOwners: [String: any PlaybackControlling] = [:]
        for adapter in adapters {
            // First adapter to claim an app wins, so the precise mechanism keeps
            // apps that both could reach.
            for (bundleID, state) in await adapter.reachableStates(among: running)
            where next[bundleID] == nil {
                next[bundleID] = state
                nextOwners[bundleID] = adapter
            }
        }
        owners = nextOwners
        logger.debug("refresh: \(running.count) running, \(next.count) controllable")

        let changed = Set(next.keys) != Set(states.keys)
        states = next
        if changed {
            onControllableAppsChanged?()
        }
    }
}
