import AppKit

/// Keeps the phrase being typed in other apps, in memory only, so the picker can suggest for it.
@MainActor
@Observable
final class TypedTextRecorder: HealthCheckable, KeystrokeTapHandling {
    enum Status: Equatable, Sendable {
        case off
        case needsAccessibility
        case active
    }

    private(set) var status: Status = .off

    @ObservationIgnored weak var healthTicker: HealthTicker?
    /// Mutated per keystroke from the tap, so it stays untracked; `phrase` is read once per summon.
    @ObservationIgnored private var policy = TypedTextPolicy()
    @ObservationIgnored private var observers: [NotificationToken] = []
    private let tap = KeystrokeTap()
    private let accessibilityTrusted: () -> Bool
    private let now: () -> Date
    private let syntheticEventTag: Int64
    private var isRequested = false

    init(
        accessibilityTrusted: @escaping () -> Bool = Permissions.isAccessibilityTrusted,
        now: @escaping () -> Date = Date.init,
        syntheticEventTag: Int64
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.now = now
        self.syntheticEventTag = syntheticEventTag
    }

    var phrase: String { policy.phrase }

    func start() {
        isRequested = true
        installObserversIfNeeded()
        healthTicker?.subscribe(self)
        syncTap()
    }

    /// Authoritative: the tap goes, and so does everything it recorded.
    func stop() {
        isRequested = false
        healthTicker?.unsubscribe(self)
        observers.removeAll()
        policy.reset()
        tap.tearDown()
        status = .off
    }

    func healthCheck() { syncTap() }

    func tapWasDisabled() {
        policy.reset()
        syncTap()
    }

    func mouseDown() { policy.reset() }

    func handle(_ event: KeystrokeEvent) {
        guard isRequested, status == .active else { return }
        // Typing into the palette or Settings is ours, not the sentence the reader is writing.
        guard NSApp.keyWindow == nil else { return }
        policy.process(
            TypedTextPolicy.classify(
                text: event.text,
                isSynthetic: event.eventUserData == syntheticEventTag,
                secureEventInputEnabled: event.secureEventInputEnabled,
                isKeyDown: event.isKeyDown,
                hasCommandOrControl: event.hasCommandOrControl,
                isNavigationKey: event.isNavigationKey,
                isDeleteBackward: event.isDeleteBackward),
            at: now())
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.policy.reset() }
                },
                center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.tapWasDisabled() }
                },
                center: center)
        ]
    }

    /// Never prompts: the grant is asked for once, from the Settings switch that enabled the feature.
    private func syncTap() {
        guard isRequested, accessibilityTrusted() else {
            tap.tearDown()
            policy.reset()
            status = isRequested ? .needsAccessibility : .off
            return
        }
        switch tap.state {
        case .active:
            status = .active
        case .disabled:
            policy.reset()
            status = tap.reenable() ? .active : .needsAccessibility
        case .absent:
            status = tap.install(handler: self) ? .active : .needsAccessibility
        }
    }
}
