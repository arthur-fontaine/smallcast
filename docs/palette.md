# Palette

The command palette is a borderless floating `NSPanel` hosting SwiftUI; see
[architecture.md](architecture.md) for window ownership.

## State flow

`PaletteViewModel` (mode / query / selection / `focusToken`) is the bridge between the panel and
`AppCore`. Showing the palette calls `prepare(mode:)`, which resets state and bumps `focusToken` (a
UUID) so the SwiftUI search field re-focuses. `RootPaletteView` switches its content on `mode`:

- `.launcher` → `LauncherList`
- `.clipboard` → `ClipboardList` + preview
- `.calculatorHistory` → `CalculatorHistoryList`
- `.history` → `HistoryList` (recent launches + calculations — see [launcher.md](launcher.md))

Clipboard, Calculator History and Recent are sub-screens reached from the launcher (Tab, ↑ on an empty
search, a command, or a hotkey) and back out to it.

The flat `selection` index is the single source of truth for highlight / activation and **must always
match the visible row order**, including the inline calculator card at index 0 when present (see
[calculator.md](calculator.md)).

## Dismissal and the typed query

A half-written search is worth more than a keystroke, so closing the palette treats it as pending work:

- **Escape with text** clears the field and leaves the palette open; a second Escape closes it. (Inside
  a running extension command Escape still pops that command's own stack first — the extension owns its
  search bar.)
- **Escape with an empty field** closes, as it always did.
- **Dismissing with text** — the toggle hotkey, Escape, or clicking away — keeps the query for
  `PaletteWindowController.typedQueryGrace` (30 s), whatever Pop to Root Search is set to, so glancing
  at the window behind and coming back doesn't lose it. The next summon consumes the preserved state
  exactly as a within-timeout reopen already did.

`PaletteHideReason` is what keeps that honest: closing because an action *ran* (`.actionTaken`, the
default) resets as before, since the search already did its job — only `.dismissed` holds on. The three
dismissal sites name themselves; everything else inherits the safe default.

## Menu-open input freeze

While a footer popover menu (⌘K Actions / app menu) is open the search field reads as inert but
**never resigns first responder** — resigning makes the `NSTextField` swap between its field-editor
and cell rendering, shifting the text / placeholder a point or two, so focus stays put. Input is
frozen instead:

- `RootPaletteView` mirrors the open state into `PaletteViewModel.menuOpen`, whose `didSet` fires
  `onMenuOpenChanged`.
- `PalettePanel.sendEvent` then swallows text-editing keystrokes while `menuOpen` (letting ⌘/⌥ chords
  and menu-nav keys through to SwiftUI `onKeyPress`).
- The caret is hidden by clearing SwiftUI's **own** live field editor's `insertionPointColor`. SwiftUI
  force-casts its field editor to a private subclass, so vending a custom one crashes — only the
  existing one can be tuned.

## Focus restoration (load-bearing)

`PaletteWindowController` records `previousApp` (the frontmost app) on show. Paste then targets that
app:

- `Paster.paste` activates it and posts a synthetic ⌘V via `CGEvent`.
- `Paster.pasteInPlace` posts ⌘V straight to the app's PID _without_ activating it, so the palette can
  stay open and frontmost (used by "paste keeping window open").

Both require the Accessibility permission (`Permissions.ensureAccessibility()`).

The same show also mirrors that app into `PaletteViewModel.pasteTarget` (a `PasteTarget`: localized
name + bundle path), so Clipboard and Emoji can name it — the footer pill reads "Paste to Notes" and
the ⌘K paste rows carry the app's icon. Resolved once per summon, never per render, and deliberately
not cleared by `prepare` (pop-to-root resets the screen, not the target).
