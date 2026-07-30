# Window management

An opt-in set of Raycast-style window arrangement commands: halves, thirds, fourths, quarters, sixths,
maximize / almost maximize / reasonable size, move-to-edge, grow / shrink, display switching, fullscreen
and restore — 39 in total (`WindowAction.allCases`).

Off by default. **Settings › General › Window Management** turns it on, which is the only thing that
makes the commands exist.

## Layout

`Core/WindowManagement/` is three files, split so the maths is testable:

- **`WindowAction.swift`** — the command set: raw ids, Raycast's own titles, SF Symbols, the launcher
  entry id (`command:window:<raw>`) and the UserDefaults key its shortcut lives under. Foundation-only.
- **`WindowGeometry.swift`** — pure geometry: given the window's frame, the screen's usable area and the
  gap, where the window goes. CoreGraphics-only, so `Tools/window-test.swift` compiles it directly.
- **`WindowManager.swift`** — the Accessibility plumbing: resolving the focused window, reading/writing
  its frame, coordinate conversion, restore history, display cycling, fullscreen.

Every rect in `WindowGeometry` is in **Accessibility space** — origin top-left, y growing *downward* —
matching `kAXPositionAttribute`, so nothing is flipped between the geometry and the window server.
`WindowManager.axRect` converts `NSScreen` frames (Cocoa, y-up from the primary display's bottom-left)
into that space and is the only place the two conventions meet.

## How a command runs

Both entry points end in `AppCore.performWindowAction`, which surfaces a refusal as a HUD and otherwise
says nothing — the window moving is the feedback, as in Raycast.

- **From the launcher** — the commands are synthetic `.command` entries built by `CommandRegistry`, so
  they inherit every existing `AppEntry` path (fuzzy match, visibility, the Shortcuts pane). They carry
  `kindLabelOverride = "Window Management"`. `AppCore.runCommand` sends them to the app that was
  frontmost when the palette opened (`previousApp`), then hands focus back to it.
- **From a global shortcut** — `HotKeyAction.window(_:)`, bound in **Settings › Shortcuts › Commands**
  like any other row. The target is `NSWorkspace.frontmostApplication`.

`CommandRegistry.all` is built on the scan queue, off the main actor, so it reads
`SettingsKey.windowManagementEnabled` straight from `UserDefaults` rather than from `AppSettings`.
Toggling the setting calls `AppCore.windowManagementDidChange`, which swaps the Carbon registrations and
re-scans the index. A binding stored while the feature is off (a settings import carries them) stays
dormant: `HotKeyManager.register` refuses to register a `.window` action until the feature is on.

## Behaviour notes

- **Gap** — Settings offers 0–24 px. It's kept both to the screen edges and *between* two tiled windows:
  a tile's shared edges are inset by half the gap each, so two halves end up exactly `gap` apart.
- **Reasonable Size** is 60% of the usable area, capped at 1025×900 (Raycast's numbers). **Almost
  Maximize** is 90%, centred.
- **Restore** undoes the last arrangement of *that* window. Frames are keyed by pid + window title,
  capped at 40 entries — titles aren't unique across an app's windows, which is the accepted
  approximation; the alternative is the private `_AXUIElementGetWindow` id.
- **Fullscreen windows** ignore position and size writes, so a geometry command on one leaves fullscreen
  first and applies the frame after the system's animation.
- **Displays** cycle left-to-right by physical position; the window keeps its proportions on the new
  screen, so a half-screen window stays half-screen.
- **Spaces** — Raycast's "Move to Previous/Next Space" is not implemented; there's no public API for it.
- Everything needs the **Accessibility** permission (the same grant paste uses). Without it every
  command answers with a HUD, and the Settings row shows an orange status dot.

## Tests

```sh
swiftc Smallcast/Core/WindowManagement/{WindowAction,WindowGeometry}.swift \
    Tools/window-test.swift -o /tmp/window-test && /tmp/window-test
```

The harness compiles the shipped sources — which is why `WindowAction` and `WindowGeometry` must stay
free of AppKit and ApplicationServices.
