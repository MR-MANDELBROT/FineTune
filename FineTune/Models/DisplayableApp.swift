// FineTune/Models/DisplayableApp.swift
import AppKit
import UniformTypeIdentifiers

/// Represents an app that can be displayed in the UI: actively producing audio,
/// pinned but inactive, or idle — holding a CoreAudio process object without
/// currently running IO, which is what a paused media app looks like.
enum DisplayableApp: Identifiable {
    case active(AudioApp)
    case pinnedInactive(PinnedAppInfo)
    case idle(AudioApp)

    var id: String {
        switch self {
        case .active(let app):
            return app.persistenceIdentifier
        case .pinnedInactive(let info):
            return info.persistenceIdentifier
        case .idle(let app):
            return app.persistenceIdentifier
        }
    }

    /// Whether this app is shown without currently producing audio. Both the pinned
    /// and the idle case render through `InactiveAppRow`.
    var isInactive: Bool {
        switch self {
        case .active:
            return false
        case .pinnedInactive, .idle:
            return true
        }
    }

    /// Whether this represents a pinned-but-inactive app.
    /// Note: Active apps may also be pinned - check the pinned list directly for that case.
    var isPinnedInactive: Bool {
        switch self {
        case .active, .idle:
            return false
        case .pinnedInactive:
            return true
        }
    }

    var isActive: Bool {
        switch self {
        case .active:
            return true
        case .pinnedInactive, .idle:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .active(let app):
            return app.name
        case .pinnedInactive(let info):
            return info.displayName
        case .idle(let app):
            return app.name
        }
    }

    var icon: NSImage {
        switch self {
        case .active(let app):
            return app.icon
        case .pinnedInactive(let info):
            return Self.loadIcon(bundleID: info.bundleID)
        case .idle(let app):
            return app.icon
        }
    }

    /// Bundle identifier, where known — used to resolve playback control.
    var bundleID: String? {
        switch self {
        case .active(let app):
            return app.bundleID
        case .pinnedInactive(let info):
            return info.bundleID
        case .idle(let app):
            return app.bundleID
        }
    }

    /// Loads the app icon from a bundle ID, or returns a generic placeholder.
    static func loadIcon(bundleID: String?) -> NSImage {
        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
