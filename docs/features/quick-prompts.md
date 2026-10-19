# Quick Prompts

A quick prompt is a saved question for Quick AI with named blanks: `Translate ~~~{argument
name="text"}~~~ to {argument name="language"}`. It is a launcher row — typing its name puts one field
per argument beside the search, the way a quicklink's do — and ↵ sends the filled-in text to a fresh
Quick AI chat. A prompt with an argument is also offered as a [fallback](launcher.md#fallbacks), and a
fallback **preset** can run it under another name with some arguments already given ("Translate to
English").

Quick prompts ride the AI switch: with `aiEnabled` off there are no rows, no fallbacks, no
`Create Quick Prompt` command, and `QuickPromptCoordinator.run` refuses. **Settings ▸ AI ▸ Quick
Prompts** lists them, with an alias field, Edit, Delete and an Enabled checkbox per row.

## Invariants

- **There is one template engine.** A prompt expands through `SnippetTemplateEngine`, so every
  snippet token works — `{selection}`, `{clipboard}`, `{date}`, modifiers — and arguments are
  `{argument name="…"}`. A bare `{text}` is literal text, not an argument: the engine treats an unknown
  token as text so a snippet can hold code braces, and prompts do not get a second dialect.
- **Drawing the fields reads nothing.** The header chips come from `declaredArguments(in:)`, through
  `TemplateArgumentsAccessory` — the same strip quicklinks use, so the two cannot drift. A prompt's
  strip reads as its sentence: the words written before each field after the first are drawn beside
  it, edge punctuation trimmed and a long run cut to the three words nearest the field, so
  `Translate ~~~{text}~~~ to {language}` shows *Translate [text] to [language]*.
- **One run funnel.** Launcher activation, the fallback row and a preset all reach
  `QuickPromptCoordinator.run(id:values:)`. Values still owed send the row back to root search through
  `PaletteCoordinator.showArguments`, filled-in values kept and the first empty field focused; a
  `{selection}` that reads nothing fails with the HUD the quicklinks use, never an empty question.
- **`Model/` stays Foundation-only.** `QuickPromptStore` keeps the library in defaults under
  `quickPrompts`, like custom commands: a short list of authored text, sanitized on load.

## Running

`run` captures the expansion context on every call, as quicklinks do, so `{clipboard}` and
`{selection}` are read at the moment the prompt runs; with the palette up the selection comes from the
app the palette was opened over. A `{selection}` left empty by Accessibility gets one ⌘C, with the
palette hidden first because it holds key. The expanded text then goes to `QuickAICoordinator.ask` —
a new chat with the question already sent, exactly what the Quick AI fallback does.

A prompt row sits in its own launcher section, **Quick Prompts**, after Quicklinks. Its ⌘K menu adds
**Edit Quick Prompt** (`⌘E`), and **Hide from Root Search** (`⇧⌘H`) clears the prompt's own
`showsInRootSearch` rather than writing `VisibilityStore`; the editor's toggle is its undo.

A prompt has **no global shortcut**. A shortcut with arguments still owed would need a surface of its
own to land on, and root search is the only one a prompt has.

## Editing

The editor is a Settings panel (`QuickPromptEditorPanel`), opened from the pane, from a row's ⌘E, and
from `Create Quick Prompt`. The palette steps aside and `QuickPromptCoordinator.editRequest` is what
Settings ▸ AI presents, so all three open the same panel. **Insert…** appends a named argument, one with
`options=`, an optional one with `default=`, the selection, the clipboard or a date; the line under the
text lists the fields the launcher will ask for, read off the template exactly as the row reads it.
Editing keeps the prompt's identity, so its alias, favorite slot, ranking and presets survive.

Deleting confirms, then removes the alias, favorite, hidden-item key and ranking. Fallback presets
built on a deleted prompt are pruned by `FallbackCoordinator.prunePresets` whenever the library
changes — deferred a turn, so a backup's replace-then-refill never prunes a prompt that comes back.

## Backup

Prompts ride a settings backup (`quickPrompts`), replacing the library on import like custom
commands. They grant nothing: `aiEnabled` stays out of the backup, so an imported prompt sends nothing
until AI is switched on here.

## Standalone harness

```sh
./Scripts/run-tests.sh quick-prompt-test   # the store
./Scripts/run-tests.sh fallback-test       # identity and which argument a query fills
```
