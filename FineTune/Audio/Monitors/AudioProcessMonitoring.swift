@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var activeApps: [AudioApp] { get }

    /// Apps that own a CoreAudio process object but are not currently running IO —
    /// typically media apps sitting paused. Purely a display surface: unlike
    /// `activeApps` this list never drives tap provisioning or routing.
    var idleApps: [AudioApp] { get }

    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()
}

extension AudioProcessMonitoring {
    /// Default keeps test doubles that only model active apps source-compatible.
    var idleApps: [AudioApp] { [] }
}
