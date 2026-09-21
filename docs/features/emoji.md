# Emoji picker

A palette sub-screen (reached like Clipboard / Calculator History) presenting a searchable emoji grid.

## Invariants

- **`Model/` stays Foundation-only** — `EmojiCatalog`, `EmojiGridGeometry` and the generated dataset are
  compiled by `emoji-test`, so an `import AppKit` there breaks the test suite.
- **`EmojiData.generated.swift` is emitted by `node Scripts/gen-emoji.js`** (Node 18+ for global `fetch`)
  and is never edited by hand. Regenerate and commit instead.
- **Suggestions ship off, and their switch doubles as consent** — to record typing and to download the
  model. `emojiSuggestionsEnabled` is excluded from settings backups, and Accessibility is requested only
  from that Settings gesture, never from startup or a health check.
- **The typed record lives in memory only.** `TypedTextPolicy` is a capped string on the recorder; nothing
  it holds is ever written to disk, logged or sent anywhere. The model runs on device.
- **`EmoTokenizer.swift` is a port, not ours.** It carries Desert Ant Labs' copyright and licence header
  and stays byte-for-byte faithful to the SDK's featurizer: `emo-test` pins it to golden vectors produced
  by the original. A change there is a model-compatibility change, not a refactor.

## Layout

| Path | Role |
| --- | --- |
| `Model/EmojiCatalog.swift` | The catalog model — groups, names, keywords |
| `Model/EmojiGridGeometry.swift` | Pure grid math — columns, item sizing |
| `Model/EmojiData.generated.swift` | The dataset |
| `Service/EmojiIndex.swift` | Search index over the catalog |
| `Service/FrequentEmojiStore.swift` | Persisted most-frequently-used emoji |
| `Model/EmoTokenizer.swift` | The Emo featurizer — hashed n-grams and the unigram tokenizer (ported) |
| `Model/EmoModelInputs.swift` | The `emo_meta.json` sidecar, the six input tensors, the output ranking |
| `Model/TypedTextPolicy.swift` | The capped typed record and the phrase it offers |
| `Service/EmoModelStore.swift` | Downloads and hash-checks the pinned model files |
| `Service/EmoSuggester.swift` | The Core ML session: phrase in, ranked emoji out |
| `Service/TypedTextRecorder.swift` | The listen-only keystroke tap feeding the record |
| `Service/EmojiSuggestionManager.swift` | Owns the three above and the `Suggested` row's state |
| `UI/EmojiGridView.swift` | The SwiftUI grid |
| `UI/EmojiScreen.swift`, `UI/EmojiCoordinator.swift` | The palette screen and its action surface |

The index, the stores, the tap and the classifier are **effects**, so they live under `Service/` — the
`Model/` files are pure, and `emoji-test` plus `emo-test` compile them to prove it.

## Suggestions

**Settings → Emoji & Symbols → Suggestions** adds a `Suggested` row above `Frequently Used` when the
query is empty: up to eight emoji the [Emo](https://desertant.com/models/emo/) classifier picks for the
sentence being typed in the app behind the palette.

- **Enabling confirms first.** The dialog names both costs — Accessibility for the listen-only tap, and a
  one-time 5.5 MB download from `huggingface.co` — then stores the flag and requests the grant. Off is
  a full teardown: the tap goes, the record is forgotten and the model files are deleted.
- **The record is the last sentence.** `TypedTextRecorder` installs a `KeystrokeTap`
  (`Platform/KeystrokeTap.swift`, shared with snippet keywords) and feeds `TypedTextPolicy`: 240
  characters at most, reset on a click, a navigation key, an app switch, Secure Event Input or a minute
  of silence, and ignored entirely while a Smallcast window holds key. A ⌘/⌃ chord is ignored rather
  than reset, because the chord that summons the picker reaches the tap before the picker reads the
  record. `phrase` is the text after the last `.` `!` `?` or newline, cut to its last sixteen words.
- **Suggestions are computed once per summon.** `PaletteCoordinator.showPalette` reads the record as the
  emoji screen opens, before anything typed into the picker could disturb it, and runs the model off-main.
  Probabilities below 0.02 are dropped, so a phrase the model has no opinion on shows no row at all.
- **The model is pinned.** `EmoModelStore` fetches revision `v0.7.0` on a private `.ephemeral`,
  `urlCache = nil` session into `Caches/<bundle-id>/emo-v0.7.0/`, verifying every file's SHA-256 before
  it lands. `EmoSuggester` loads the compiled `.mlmodelc` CPU-only — the graph is small enough that the
  Neural Engine's dispatch would cost more than it saves — and reads the Float16 output contiguously.
- **Labels match the catalog exactly.** All 812 labels, VS16 included, are glyphs in
  `EmojiData.generated.swift`, so `index.entry(for:)` needs no normalisation; a label the catalog lacks
  would simply be skipped.
- **Attribution is a licence term.** The pane's footer carries "Powered by Emo from Desert Ant Labs"
  linking to `desertant.com`; `NOTICE.md` records the port and the model's licence.

## Search

- **Keywords keep their CLDR phrase boundaries.** The generator joins them with commas and keeps every
  annotation, and a single-word query fuzzy-matches the name and each keyword on its own, so a
  subsequence never spans two keywords.
- **Every word of a multiword query must start a word** in the name or a keyword, in any order. A literal
  phrase outranks words found in the name, which outrank words assembled from name and keywords.
- **A full name ranks first, then a complete leading name word, then an exact keyword**, then a partial
  leading word: `birthday` keeps 🎂 first, and `pray` favours the annotation over "prayer beads".
- **Colon-wrapped queries are unwrapped**, so `:+1:` reuses CLDR's `+1` annotation with no alias table.
- **Usage breaks ties, never tiers.** The top 100 glyphs from `FrequentEmojiStore.top` add a 100…1
  bonus, and the store's identity and revision are in the search memo key.

## Rendering

Two structural decisions in `EmojiGridView` are load-bearing, and both are about the ~2,000 cells the
grid can realize.

**Interaction lives on the row, never the cell.** Tap, double-tap, right-click and hover are attached
once per `EmojiSectionGrid` row. A fast scroll realizes every cell, and per-cell interaction
machinery — notably the `NSView`-backed right-click catcher — costs roughly **100 MB** at that scale,
which lazy containers never release. Per-row keeps it bounded to the handful of visible rows, so the
cell view stays pure content: no gestures, no overlays, no hover tracking. Hover is resolved by
mapping the pointer's x to a column, which is exact because cells split the row width evenly with
zero spacing; the empty trailing slots of a partial last row resolve to nil.

**Rows sit directly under the outer `LazyVStack`.** A cell nested inside a `LazyVGrid` cannot be
scrolled to until it is realized, which broke keyboard scrolling on key-hold. Keeping rows as the
`ScrollViewReader`'s targets means any row can be reached even while off-screen. Row IDs are
section-namespaced, because a frequently-used emoji also appears inside its own category. Selecting
into the first row scrolls to the origin rather than the row, so the section header shows too.

The grid list uses the palette scrollbar (`.thinScrollbar()` + `.hideNativeScrollers()`) and the shared
`SectionHeader` for group labels — see [ui.md](../ui.md).
