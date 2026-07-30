import CoreGraphics

/// The pure geometry behind every window command: given the window's current frame and the target
/// screen's usable area, where should the window end up. Kept free of AppKit / Accessibility so
/// `Tools/window-test.swift` can compile it standalone (`WindowManager` owns all the AX plumbing).
///
/// Every rect here is in **Accessibility space**: origin top-left, y growing downward — the space
/// `kAXPositionAttribute` uses, so no flipping happens between here and the window server.
enum WindowGeometry {
    /// Smallest window a resize command will produce; below that a window is unusable.
    static let minimumSize = CGSize(width: 240, height: 160)

    /// One "Make Smaller" / "Make Larger" step, as a fraction of the screen's usable size.
    static let resizeStep: CGFloat = 0.05

    /// Raycast's Reasonable Size: 60% of the screen, capped so it stays reasonable on a large display.
    static let reasonableFraction: CGFloat = 0.6
    static let reasonableCap = CGSize(width: 1025, height: 900)

    /// Almost Maximize leaves a visible margin all around instead of filling the screen.
    static let almostMaximizeFraction: CGFloat = 0.9

    /// The frame `action` wants, or nil when the action isn't a geometry change (fullscreen, restore,
    /// display switching — `WindowManager` handles those). `gap` is the spacing kept to the screen
    /// edges and between two tiled windows.
    static func frame(for action: WindowAction, window: CGRect, visible: CGRect, gap: CGFloat)
        -> CGRect?
    {
        let area = usableArea(visible, gap: gap)
        guard area.width > 0, area.height > 0 else { return nil }

        func tile(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            tileFrame(x: x, y: y, width: width, height: height, in: area, gap: gap)
        }

        switch action {
        case .leftHalf: return tile(0, 0, 1 / 2, 1)
        case .rightHalf: return tile(1 / 2, 0, 1 / 2, 1)
        case .topHalf: return tile(0, 0, 1, 1 / 2)
        case .bottomHalf: return tile(0, 1 / 2, 1, 1 / 2)
        case .maximize: return tile(0, 0, 1, 1)

        case .almostMaximize:
            return centered(
                CGSize(
                    width: area.width * almostMaximizeFraction,
                    height: area.height * almostMaximizeFraction), in: area)

        case .reasonableSize:
            return centered(
                CGSize(
                    width: min(area.width * reasonableFraction, reasonableCap.width),
                    height: min(area.height * reasonableFraction, reasonableCap.height)), in: area)

        case .maximizeWidth:
            return clamped(
                CGRect(x: area.minX, y: window.minY, width: area.width, height: window.height),
                in: area)

        case .maximizeHeight:
            return clamped(
                CGRect(x: window.minX, y: area.minY, width: window.width, height: area.height),
                in: area)

        case .center:
            return centered(window.size, in: area)

        case .firstThird: return tile(0, 0, 1 / 3, 1)
        case .centerThird: return tile(1 / 3, 0, 1 / 3, 1)
        case .lastThird: return tile(2 / 3, 0, 1 / 3, 1)
        case .firstTwoThirds: return tile(0, 0, 2 / 3, 1)
        case .lastTwoThirds: return tile(1 / 3, 0, 2 / 3, 1)

        case .firstFourth: return tile(0, 0, 1 / 4, 1)
        case .secondFourth: return tile(1 / 4, 0, 1 / 4, 1)
        case .thirdFourth: return tile(2 / 4, 0, 1 / 4, 1)
        case .lastFourth: return tile(3 / 4, 0, 1 / 4, 1)

        case .topLeftQuarter: return tile(0, 0, 1 / 2, 1 / 2)
        case .topRightQuarter: return tile(1 / 2, 0, 1 / 2, 1 / 2)
        case .bottomLeftQuarter: return tile(0, 1 / 2, 1 / 2, 1 / 2)
        case .bottomRightQuarter: return tile(1 / 2, 1 / 2, 1 / 2, 1 / 2)

        case .topLeftSixth: return tile(0, 0, 1 / 3, 1 / 2)
        case .topCenterSixth: return tile(1 / 3, 0, 1 / 3, 1 / 2)
        case .topRightSixth: return tile(2 / 3, 0, 1 / 3, 1 / 2)
        case .bottomLeftSixth: return tile(0, 1 / 2, 1 / 3, 1 / 2)
        case .bottomCenterSixth: return tile(1 / 3, 1 / 2, 1 / 3, 1 / 2)
        case .bottomRightSixth: return tile(2 / 3, 1 / 2, 1 / 3, 1 / 2)

        case .moveLeft:
            return clamped(CGRect(origin: CGPoint(x: area.minX, y: window.minY), size: window.size), in: area)
        case .moveRight:
            return clamped(
                CGRect(
                    origin: CGPoint(x: area.maxX - window.width, y: window.minY), size: window.size),
                in: area)
        case .moveUp:
            return clamped(CGRect(origin: CGPoint(x: window.minX, y: area.minY), size: window.size), in: area)
        case .moveDown:
            return clamped(
                CGRect(
                    origin: CGPoint(x: window.minX, y: area.maxY - window.height), size: window.size),
                in: area)

        case .makeSmaller: return resized(window, by: -resizeStep, in: area)
        case .makeLarger: return resized(window, by: resizeStep, in: area)

        case .toggleFullscreen, .previousDisplay, .nextDisplay, .restore:
            return nil
        }
    }

