// FineTune/Audio/Playback/MediaRemotePlaybackAdapter.swift
import Foundation
import os

/// Reaches apps that publish Now Playing information but expose no scripting
/// interface — browsers, iOS apps running on macOS, most streaming clients.
///
/// MediaRemote is the mechanism behind Control Center's Now Playing tile and the
/// media keys, but since macOS 15.4 it ignores callers without a private
/// entitlement that third-party apps cannot obtain. It does answer Apple's own
/// binaries, so the actual calls happen inside `/usr/bin/perl`, which loads the
/// small bridge in `MediaRemoteBridge/` and prints the result. See that directory
/// for the details; the technique comes from ungive/mediaremote-adapter.
///
/// Consequences worth knowing:
/// - Only one app is reachable at a time: whichever owns the Now Playing session.
///   That is the correct app rather than a guess, so the button lands on the right
///   row, but a second paused player stays out of reach.
/// - This leans on a private framework. If a macOS update closes the door, the
///   bridge stops returning data and every app it covered quietly loses its
///   button. Nothing else in FineTune is affected.
actor MediaRemotePlaybackAdapter: PlaybackControlling {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FineTune",
        category: "MediaRemoteAdapter"
    )

    private let scriptURL: URL
    private let libraryURL: URL

    /// Set once the bridge fails in a way that will not fix itself — a missing
    /// resource, or an OS that no longer answers. Avoids respawning perl on a poll
    /// for something that cannot succeed.
    private var isDisabled = false

    /// How long the helper gets before it is killed. Its own internal waits are
    /// two seconds, so anything beyond this is a hang.
    private static let helperTimeout: TimeInterval = 5

    init?(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return nil }
        let script = resources.appendingPathComponent("nowplaying.pl")
        let library = resources.appendingPathComponent("libFineTuneNowPlaying.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: library.path)
        else { return nil }

        self.scriptURL = script
        self.libraryURL = library
    }

    // MARK: - PlaybackControlling

    func reachableStates(among runningBundleIDs: Set<String>) async -> [String: PlaybackState] {
        guard !isDisabled, let output = run("get") else { return [:] }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", let data = trimmed.data(using: .utf8) else { return [:] }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundleID = payload["bundleIdentifier"] as? String,
              let playing = payload["playing"] as? Bool
        else {
            logger.debug("Unexpected bridge payload: \(trimmed, privacy: .public)")
            return [:]
        }

        // The Now Playing session can outlive the app that owned it; only report
        // apps that are actually running, matching every other row in the popup.
        guard runningBundleIDs.contains(bundleID) else { return [:] }

        return [bundleID: playing ? .playing : .paused]
    }

    func playPause(bundleID: String) async {
        guard !isDisabled else { return }
        // The bundle ID is passed so the bridge can drop the command if the Now
        // Playing session moved to another app between the poll and the click.
        _ = run("toggle", argument: bundleID)
    }

    // MARK: - Helper process

    private func run(_ command: String, argument: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, libraryURL.path, command] + (argument.map { [$0] } ?? [])

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Could not start the MediaRemote bridge: \(error.localizedDescription)")
            isDisabled = true
            return nil
        }

        // The helper bounds its own waits, so a process still alive past the
        // timeout is wedged and gets killed rather than blocking the poll.
        let watchdog = DispatchWorkItem { [weak process] in
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.helperTimeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
