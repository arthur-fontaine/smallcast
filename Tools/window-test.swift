// Standalone test for the window-arrangement geometry — compiles the *real* CoreGraphics-only sources (no copy to sync): swiftc Smallcast/Core/WindowManagement/{WindowAction,WindowGeometry}.swift Tools/window-test.swift -o /tmp/window-test && /tmp/window-test

import CoreGraphics
import Foundation

@main
struct WindowTests {
    static var failures = 0
    static var passes = 0

    /// A 1600×1000 screen whose usable area starts 40pt down (menu bar), in Accessibility space.
    static let screen = CGRect(x: 0, y: 40, width: 1600, height: 960)
    /// An arbitrary window sitting in the middle of it.
    static let window = CGRect(x: 500, y: 300, width: 600, height: 400)

    static func main() {
        // Halves
        expect(.leftHalf, CGRect(x: 0, y: 40, width: 800, height: 960))
        expect(.rightHalf, CGRect(x: 800, y: 40, width: 800, height: 960))
        expect(.topHalf, CGRect(x: 0, y: 40, width: 1600, height: 480))
        expect(.bottomHalf, CGRect(x: 0, y: 520, width: 1600, height: 480))

        // Whole screen
        expect(.maximize, screen)
        expect(.almostMaximize, CGRect(x: 80, y: 88, width: 1440, height: 864))
        expect(.reasonableSize, CGRect(x: 320, y: 232, width: 960, height: 576))
        expect(.maximizeWidth, CGRect(x: 0, y: 300, width: 1600, height: 400))
        expect(.maximizeHeight, CGRect(x: 500, y: 40, width: 600, height: 960))
        expect(.center, CGRect(x: 500, y: 320, width: 600, height: 400))

        // Reasonable Size is capped, so a very wide screen doesn't get a 60% monster
        expectFrame(
            .reasonableSize, window: window,
            visible: CGRect(x: 0, y: 0, width: 5120, height: 2880),
            expected: CGRect(x: 2047.5, y: 990, width: 1025, height: 900))

        // Thirds / fourths
        expect(.firstThird, CGRect(x: 0, y: 40, width: 1600.0 / 3, height: 960))
        expect(.centerThird, CGRect(x: 1600.0 / 3, y: 40, width: 1600.0 / 3, height: 960))
        expect(.lastThird, CGRect(x: 3200.0 / 3, y: 40, width: 1600.0 / 3, height: 960))
        expect(.firstTwoThirds, CGRect(x: 0, y: 40, width: 3200.0 / 3, height: 960))
        expect(.lastTwoThirds, CGRect(x: 1600.0 / 3, y: 40, width: 3200.0 / 3, height: 960))
        expect(.firstFourth, CGRect(x: 0, y: 40, width: 400, height: 960))
        expect(.secondFourth, CGRect(x: 400, y: 40, width: 400, height: 960))
        expect(.thirdFourth, CGRect(x: 800, y: 40, width: 400, height: 960))
        expect(.lastFourth, CGRect(x: 1200, y: 40, width: 400, height: 960))

        // Quarters & sixths (y grows downward, so "top" is the smaller y)
        expect(.topLeftQuarter, CGRect(x: 0, y: 40, width: 800, height: 480))
        expect(.topRightQuarter, CGRect(x: 800, y: 40, width: 800, height: 480))
        expect(.bottomLeftQuarter, CGRect(x: 0, y: 520, width: 800, height: 480))
        expect(.bottomRightQuarter, CGRect(x: 800, y: 520, width: 800, height: 480))
        expect(.topLeftSixth, CGRect(x: 0, y: 40, width: 1600.0 / 3, height: 480))
        expect(.topCenterSixth, CGRect(x: 1600.0 / 3, y: 40, width: 1600.0 / 3, height: 480))
        expect(.topRightSixth, CGRect(x: 3200.0 / 3, y: 40, width: 1600.0 / 3, height: 480))
        expect(.bottomLeftSixth, CGRect(x: 0, y: 520, width: 1600.0 / 3, height: 480))
        expect(.bottomCenterSixth, CGRect(x: 1600.0 / 3, y: 520, width: 1600.0 / 3, height: 480))
        expect(.bottomRightSixth, CGRect(x: 3200.0 / 3, y: 520, width: 1600.0 / 3, height: 480))

        // Moving keeps the size and lands on the edge
        expect(.moveLeft, CGRect(x: 0, y: 300, width: 600, height: 400))
        expect(.moveRight, CGRect(x: 1000, y: 300, width: 600, height: 400))
        expect(.moveUp, CGRect(x: 500, y: 40, width: 600, height: 400))
        expect(.moveDown, CGRect(x: 500, y: 600, width: 600, height: 400))

        // Resizing steps by 5% of the screen, around the window's centre
        expect(.makeLarger, CGRect(x: 460, y: 276, width: 680, height: 448))
        expect(.makeSmaller, CGRect(x: 540, y: 324, width: 520, height: 352))

        // Shrinking stops at the minimum and growing at the screen
        expectFrame(
            .makeSmaller, window: CGRect(x: 700, y: 400, width: 250, height: 170),
            visible: screen, expected: CGRect(x: 705, y: 405, width: 240, height: 160))
        expectFrame(
            .makeLarger, window: CGRect(x: 20, y: 60, width: 1580, height: 950),
            visible: screen, expected: screen)

        // Gaps: outer margin `gap`, and exactly `gap` between two neighbouring tiles
        let gapped = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        expectFrame(
            .leftHalf, window: window, visible: gapped, gap: 10,
            expected: CGRect(x: 10, y: 10, width: 485, height: 980))
        expectFrame(
            .rightHalf, window: window, visible: gapped, gap: 10,
            expected: CGRect(x: 505, y: 10, width: 485, height: 980))
        expectFrame(
            .maximize, window: window, visible: gapped, gap: 10,
            expected: CGRect(x: 10, y: 10, width: 980, height: 980))

        // Non-geometric actions are the manager's business, not the geometry's
        for action in [WindowAction.restore, .toggleFullscreen, .previousDisplay, .nextDisplay] {
            if WindowGeometry.frame(for: action, window: window, visible: screen, gap: 0) != nil {
                fail(action.rawValue, expected: "nil", got: "a frame")
            } else {
                passes += 1
            }
        }

        // Moving to another display keeps the window's proportions
        let external = CGRect(x: 1600, y: 0, width: 3200, height: 1920)
        expectRect(
            "transposed left half",
            WindowGeometry.transposed(
                CGRect(x: 0, y: 40, width: 800, height: 960), from: screen, to: external),
            CGRect(x: 1600, y: 0, width: 1600, height: 1920))

        // Every action has a title, a symbol and a round-tripping entry id
        for action in WindowAction.allCases {
            if action.title.isEmpty || action.sfSymbol.isEmpty {
                fail(action.rawValue, expected: "title + symbol", got: "empty")
            } else if WindowAction(entryID: action.entryID) != action {
                fail(action.rawValue, expected: "round-trips via entryID", got: action.entryID)
            } else {
                passes += 1
            }
        }
        if Set(WindowAction.allCases.map(\.title)).count != WindowAction.allCases.count {
            fail("titles", expected: "unique", got: "duplicates")
        } else {
            passes += 1
        }

        print(failures == 0 ? "\nAll \(passes) checks passed." : "\n\(failures) failure(s), \(passes) passed.")
        exit(failures == 0 ? 0 : 1)
    }

    static func expect(_ action: WindowAction, _ expected: CGRect) {
        expectFrame(action, window: window, visible: screen, expected: expected)
    }

    static func expectFrame(
        _ action: WindowAction, window: CGRect, visible: CGRect, gap: CGFloat = 0,
        expected: CGRect
    ) {
        guard let got = WindowGeometry.frame(for: action, window: window, visible: visible, gap: gap)
        else {
            fail(action.rawValue, expected: "\(expected)", got: "nil")
            return
        }
        expectRect(action.rawValue, got, expected)
    }

    static func expectRect(_ label: String, _ got: CGRect, _ expected: CGRect) {
        let close = abs(got.minX - expected.minX) < 0.001 && abs(got.minY - expected.minY) < 0.001
            && abs(got.width - expected.width) < 0.001 && abs(got.height - expected.height) < 0.001
        if close {
            passes += 1
        } else {
            fail(label, expected: "\(expected)", got: "\(got)")
        }
    }

    static func fail(_ label: String, expected: String, got: String) {
        failures += 1
        print("FAIL  \(label)\n      expected: \(expected)\n      got:      \(got)")
    }
}
