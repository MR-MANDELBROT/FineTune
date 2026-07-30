// FineTuneTests/IdleAppDisplayTests.swift
//
// Verifies idle apps reach the popup list without duplicating apps that are already
// on screen, and that they stay display-only.

import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("Idle app display")
@MainActor
struct IdleAppDisplayTests {
    private func makeApp(pid: pid_t, name: String, bundleID: String) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: [],
            name: name,
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: bundleID
        )
    }

    private func makeEngine(
        active: [AudioApp],
        idle: [AudioApp]
    ) -> (AudioEngine, SettingsManager) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let monitor = StubProcessMonitor()
        monitor.activeApps = active
        monitor.idleApps = idle

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            processMonitor: monitor,
            deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: deviceMonitor),
            startMonitorsAutomatically: false
        )
        return (engine, settings)
    }

    @Test("idle apps are listed after active ones")
    func idleAppsComeLast() {
        let (engine, _) = makeEngine(
            active: [makeApp(pid: 1, name: "Zed", bundleID: "com.test.active")],
            idle: [makeApp(pid: 2, name: "Alpha", bundleID: "com.test.idle")]
        )

        let ids = engine.displayableApps.map(\.id)

        #expect(ids == ["com.test.active", "com.test.idle"])
    }

    @Test("an app that is active and idle at once appears only once")
    func activeAndIdleDoesNotDuplicate() {
        let app = makeApp(pid: 1, name: "Safari", bundleID: "com.test.both")
        // Mirrors Safari: its media helper runs while the main process sits idle.
        let (engine, _) = makeEngine(
            active: [app],
            idle: [makeApp(pid: 2, name: "Safari", bundleID: "com.test.both")]
        )

        let ids = engine.displayableApps.map(\.id)

        #expect(ids == ["com.test.both"])
    }

    @Test("idle apps disappear when the setting is off")
    func settingHidesIdleApps() {
        let (engine, settings) = makeEngine(
            active: [],
            idle: [makeApp(pid: 2, name: "Alpha", bundleID: "com.test.idle")]
        )
        #expect(engine.displayableApps.count == 1)

        settings.appSettings.showIdleApps = false

        #expect(engine.displayableApps.isEmpty)
    }

    @Test("ignored idle apps stay hidden")
    func ignoredIdleAppsStayHidden() {
        let idle = makeApp(pid: 2, name: "Alpha", bundleID: "com.test.idle")
        let (engine, settings) = makeEngine(active: [], idle: [idle])

        settings.ignoreApp(
            idle.persistenceIdentifier,
            info: IgnoredAppInfo(
                persistenceIdentifier: idle.persistenceIdentifier,
                displayName: idle.name,
                bundleID: idle.bundleID
            )
        )

        #expect(engine.displayableApps.isEmpty)
    }

    @Test("a pinned app is not also listed as idle")
    func pinnedAppsAreNotDuplicated() {
        let idle = makeApp(pid: 2, name: "Alpha", bundleID: "com.test.idle")
        let (engine, settings) = makeEngine(active: [], idle: [idle])

        settings.pinApp(
            idle.persistenceIdentifier,
            info: PinnedAppInfo(
                persistenceIdentifier: idle.persistenceIdentifier,
                displayName: idle.name,
                bundleID: idle.bundleID
            )
        )

        let entries = engine.displayableApps
        #expect(entries.count == 1)
        #expect(entries.first?.isPinnedInactive == true)
    }

    @Test("idle apps never reach the tap-provisioning list")
    func idleAppsAreDisplayOnly() {
        let (engine, _) = makeEngine(
            active: [makeApp(pid: 1, name: "Active", bundleID: "com.test.active")],
            idle: [makeApp(pid: 2, name: "Idle", bundleID: "com.test.idle")]
        )

        // `apps` is what drives tap creation and routing — idle apps must stay out.
        #expect(engine.apps.map(\.persistenceIdentifier) == ["com.test.active"])
    }
}
