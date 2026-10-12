import Foundation

/// The rail owns ⌘1…⌘5 where it is drawn, or on a screen it opened that has no digits of its own.
@main
@MainActor
struct SpotlightButtonTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func chord(
        glass: Bool = true, compact: Bool = true, buttons: [SpotlightButton] = SpotlightButton.defaults,
        collapsed: Bool = true, mode: PaletteMode = .launcher, index: Int
    ) -> SpotlightButtonChord? {
        SpotlightButtonChord.resolve(
            isLiquidGlass: glass, compactMode: compact, buttons: buttons, collapsed: collapsed,
            mode: mode, index: index)
    }

    static func main() {
        print("# on the compact bar")
        expect(chord(index: 0) == .search, "⌘1 is the search field, as in Spotlight")
        expect(chord(index: 1) == .open(.applications), "⌘2 opens the first button")
        expect(chord(index: 4) == .open(.clipboard), "⌘5 opens the fourth button")
        expect(chord(index: 5) == .consumed, "a digit past the buttons launches no hidden favorite")
        expect(
            chord(buttons: [.files], index: 2) == .consumed,
            "with one button, ⌘3 has nothing behind it")

        print("# where the rail never appears, digits are what they were")
        expect(chord(glass: false, index: 1) == nil, "the Smallcast theme keeps its favorites")
        expect(chord(compact: false, index: 1) == nil, "an expanded launcher keeps its favorites")
        expect(chord(buttons: [], index: 1) == nil, "no buttons, no rail, no chords")
        expect(
            chord(collapsed: false, mode: .launcher, index: 1) == nil,
            "typing in the launcher hands the digits back to its favorite rows")

        print("# on a screen a button opened")
        expect(
            chord(collapsed: false, mode: .applications, index: 2) == .open(.files),
            "⌘3 moves from Applications to Files")
        expect(
            chord(collapsed: false, mode: .fileSearch, index: 0) == .search,
            "⌘1 goes back to the search field")
        expect(
            chord(collapsed: false, mode: .clipboard, index: 1) == nil,
            "the clipboard keeps ⌘1…⌘0 for its pinned entries")
        expect(
            chord(collapsed: false, mode: .emoji, index: 1) == nil,
            "a screen no button opened is left alone")

        print("# a slot's picker")
        let four = SpotlightButton.defaults
        expect(
            SpotlightButton.assigning(.emoji, toSlot: 1, in: four)
                == [.applications, .emoji, .quickAI, .clipboard],
            "a new button replaces the slot's")
        expect(
            SpotlightButton.assigning(.clipboard, toSlot: 0, in: four)
                == [.clipboard, .files, .quickAI, .applications],
            "a button from another slot trades places, so order is set by picking")
        expect(
            SpotlightButton.assigning(nil, toSlot: 1, in: four) == [.applications, .quickAI, .clipboard],
            "None removes the slot and closes the gap")
        expect(
            SpotlightButton.assigning(.emoji, toSlot: 2, in: [.files, .quickAI])
                == [.files, .quickAI, .emoji],
            "the empty slot after the last adds one")
        expect(
            SpotlightButton.assigning(.files, toSlot: 2, in: [.files, .quickAI]) == [.quickAI, .files],
            "adding one already listed moves it to the end")
        expect(
            SpotlightButton.assigning(nil, toSlot: 3, in: [.files]) == [.files],
            "None on the empty slot changes nothing")

        print("# normalising a stored list")
        expect(
            SpotlightButton.normalize([.files, .files, .quickAI]) == [.files, .quickAI],
            "a repeat is dropped, order kept")
        expect(
            SpotlightButton.normalize(SpotlightButton.allCases).count == SpotlightButton.maximumCount,
            "a list past the cap is cut to it")
        expect(
            SpotlightButton(rawValue: "applications") == .applications,
            "the stored name is the raw value")

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