    /// The same window on another screen: its position and size are kept proportional, so a half-screen
    /// window stays a half-screen window across displays of different sizes.
    static func transposed(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return window }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let moved = CGRect(
            x: target.minX + (window.minX - source.minX) * scaleX,
            y: target.minY + (window.minY - source.minY) * scaleY,
            width: window.width * scaleX,
            height: window.height * scaleY)
        return clamped(moved, in: target)
    }

    /// The screen area commands tile into: the visible frame minus the configured gap on every edge.
    static func usableArea(_ visible: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0, visible.width > gap * 2, visible.height > gap * 2 else { return visible }
        return visible.insetBy(dx: gap, dy: gap)
    }

    /// A fractional cell of `area`, with half the gap taken off each edge shared with a neighbouring
    /// tile — so two tiled windows end up exactly `gap` apart, matching their distance to the edges.
    private static func tileFrame(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in area: CGRect, gap: CGFloat
    ) -> CGRect {
        let half = gap / 2
        let leadingInset = x > 0 ? half : 0
        let trailingInset = x + width < 1 ? half : 0
        let topInset = y > 0 ? half : 0
        let bottomInset = y + height < 1 ? half : 0
        return CGRect(
            x: area.minX + area.width * x + leadingInset,
            y: area.minY + area.height * y + topInset,
            width: max(1, area.width * width - leadingInset - trailingInset),
            height: max(1, area.height * height - topInset - bottomInset))
    }

    private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(
            x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// Grow or shrink around the window's centre, never past the screen or below `minimumSize`.
    private static func resized(_ window: CGRect, by step: CGFloat, in area: CGRect) -> CGRect {
        let width = clamp(
            window.width + area.width * step,
            min: min(minimumSize.width, area.width), max: area.width)
        let height = clamp(
            window.height + area.height * step,
            min: min(minimumSize.height, area.height), max: area.height)
        let frame = CGRect(
            x: window.midX - width / 2, y: window.midY - height / 2, width: width, height: height)
        return clamped(frame, in: area)
    }

    /// Keep the frame fully inside `area`, shrinking it only when it genuinely doesn't fit.
    private static func clamped(_ frame: CGRect, in area: CGRect) -> CGRect {
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        return CGRect(
            x: clamp(frame.minX, min: area.minX, max: area.maxX - width),
            y: clamp(frame.minY, min: area.minY, max: area.maxY - height),
            width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
