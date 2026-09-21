import AppKit
import Carbon.HIToolbox

/// One keyboard event as plain values: what a tap handler decides on, with no `CGEvent` in reach.
struct KeystrokeEvent: Sendable {
    let isKeyDown: Bool
    let isFlagsChanged: Bool
    let keyCode: Int
    let hasCommandOrControl: Bool
    let text: String?
    let eventUserData: Int64
    let secureEventInputEnabled: Bool

    /// Keys that move the caret or leave the field, after which a typed prefix means nothing.
    static let navigationKeyCodes: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab, kVK_LeftArrow, kVK_RightArrow,
        kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete
    ]

    var isNavigationKey: Bool { Self.navigationKeyCodes.contains(keyCode) }
    var isDeleteBackward: Bool { keyCode == kVK_Delete }
}

@MainActor
protocol KeystrokeTapHandling: AnyObject {
    func tapWasDisabled()
    /// A click relocates the caret, so whatever was buffered no longer describes what precedes it.
    func mouseDown()
    func handle(_ event: KeystrokeEvent)
}

enum KeystrokeTapState: Equatable, Sendable {
    case absent
    case disabled
    case active
}

private func keystrokeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.handler?.tapWasDisabled() }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
        MainActor.assumeIsolated { tap.handler?.mouseDown() }
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    var length = 0
    var characters = [UniChar](repeating: 0, count: 16)
    event.keyboardGetUnicodeString(
        maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
    let decoded = KeystrokeEvent(
        isKeyDown: type == .keyDown,
        isFlagsChanged: type == .flagsChanged,
        keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
        hasCommandOrControl: flags.contains(.maskCommand) || flags.contains(.maskControl),
        text: length > 0 ? String(utf16CodeUnits: characters, count: length) : nil,
        eventUserData: event.getIntegerValueField(.eventSourceUserData),
        secureEventInputEnabled: IsSecureEventInputEnabled())
    MainActor.assumeIsolated { tap.handler?.handle(decoded) }
    return Unmanaged.passUnretained(event)
}

/// A listen-only session tap over keys and clicks; the Accessibility grant is all it needs.
@MainActor
final class KeystrokeTap {
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate weak var handler: (any KeystrokeTapHandling)?

    var state: KeystrokeTapState {
        guard let tapPort else { return .absent }
        return CGEvent.tapIsEnabled(tap: tapPort) ? .active : .disabled
    }

    func install(handler: any KeystrokeTapHandling) -> Bool {
        self.handler = handler
        guard tapPort == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: keystrokeTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }

        tapPort = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }

    func reenable() -> Bool {
        guard let tapPort else { return false }
        CGEvent.tapEnable(tap: tapPort, enable: true)
        return CGEvent.tapIsEnabled(tap: tapPort)
    }

    func tearDown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
    }
}
