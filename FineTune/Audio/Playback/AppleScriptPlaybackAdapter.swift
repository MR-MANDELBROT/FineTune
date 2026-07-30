// FineTune/Audio/Playback/AppleScriptPlaybackAdapter.swift
import Foundation
import os

/// Controls playback in apps that expose a scripting interface.
///
/// An actor for two reasons: `NSAppleScript` must not be executed concurrently, and
/// an Apple Event to a busy app can block for a while — neither belongs on the main
/// actor while the popup is on screen.
///
/// Scripts address their target by `application id`, which would *launch* a target
/// that is not running. Callers only ever pass bundle IDs taken from CoreAudio's live
/// process list, so the app is already running by construction.
actor AppleScriptPlaybackAdapter: PlaybackControlling {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FineTune",
        category: "PlaybackAdapter"
    )

    /// Compiled scripts, keyed by their source. Compilation is cheap but not free,
    /// and these run on a poll while the popup is open.
    private var compiled: [String: NSAppleScript] = [:]

    /// Apps the user has denied automation access for. Retrying would re-prompt on
    /// every poll, so one refusal is final for the lifetime of the process.
    private var denied: Set<String> = []

    // MARK: - App table

    private struct Recipe: Sendable {
        /// Returns "playing"/"paused" (the `player state` idiom) or "true"/"false"
        /// (the boolean idiom). Anything else means "nothing loaded".
        let state: String
        let toggle: String
    }

    /// The `player state` idiom, shared by Spotify and Apple's media apps. Their
    /// enumerations are stopped/playing/paused, plus fast forwarding/rewinding on
    /// Apple's, which read as playing.
    private static func playerStateRecipe(_ bundleID: String) -> Recipe {
        Recipe(
            state: "tell application id \"\(bundleID)\" to return player state as string",
            toggle: "tell application id \"\(bundleID)\" to playpause"
        )
    }

    /// Verified against each app's scripting dictionary. Adding an app is a matter of
    /// one entry: a wrong guess costs nothing, because a script that fails to return a
    /// recognised state leaves the app without a button rather than a broken one.
    private static let recipes: [String: Recipe] = [
        "com.spotify.client": playerStateRecipe("com.spotify.client"),
        "com.apple.Music": playerStateRecipe("com.apple.Music"),
        "com.apple.TV": playerStateRecipe("com.apple.TV"),

        // QuickTime is document-based rather than player-based.
        "com.apple.QuickTimePlayerX": Recipe(
            state: """
                tell application id "com.apple.QuickTimePlayerX"
                    if (count of documents) is 0 then return "none"
                    return (playing of document 1) as string
                end tell
                """,
            toggle: """
                tell application id "com.apple.QuickTimePlayerX"
                    if (count of documents) is 0 then return
                    if playing of document 1 then
                        pause document 1
                    else
                        play document 1
                    end if
                end tell
                """
        ),

        // VLC exposes a `playing` boolean, and its `play` command toggles.
        "org.videolan.vlc": Recipe(
            state: "tell application id \"org.videolan.vlc\" to return (playing) as string",
            toggle: "tell application id \"org.videolan.vlc\" to play"
        ),
    ]

    // MARK: - PlaybackControlling

    func reachableStates(among runningBundleIDs: Set<String>) async -> [String: PlaybackState] {
        var result: [String: PlaybackState] = [:]
        for bundleID in runningBundleIDs where Self.recipes[bundleID] != nil {
            if let state = await state(bundleID: bundleID) {
                result[bundleID] = state
            }
        }
        return result
    }

    private func state(bundleID: String) async -> PlaybackState? {
        guard let recipe = Self.recipes[bundleID], !denied.contains(bundleID) else { return nil }
        guard let raw = run(recipe.state, bundleID: bundleID, expectsResult: true) else { return nil }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing", "fast forwarding", "rewinding", "true":
            return .playing
        case "paused", "false":
            return .paused
        default:
            // "stopped", "none", or anything unrecognised: no transport to offer.
            return nil
        }
    }

    func playPause(bundleID: String) async {
        guard let recipe = Self.recipes[bundleID], !denied.contains(bundleID) else { return }
        // Toggle commands return nothing by design, so no result is expected.
        _ = run(recipe.toggle, bundleID: bundleID, expectsResult: false)
    }

    // MARK: - Execution

    /// Runs `source`, returning its string result. Wrapped in a short Apple Event
    /// timeout so an unresponsive target cannot stall the poll for the default 2
    /// minutes.
    private func run(_ source: String, bundleID: String, expectsResult: Bool) -> String? {
        let wrapped = """
            with timeout of 2 seconds
            \(source)
            end timeout
            """

        let script: NSAppleScript
        if let cached = compiled[wrapped] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: wrapped) else {
                logger.error("Could not compile playback script for \(bundleID, privacy: .public)")
                return nil
            }
            compiled[wrapped] = fresh
            script = fresh
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: the user declined automation access for this app.
            if code == -1743 {
                denied.insert(bundleID)
                logger.info("Automation denied for \(bundleID, privacy: .public); not asking again")
            } else {
                logger.debug("Playback script failed for \(bundleID, privacy: .public): \(code)")
            }
            return nil
        }

        guard let value = result.stringValue else {
            if expectsResult {
                // Reached when the event is blocked outright rather than refused — most
                // likely a missing com.apple.security.automation.apple-events entitlement,
                // which hardened runtime requires before any Apple Event may be sent.
                logger.error("Playback script for \(bundleID, privacy: .public) returned no value and no error")
            }
            return nil
        }
        return value
    }
}
