import AppKit
import SwiftUI

/// A native-looking stand-in for whatever icon an extension shipped: an SF Symbol from a curated set,
/// on a tinted tile. Chosen in Settings › Extensions, applied to every command of that extension.
struct ExtensionAppearance: Codable, Equatable, Hashable, Sendable {
    var symbol: String
    var tint: ExtensionTint

    static let fallback = ExtensionAppearance(symbol: "puzzlepiece.extension", tint: .purple)
}

/// The tile colours on offer — the same family the Settings sidebar uses, so an overridden extension
/// looks like it belongs rather than like a sticker.
enum ExtensionTint: String, CaseIterable, Identifiable, Codable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray

    var id: String { rawValue }

    /// Fixed sRGB, not the system colours: the tile is rasterized off the main thread, where a dynamic
    /// colour would resolve against whatever appearance that thread happens to see. Pinning the values
    /// also guarantees the picker's SwiftUI preview and the drawn bitmap are the same colour. These are
    /// Apple's dark-mode system values, which is the only appearance the app runs in.
    private var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blue: return (0.04, 0.52, 1.00)
        case .indigo: return (0.37, 0.36, 0.90)
        case .purple: return (0.75, 0.35, 0.95)
        case .pink: return (1.00, 0.22, 0.37)
        case .red: return (1.00, 0.27, 0.23)
        case .orange: return (1.00, 0.62, 0.04)
        case .yellow: return (1.00, 0.84, 0.04)
        case .green: return (0.20, 0.84, 0.29)
        case .mint: return (0.40, 0.83, 0.81)
        case .teal: return (0.25, 0.78, 0.88)
        case .gray: return (0.60, 0.60, 0.62)
        }
    }

    var color: Color {
        let rgb = components
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// What `IconCache` actually draws with — the same values, as AppKit sees them.
    var nsColor: NSColor {
        let rgb = components
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

/// The icons users can pick from. Deliberately a fixed set: a curated list keeps every extension
/// looking like part of the app, and sidesteps custom-image plumbing (sizing, caching, dead files).
enum ExtensionSymbols {
    /// Filtered once against the running system, so a symbol missing on this macOS never shows up as an
    /// empty tile in the picker.
    static let all: [String] = catalog.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    private static let catalog = [
        // Status & power
        "bolt.fill", "cup.and.saucer.fill", "moon.fill", "sun.max.fill", "power", "battery.100",
        "eye.fill", "bell.fill", "sparkles", "wand.and.stars",
        // Time
        "calendar", "clock.fill", "timer", "hourglass", "alarm.fill",
        // Text & documents
        "doc.text.fill", "text.alignleft", "checklist", "list.bullet", "note.text",
        "folder.fill", "tray.full.fill", "archivebox.fill", "book.fill", "bookmark.fill",
        // Communication
        "envelope.fill", "message.fill", "paperplane.fill", "phone.fill", "video.fill",
        "person.2.fill", "bubble.left.and.bubble.right.fill",
        // Media
        "music.note", "speaker.wave.2.fill", "headphones", "photo.fill", "camera.fill",
        "play.fill", "pause.fill", "paintbrush.fill", "theatermasks.fill",
        // Developer
        "terminal.fill", "chevron.left.forwardslash.chevron.right", "hammer.fill",
        "wrench.and.screwdriver.fill", "ant.fill", "cpu", "memorychip", "externaldrive.fill",
        "server.rack", "shippingbox.fill",
        // System & network
        "gearshape.fill", "slider.horizontal.3", "network", "globe", "link", "wifi",
        "display", "keyboard", "cursorarrow.rays", "square.grid.2x2.fill",
        // Security & money
        "lock.fill", "key.fill", "shield.fill", "creditcard.fill", "cart.fill", "banknote.fill",
        // Data
        "chart.bar.fill", "chart.pie.fill", "function", "number", "brain",
        // Places & things
        "star.fill", "heart.fill", "flag.fill", "tag.fill", "map.fill", "location.fill",
        "airplane", "car.fill", "leaf.fill", "flame.fill", "drop.fill", "snowflake",
        "cloud.fill", "gift.fill", "trash.fill", "arrow.triangle.2.circlepath",
    ]
}

/// Persists the per-extension icon overrides. Keyed by manifest name, the same key
/// `ExtensionStorage` uses for preferences, so uninstalling and reinstalling keeps the choice.
@MainActor
final class ExtensionAppearanceStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private let key = "extensionAppearances"

    @Published private(set) var overrides: [String: ExtensionAppearance]

    init() {
        if let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: ExtensionAppearance].self, from: data)
        {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    func appearance(for extensionName: String) -> ExtensionAppearance? {
        overrides[extensionName]
    }

    /// `nil` restores the extension's own icon.
    func set(_ appearance: ExtensionAppearance?, for extensionName: String) {
        if let appearance {
            overrides[extensionName] = appearance
        } else {
            overrides.removeValue(forKey: extensionName)
        }
        persist()
    }

    /// Replace the whole map at once (used when importing a settings backup).
    func replace(_ newOverrides: [String: ExtensionAppearance]) {
        overrides = newOverrides
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: key)
    }
}
