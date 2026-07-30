import Foundation

/// Every window-arrangement command, mirroring Raycast's Window Management set. Foundation-only (the
/// `Tools/window-test.swift` harness compiles this together with `WindowGeometry`); the AX plumbing
/// lives in `WindowManager`.
enum WindowAction: String, CaseIterable, Sendable {
    // Halves
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    // Whole screen
    case maximize
    case almostMaximize = "almost-maximize"
    case maximizeWidth = "maximize-width"
    case maximizeHeight = "maximize-height"
    case reasonableSize = "reasonable-size"
    case center
    case toggleFullscreen = "toggle-fullscreen"
    // Thirds
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds"
    case lastTwoThirds = "last-two-thirds"
    // Fourths (vertical strips)
    case firstFourth = "first-fourth"
    case secondFourth = "second-fourth"
    case thirdFourth = "third-fourth"
    case lastFourth = "last-fourth"
    // Quarters
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    // Sixths
    case topLeftSixth = "top-left-sixth"
    case topCenterSixth = "top-center-sixth"
    case topRightSixth = "top-right-sixth"
    case bottomLeftSixth = "bottom-left-sixth"
    case bottomCenterSixth = "bottom-center-sixth"
    case bottomRightSixth = "bottom-right-sixth"
    // Move & resize in place
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case makeSmaller = "make-smaller"
    case makeLarger = "make-larger"
    // Displays
    case previousDisplay = "previous-display"
    case nextDisplay = "next-display"
    case restore

    /// Raycast's own command names — the launcher rows read the same as what users already know.
    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .maximizeWidth: return "Maximize Width"
        case .maximizeHeight: return "Maximize Height"
        case .reasonableSize: return "Reasonable Size"
        case .center: return "Center"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .firstFourth: return "First Fourth"
        case .secondFourth: return "Second Fourth"
        case .thirdFourth: return "Third Fourth"
        case .lastFourth: return "Last Fourth"
        case .topLeftQuarter: return "Top Left Quarter"
        case .topRightQuarter: return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter: return "Bottom Right Quarter"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .makeSmaller: return "Make Smaller"
        case .makeLarger: return "Make Larger"
        case .previousDisplay: return "Move to Previous Display"
        case .nextDisplay: return "Move to Next Display"
        case .restore: return "Restore Window Size"
        }
    }

    var sfSymbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: return "rectangle.inset.filled"
        case .maximizeWidth: return "arrow.left.and.right"
        case .maximizeHeight: return "arrow.up.and.down"
        case .reasonableSize: return "rectangle.center.inset.filled"
        case .center: return "square.on.square.squareshape.controlhandles"
        case .toggleFullscreen: return "arrow.up.backward.and.arrow.down.forward"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            return "rectangle.split.3x1"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth:
            return "rectangle.split.3x1"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return "rectangle.split.2x2"
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
            .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            return "rectangle.split.3x2"
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveUp: return "arrow.up"
        case .moveDown: return "arrow.down"
        case .makeSmaller: return "minus.magnifyingglass"
        case .makeLarger: return "plus.magnifyingglass"
        case .previousDisplay, .nextDisplay: return "display.2"
        case .restore: return "arrow.uturn.backward"
        }
    }

    /// Launcher entry id — the `command:` prefix keeps these inside the existing `.command` plumbing.
    var entryID: String { "command:window:" + rawValue }

    init?(entryID: String) {
        let prefix = "command:window:"
        guard entryID.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(entryID.dropFirst(prefix.count)))
    }

    /// UserDefaults key holding this action's shortcut JSON — the `KeyboardShortcuts_` prefix matches
    /// every other binding (see `HotKeyAction.defaultsKey`).
    var defaultsKey: String { "KeyboardShortcuts_window." + rawValue }
}
