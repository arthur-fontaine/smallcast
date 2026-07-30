import AppKit
// `@preconcurrency` downgrades the AX concurrency diagnostics: the `kAX…Attribute` globals are mutable
// C strings but process-constant, and every AX call here stays on the main actor.
@preconcurrency import ApplicationServices

/// Applies `WindowAction`s to another app's focused window over the Accessibility API.
///
/// Everything geometric is delegated to `WindowGeometry`; this type only resolves the window, converts
/// between Cocoa and Accessibility coordinates, and remembers frames so `Restore` can undo.
@MainActor
final class WindowManager {
    /// Frames captured before the last arrangement, keyed by pid + window title so each window gets its
    /// own undo. Titles aren't unique across an app's windows, which is the accepted approximation —
    /// the alternative is the private `_AXUIElementGetWindow` id.
    private var restoreFrames: [String: CGRect] = [:]
    private var restoreOrder: [String] = []
    private let restoreLimit = 40

    /// Gap kept to the screen edges and between two tiled windows, read at use time so a change in
    /// Settings applies to the very next command with nothing to wire up.
    private var gap: CGFloat {
        CGFloat(UserDefaults.standard.integer(forKey: SettingsKey.windowGap))
    }

    /// Runs `action` against `app`'s focused window, returning a user-facing message when it couldn't —
    /// the caller surfaces that as a HUD. `nil` means the window was arranged.
    @discardableResult
    func perform(_ action: WindowAction, on app: NSRunningApplication?) -> String? {
        guard Permissions.ensureAccessibility() else {
            return "Smallcast needs Accessibility access to move windows."
        }
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "No window to arrange."
        }
        guard let window = focusedWindow(pid: app.processIdentifier) else {
            return "\(app.localizedName ?? "That app") has no window to arrange."
        }

        switch action {
        case .toggleFullscreen:
            setFullscreen(!isFullscreen(window), on: window)
            return nil
        case .restore:
            guard let previous = restoreFrames.removeValue(forKey: key(pid: app.processIdentifier, window: window))
            else { return "Nothing to restore for this window." }
            apply(previous, to: window)
            return nil
        case .previousDisplay, .nextDisplay:
            return moveToAdjacentDisplay(window, forward: action == .nextDisplay)
        default:
            break
        }

        guard let current = frame(of: window) else { return "That window can't be moved." }
        guard let screen = screen(containing: current) else { return "That window can't be moved." }
        guard
            let target = WindowGeometry.frame(
                for: action, window: current, visible: visibleAXFrame(of: screen), gap: gap)
        else { return "That window can't be moved." }

        rememberFrame(current, pid: app.processIdentifier, window: window)

        // A fullscreen window ignores position/size writes; leave fullscreen first and let the system
        // finish its animation before arranging.
        if isFullscreen(window) {
            setFullscreen(false, on: window)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.apply(target, to: window)
            }
            return nil
        }

        apply(target, to: window)
        return nil
    }

    /// Wipes the undo history — the setting was turned off, so nothing stale survives a re-enable.
    func forgetRestoreHistory() {
        restoreFrames.removeAll()
        restoreOrder.removeAll()
    }

    // MARK: - Displays

    private func moveToAdjacentDisplay(_ window: AXUIElement, forward: Bool) -> String? {
        let screens = orderedScreens()
        guard screens.count > 1 else { return "Only one display is connected." }
        guard let current = frame(of: window), let source = screen(containing: current),
            let index = screens.firstIndex(of: source)
        else { return "That window can't be moved." }

        let target = screens[(index + (forward ? 1 : screens.count - 1)) % screens.count]
        let moved = WindowGeometry.transposed(
            current, from: visibleAXFrame(of: source), to: visibleAXFrame(of: target))
        apply(moved, to: window)
        return nil
    }

    /// Left-to-right, then top-to-bottom — cycling follows the physical arrangement rather than the
    /// order the system happens to report.
    private func orderedScreens() -> [NSScreen] {
        NSScreen.screens.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }

    /// The screen holding most of the window, falling back to the main one for an off-screen window.
    private func screen(containing frame: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = fullAXFrame(of: screen).intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Coordinate conversion

    /// Cocoa screen coordinates are y-up from the primary display's bottom-left; the Accessibility API
    /// is y-down from its top-left.
    private func axRect(_ rect: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func visibleAXFrame(of screen: NSScreen) -> CGRect { axRect(screen.visibleFrame) }
    private func fullAXFrame(of screen: NSScreen) -> CGRect { axRect(screen.frame) }

    // MARK: - Accessibility plumbing

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let window = element(app, attribute: kAXFocusedWindowAttribute) { return window }
        // Some apps don't publish a focused window (nothing key in that app); fall back to its first.
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first
    }

    private func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again: a window pinned against the old screen edge would clamp a
    /// single size write, and one pass of each isn't enough for apps with size steps (terminals).
    private func apply(_ frame: CGRect, to window: AXUIElement) {
        setSize(frame.size, on: window)
        setPosition(frame.origin, on: window)
        setSize(frame.size, on: window)
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, Self.fullscreenAttribute, &value) == .success
        else { return false }
        return (value as? Bool) ?? false
    }

    private func setFullscreen(_ fullscreen: Bool, on window: AXUIElement) {
        AXUIElementSetAttributeValue(
            window, Self.fullscreenAttribute, fullscreen ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Not exposed as a `kAX…` constant, but the standard attribute AppKit windows publish.
    private static let fullscreenAttribute = "AXFullScreen" as CFString

    // MARK: - Restore history

    private func rememberFrame(_ frame: CGRect, pid: pid_t, window: AXUIElement) {
        let key = key(pid: pid, window: window)
        if restoreFrames[key] == nil {
            restoreOrder.append(key)
            if restoreOrder.count > restoreLimit {
                restoreFrames.removeValue(forKey: restoreOrder.removeFirst())
            }
        }
        restoreFrames[key] = frame
    }

    private func key(pid: pid_t, window: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return "\(pid):\((value as? String) ?? "")"
    }
}
