# Merging Tinycast

Smallcast is a fork of [Tinycast](https://github.com/abue-ammar/tinycast), and most of what this fork
built has since been contributed upstream and developed further there. So a sync is rarely a merge in
the ordinary sense: it is a decision, feature by feature, about which of two implementations of the
same thing survives.

The default is **upstream's**. Taking Tinycast's version wherever the two have converged is what keeps
every later sync cheap, and this fork's own version is kept only where it is strictly richer — in which
case the *feature* is ported onto upstream's code rather than upstream's code being replaced by this
fork's file.

`base` is Tinycast, `origin` is Smallcast. Never push to `base` and never open a PR against it.

## Invariants

- **Check the merge base before assuming it lies.** Upstream rewrites its history often enough that the
  commit this fork last merged is usually gone from `base/main` — but not always. Resolve `git merge-base
  main base/main`, and only when it walks back past a sync go looking for the anchor by tree. See
  [Why the merge base lies](#why-the-merge-base-lies).
- **Every merge must re-check the [Smallcast-only table](#smallcast-only-features).** Every one of those
  fourteen entries reaches into a file upstream also owns, so "take upstream's file" deletes part of it
  with no conflict to warn you. Four have been lost that way, one of them twice — and the third sync
  found every hook in every shared file gone, because upstream had rewritten each of those files.
- **A dropped feature is a merge conflict that resolved wrong**, not a follow-up task. The harnesses
  catch some of it; the rest is only caught by walking the table.
- **Never restore a Smallcast feature by restoring this fork's file** when upstream has changed that
  file too. Port the feature onto upstream's version, so the file keeps tracking upstream.

## Why the merge base lies

Upstream force-pushes: PRs land squashed or rebased, so a commit that existed when this fork merged it
is gone from `base/main` a week later. This fork's merge commit still records that vanished commit as a
parent, so `git merge-base` walks back past every sync to the last commit both sides still share, and a
plain `git merge base/main` then replays a hundred-plus commits whose content is already here.

The fix is that the content *is* still there, under a different commit. Find the `base/main` commit whose
tree is identical to the old merged tip, and tell git that one is already merged:

```sh
git rev-parse <old-merged-tip>^{tree}          # the tree this fork already has
git log --format='%H %T %s' base/main          # find the commit with that exact tree
git diff <old-merged-tip> <anchor> --stat      # must be empty
```

A same-titled commit is the usual candidate, and an empty `--stat` is the proof. Any residual diff is
upstream content the sync would skip silently, so resolve it before going on.

In the first August 2026 sync this turned 103 replayed commits into 29 real ones. The second one needed
none of it: `419a5b4` was still reachable from `base/main`, the merge base already pointed at it, and the
merge saw exactly the 20 new commits. The third (September 2026) was the same: the merge base was
`8882c27`, the tip the second sync merged, and the merge saw its 164 new commits. So run the check
first — the plumbing commit is only earned when the merge base actually walks back past a sync.

**Raise git's rename limits for a big batch.** 749 changed files is past the default, and once rename
detection is skipped the `Tinycast/` → `Smallcast/` fold has to handle every file by hand:
`git -c merge.renameLimit=30000 -c diff.renameLimit=30000 merge --no-commit --no-ff base/main`.

## The procedure

Work in a worktree named for the sync (`git wt sync-base-main`), never in `main`.

1. **Re-tie the histories, if the merge base needs it.** When `git merge-base main base/main` already
   names the last merged tip, skip this step entirely and say so in the merge message. Otherwise
   `git merge -s ours <anchor>` records the anchor as merged without touching a single file. Commit it
   on its own — it is plumbing, and its message should say which old tip it stands in for.
2. **Merge for real.** `git merge --no-commit --no-ff base/main`. It now sees only the genuinely new
   commits.
3. **Fold the `Tinycast/` tree.** Git's directory-rename detection handles only part of the
   `Tinycast/` → `Smallcast/` move, so upstream's new files land at `Tinycast/...` beside this fork's
   copies. For every path still under `Tinycast/`, write upstream's content to the matching
   `Smallcast/` path and remove the original. Delete `Tinycast.xcodeproj` outright. Script it: for
   every conflicted path *and* every path under `Tinycast/`, look the Tinycast spelling up in
   `base/main`; if it exists, write it renamed to the Smallcast spelling, otherwise the file moved or
   died upstream and this fork's copy goes too. A fork-only file never conflicts, so it survives
   untouched. **Never let that sed touch `.git`** — in a worktree it is a file holding the gitdir path,
   and `--exclude-dir` does not exclude it.
4. **Resolve, upstream-first.** Take stage 3 for every remaining conflict, applying [the
   rename](#the-rename). Hold back the three files that need judgement: `Scripts/run-tests.sh` (keep
   this fork's extra harness lines), `Scripts/raycast-runtime/pnpm-lock.yaml` (take upstream verbatim,
   never rename inside it) and `.github/workflows/release.yml` (upstream's pipeline, this fork's tap
   owner).
5. **Sweep the rename.** Files that merged cleanly still carry upstream's naming, so they are missed by
   step 4 entirely.
6. **Walk the tables below** and port back everything upstream does not have.
7. **Regenerate and verify.** See [After the merge](#after-the-merge).

Keep the whole layout adaptation *inside* the merge commit. Re-porting a feature afterwards is a
separate commit, and saying which feature it restores is the point of it.

### The rename

Both cases matter and they mean different things:

| Pattern | Becomes | Why |
| --- | --- | --- |
| `Tinycast` | `Smallcast` | types, paths, product names, display strings |
| `tinycast` | `smallcast` | the `__smallcast` JS global the Swift host installs, bundle IDs (`com.smallcast.app`), cache and temp-file prefixes, the `SMALLCAST` env var custom commands see |
| `TINYCAST` | `SMALLCAST` | shouted env vars — `SMALLCAST` for custom commands, `SMALLCAST_TEST_JOBS` for the runner |
| `abue-ammar` | `arthur-fontaine` | the Homebrew tap, the release feed, the website URL |

Never rename inside `website/` (upstream's own site, left as Tinycast's), `pnpm-lock.yaml` (integrity
hashes), or the two places that name Tinycast on purpose: this file, and `AGENTS.md`'s pointer to it.
Afterwards, `grep -rniI 'tinycast\|abue-ammar' --exclude-dir=.git --exclude-dir=website
--exclude-dir=node_modules --exclude=pnpm-lock.yaml --exclude=upstream.md --exclude=AGENTS.md .` must
return nothing.

One test vector moves with the rename: `ext-test`'s crypto check encrypts the literal `hello tinycast`
and compares the AES-CBC ciphertext hex. Renaming the plaintext changes the hex, so the expected value
is the fork's own (`ed019a3a…` for `hello smallcast`); the round-tripped plaintext is the proof the
shim is right, not the hex.

## Smallcast-only features

Nothing upstream is comparable, so the rule is always **keep**. The danger is never the fork-only
*file* — it survives untouched. It is the hook inside a file upstream also owns, which "take upstream's
version" deletes without a conflict to warn you.

| Feature | Fork-only files | Hooks in shared files — the part that gets lost |
| --- | --- | --- |
| **Recent list on ↑** — launches and calculations, newest first | `Launcher/Model/LaunchHistoryStore.swift`, `Launcher/Service/HistoryFeed.swift`, `Launcher/UI/RecentList.swift`, `Launcher/UI/RecentScreen.swift`, `Tests/launch-history-test.swift` | `PaletteMode.recent` (case + symbol + placeholder); `RootPaletteView.screen`'s `.recent` branch, its `LaunchHistoryStore` / `RunningAppsMonitor` `@Environment` reads, and **`openRecentFromTop()` called before the compact guard in the ↑ handler** (it `push`es, so Escape walks back); `AppCore.launchHistory` and the `launchHistory:` argument to `LauncherCoordinator`; `launchHistory.record` in `LauncherCoordinator.launch`; `.environment(core.launchHistory)` in `PaletteEnvironment` and `SettingsCoordinator`; `run launch-history-test` in `run-tests.sh` |
| **`AppRow` and `CalcHistoryRow` are not `private`** | — | `Launcher/UI/LauncherList.swift` and `Calculator/UI/CalculatorHistoryView.swift` — `RecentList` draws its rows with them, and upstream's copies are `private`. The tell is a compile error in `RecentList` |
| **Settings › Search** — see and reset what ranking learned | `Launcher/Settings/SearchSettingsView.swift` | `SettingsTab.search` (case, title, symbol, `SettingsSection.launcher` list), the `SettingsDetailView` case, `.environment(core.launcherRanking)` in `SettingsCoordinator`, and a `search` pane entry in `SettingsSearchCatalog` (`settings-history-test` asserts every pane is reachable). `LauncherRankingRecord.submittedQuery` is upstream's spelling |
| **`LauncherRankingStore.reset(since:)` and `learnedEntries()`** — forget a window, and list what was learned | — | `Launcher/Model/LauncherRankingStore.swift`, with the `LearnedEntry` struct above the store; the Search pane is the only caller of both. `ranking-test`'s four "learned entries" checks are the tell |
| **Settings › Miscellaneous** — the currency consent switch | `Calculator/Settings/MiscellaneousSettingsView.swift` | `SettingsTab.miscellaneous`, the `SettingsDetailView` case and a `miscellaneous` catalog entry. Upstream deleted its own copy of this file long ago, so it never conflicts |
| **Calculation autosave** — remember one you only looked at | — | `PaletteState.onWillReset` (declared, and fired at the *start* of `openScreen`, which every motion funnels through); `AppCore.start()` wiring it to `calculatorCoordinator.commitCalculation`; `CalculatorCoordinator.commitCalculation` / `clearSearch` plus the `palette:` and `currencyRates:` init parameters; `RootPaletteView`'s `.clearQuery` arm calling `clearSearch()` instead of `vm.query = ""` |
| **Escape hands focus back from a field** | — | `PalettePanel.escapeEndsEditing` / `reportEndOfEditing` and `onFieldEditorEndedEditing`, wrapped around `super.sendEvent`; `PaletteWindowController.ensurePanel` bumping `palette.focusToken` from it. Upstream leaves the panel with no first responder |
| **A typed search survives a dismissal** (30 s) | — | `PaletteHideReason` (declared above `PaletteWindowController`); `workInProgressGrace`, `hide(restoreFocus:reason:)` and `schedulePopToRoot(reason:)` guarding on `interval > 0` instead of `timeout != .immediately`; `PaletteCoordinator.hidePalette(restoreFocus:reason:)`; the four `.dismissed` sites (both `togglePalette`s, Escape's `.hidePalette` arm, `windowDidResignKey`) |
| **Consent before any exchange-rate fetch** | — | `Calculator/Service/CurrencyRateStore.swift` — `isEnabled`, `setEnabled`, `refreshNow`, `provider`, `providerURL`, and the gate in `init`, `start` and `fetchAndStore`. Upstream fetches unconditionally |
| **Month and year units** — so `$100/month` converts | — | `CalcUnitCatalog` — the `month` and `year` rows after `week`. Upstream's typed evaluator has neither; `calc-test`'s three month/year lines are the tell |
| **Typo tolerance** | — | `SearchRelevance`: `FuzzyMatch.Tier.typo` (and `isLiteral` excluding it), the typo arm of `match`, `rawScore` and `shape`, `allowedDistance(forQueryLength:)`, `typoDistance` / `wordStarts` / `prefixDistance`, `SearchRelevance.typoCell` and the `(.name, .typo)` cell with the other roles' typo cells `nil`. `Tests/fuzz-test.swift`'s `typoTolerance()` block, its `typo tier` check and "only subsequence and typo are non-literal" |
| **Sixths, and four fourths** — 45 window commands, not upstream's 35 | — | `WindowManagement/Model/WindowCommand.swift` (the six `Sixth` cases, the four single-fourth cases, the `sixths` group with its title, and their `name` / `symbol` / `group` arms) and `WindowManagement/Model/WindowPlacementEngine.tileFractions` (their geometry). `Tests/window-command-test.swift` asserts the catalog count and each group's, so a stale number is the tell |
| **Ask the AI from root search** — ⌥↵ by default, configurable | `Features/AI/Model/PaletteAIChord.swift` | `RootPaletteView`'s `askAI(key:modifiers:)` / `holds(_:in:)` pair, called **first** in the ↵ handler and before `advanceTabFocus` in the Tab handler, running `core.aiChatCoordinator.ask`; the picker in `AISettingsView.chatSection` (`SettingsRowTitle(.aiChat, "Ask from the launcher")`) and its `SettingsSearchCatalog` row; `AppSettings.aiChord` and its `AppSettingsKey`, its `SettingsBackup` field and `SettingsBackupCoverage` entry. `ai-provider-test` pins the stored spellings |
| **Tab opens the clipboard, or does not** | — | `AppSettings.tabOpensClipboard` and its `AppSettingsKey`, the guard in `RootPaletteView.cycleMode` (a step *into* the ring is refused, the step back to the launcher never is), the section in `ClipboardSettingsView` with `SettingsAnchor.clipboardLauncher` and its catalog row, and its `SettingsBackup` field and coverage entry. Upstream's Tab ring is unconditional |
| **Local AI presets** — Ollama and LM Studio | `AI/Model/LMStudioServerStatus.swift`, `AI/Model/OllamaHost.swift`, `AI/Service/LMStudioServerLocator.swift`, `AI/Service/OllamaServerLocator.swift` | `AIProviderKind.ollama` / `.lmStudio` with their `title` / `defaultBaseURL` arms and `acceptsUnlistedModels` (`AIConnection.swift`); the `.ollama, .lmStudio` arm in `AIBrand`; `AIModelDiscovery.isEmbedding`; in `AIConnectionEditorSheet` the two `modelPlaceholder` arms (a compile error without them), `lmStudioServerRow` with its three `@State`s, `startLMStudioServer()`, `.task(id: connection.provider)`, `adoptLocalAddress(for:)` in the provider `onChange`, and `acceptsUnlistedModels` replacing `== .openAICompatible`. `ai-provider-test`'s four local-preset blocks |
| **Codex reads the user's `CODEX_HOME`** — a login moved out of `~/.codex` is still found | `AI/Service/CodexHomeLocator.swift` | `CodexAppServerClient`: the `userCodexHome` cache, the `CodexHomeLocator.home()` call in `start()` after the executable lookup, and the `else if` arm that puts it in the server's environment. Upstream inherits the app's environment only, which Finder never gives the variable |
| **The toggle hotkey dismisses from any screen** | — | `PaletteCoordinator.togglePalette` testing `windowController.isVisible` rather than `isShowing(.launcher)`, so the chord that summoned a sub-screen puts it away and `restoreAnyMode` brings it back within the grace. Upstream's toggle navigates a sub-screen to the launcher instead |
| **The caret in an extension's argument field follows the appearance** | — | `Extensions/UI/CommandArgumentsRow.swift` — `.tint(Theme.Colors.textPrimary)` where upstream hardcodes `.white`, which is invisible in Light mode |
| **Hold the launcher shortcut to talk to the AI** — twelve on-device speech engines | `Features/Voice/` (all of it), `HotKeys/Model/HoldDetector.swift`, `Platform/MicrophoneAccess.swift`, `Tests/voice-test.swift`, `Tests/voice-engine-test.swift`, `docs/features/voice.md` | `HotKeyCenter`: the `kEventHotKeyReleased` event type, `Entry.onKeyUp`, `register(…onKeyUp:)` and the `released:` argument to `handle`; `HotKeyManager`: `onTogglePaletteHeld` / `onTogglePaletteReleased`, `hold` / `holdTimer`, `togglePressed` / `toggleReleased`, the reset in `recordingAction`; `AppCore`: `voiceSettings`, `voiceModels`, `voice`, `voiceCoordinator`, the two hotkey closures, `voiceCoordinator.warmUp()` in `start()` and its `track` line; `AIScreen`: the `voice` / `voiceCoordinator` parameters, `primaryActionTitle`, `activate` and `body` branches; `RootPaletteView`'s `.ai` case passing them; `AISettingsView`: `VoiceSettingsSection()`; `SettingsCoordinator`: the two `.environment` lines; `Permissions.microphoneAccess` / `requestMicrophoneAccess`; `AppSettingsKey`'s three `voice*` cases and their `SettingsBackupCoverage` reasons; `SettingsAnchor.aiVoice` and its catalog rows; `NSMicrophoneUsageDescription` in `Info.plist` and `com.apple.security.device.audio-input` in the entitlements; the two `run` lines in `run-tests.sh` |
| **Branding and the dev channel** | `Smallcast.entitlements`, `smallcast.icon/`, `project.yml` | `About` links, the release tap owner and the updater feed in `Updates/Service/UpdateCheckStore.swift` — both must point at this fork, or the app updates itself into Tinycast. Since the third sync `release.yml` turns on the hardened runtime and notarization; those need this fork's own signing secrets. `Updates/Service/BundleSignature.developerID` pins **upstream's** Developer ID team (`SPBUD83MLU`), which the rename cannot touch: a self-signed Smallcast accepts an update through the running-leaf fallback below it, so the literal is harmless until this fork has a Developer ID of its own — then it must change, or the updater trusts Tinycast's builds and not ours |

## Comparable features

Both projects have these, and upstream's wins. Most were contributed upstream from here and grew after,
so this is not a downgrade — but each row has a way of going wrong.

| Feature | Verdict | The gotcha |
| --- | --- | --- |
| Raycast extension host | Upstream. Same lineage, small drift — `Scripts/raycast-runtime/` differs by little more than the rename | Rebuild `Resources/RaycastRuntime.generated.js` after resolving, and remember `__smallcast` is a lowercase rename |
| Extension appearance (icon + tint) | Upstream, via `EntryIcon.tintedSymbol` | The tint must reach the icon **cache key**, or a re-skinned extension serves whatever was drawn first. `icon-cache-test` pins it |
| SF Symbol catalog | Upstream | — |
| Icon subsystem | Upstream's `EntryIcon` / `IconRequest` / `IconStyleSignal` | `AppEntry.iconOverride` and `labelOverride` replace this fork's `imageIconPath`, `appearance` and `kindLabelOverride`; `ExtensionIconCache` replaces a remote-image path in `IconCache` |
| Frecency ranking | Upstream | Keep `reset(since:)` — see the table above |
| Category search | Upstream's `AppEntry.Kind.named(by:)`, an exact match on the category name | This fork's `SearchFields.category` band is **not** restored: the field would never be set, so it would be dead code. Its `fuzz-test` block goes with it |
| Currency conversion | Upstream's feed (Raycast's, fiat + crypto) over this fork's ECB one | Keep the consent gate on top, and `CalcMemo.evaluate` takes `rates:` now, not `currency:` |
| Derived units and money as a dimension | Upstream, since its typed evaluator (#483): `100km / 2h to km/h`, `100 USD / 4hr`, `25 USD/hr * 8hr` all answer there | This fork's `CalcDimension` / `CompoundUnit` / `UnitDef.priced(at:)` / `CalcUnits.ordered` are gone; only the month and year rows survive (table above). `CurrencyDef.unitDef` would fail to compile against upstream's `UnitDef` — delete it |
| Fallback commands | Upstream's `Fallback` / `FallbackStore` / `FallbackCoordinator` and its Settings › Fallbacks pane (#398), since the third sync | This fork's `FallbackCommand.swift`, `FallbackCommandsSection.swift`, the `fallbackCommands*` / `webSearchTemplate` settings and the `FallbackCommandsSection()` call in `SearchSettingsView` are deleted. **Search the Web is not ported**: upstream offers no web-search fallback, but a quicklink holding `{argument}` is offered as one, which covers it. `QuicklinkCoordinator.openQuicklink(id:filling:)` and `FileSearchCoordinator.show(query:)` are upstream's now, so the fork's `prefilledArgument:` and second `show(query:)` go |
| Escape steps back out of a sub-screen | Upstream's `PaletteEscapeAction.goBack` over a `PaletteState` back stack (#504, #585, #554) | This fork's `.exitScreen` case, `PaletteWindowController.exitScreen` and `PaletteCoordinator.exitScreen` are gone; only the `.clearQuery` → `clearSearch` and `.hidePalette` → `.dismissed` riders remain (table above). `palette-escape-test` is upstream's |
| Escape in a header argument field | Upstream's `.leaveArgumentField` (#492) | Covers the inline argument fields only; the fork's `escapeEndsEditing` still covers an extension form's field editor |
| Region auto-conversion, crypto | Upstream | — |
| Window management | Upstream, **plus** this fork's sixths and single fourths | Upstream's catalog is 35 commands (Center Two Thirds arrived in #650) and this one is 45. Upstream's own `fourths` group holds only First / Last Three Fourths, so the two sets union rather than collide — reconcile case by case, then fix the count and the group counts in `window-command-test`. The files moved to `WindowManagement/Model/` and the geometry lives in `WindowPlacementEngine.tileFractions` |
| Escape clears before it dismisses | Upstream's `PaletteEscapeAction.resolve` | Contributed upstream from here and restructured there. Keep two things on top of it: `.clearQuery` routes through `CalculatorCoordinator.clearSearch` so a looked-at calculation is still remembered, and `.hidePalette` passes `reason: .dismissed` so the 30 s typed-query grace still applies. Nothing asserts either, so check the two arms by reading `RootPaletteView`'s Escape handler |
| AI chat | Upstream's, entirely — Apple Intelligence, installed Codex / Claude / OpenCode, API connections, MCP servers, Quick Actions, model discovery, system prompts and chat history | This fork shipped its own AI chat in PR #18 the day before the second sync, so both existed at once. Since the third sync the connection editor is `AIConnectionEditorSheet`, not a section of `AISettingsView`, so the local-preset riders moved there (table above). `aiEnabled` stays out of settings backups because it doubles as consent to send typed text off the Mac |
| Calculator | Upstream's typed evaluator (`CalcEngine`, `CalcExpressionParser`, `CalcTokenizer`, `CalcUnitCatalog`, …) | Only the month and year rows and the consent gate are this fork's; everything else in `Calculator/Model/` is upstream's file |
| Palette search field position | Upstream — one structural position, conditional *width* | Putting it inside a branch tears down its field editor and drops first responder mid-navigation |
| Notes, in-app updater, launcher aliases, ⌘-digit favorites, clipboard type filter, input-source switcher, Space switching | Upstream only — new features arriving with the sync | — |
| The Calendar and meeting screens, extension OAuth, Raycast v2 encrypted import, release notes in the update window | Upstream only — new features arriving with the sync | Each brings its own `SettingsTab` case, `AppCore` store and harness. `Info.plist` gains camera and calendar usage strings, and `project.yml` ships `NOTICE.md` as a resource for the brand marks |
| Light appearance | Upstream. The `.darkAqua` lock is gone, and `AGENTS.md` is upstream's | — |
| `AGENTS.md` and `docs/` | Upstream's, renamed — the whole directory comes from there | Re-add the sections describing the Smallcast-only features above, including this file's link |

## After the merge

- `xcodegen generate` — new upstream files arrive under the `Smallcast` glob, but the project still has
  to be regenerated and committed. Run it again after deleting a fork file the sync made redundant, or
  the build fails on a missing input.
- `cd Scripts/raycast-runtime && pnpm install && node build.mjs` — `Smallcast/Resources/RaycastRuntime.generated.js` is committed but generated.
- Check whether upstream touched `Scripts/gen-emoji.js` or `gen-currencies.js`; if so, regenerate their
  output too.
- Compare upstream's `project.yml`, `Info.plist` and `*.entitlements` against the anchor. Dropping
  `Tinycast.xcodeproj` is only safe because upstream changes those files, not the generated project — so
  confirm that each time rather than assuming it.
- Then the usual gates in [testing.md](testing.md#definition-of-done): `./Scripts/run-tests.sh`, a
  warning-free Debug build, `./Scripts/lint.sh`, and a Release build because CI builds Release on a
  newer Xcode than yours.

## Regressions this has already caused

Both syncs so far lost the same kind of thing: a Smallcast behaviour whose only trace in the code was a
few lines inside a file upstream owns. Nothing failed — the app built and every harness passed — because
no test covered the hook. Check these by hand, every time:

- **↑ from the empty launcher opens the Recent list**, in compact *and* expanded state. Lost twice. Both
  times the cause was the same: the collapsed-palette guard returning before the Recent branch.
- **The first Escape clears the query**, the second dismisses — and clearing still commits the
  calculation that was on screen.
- **Escape on a sub-screen goes back, it does not close.** Only the launcher's own Escape dismisses.
- **⌥↵ with text asks the AI**, and **Tab walks a row's argument fields** before it rings anything;
  with Settings › Clipboard's Tab switch off, Tab never opens chat or the clipboard.
- **The toggle hotkey in a sub-screen dismisses**, and reopening within 30 s brings that screen back.
- **The caret in an extension's argument field is dark in Light mode** — upstream hardcodes `.white`
  there, so "take stage 3" restores the bug with no conflict.
- **Escape inside an extension's form field** clears the field and leaves the palette closeable.
- **Reopening within 30 s of dismissing keeps what was typed.** Lost once.
- **A typo still finds the app** (`chorme` → Google Chrome), and `finder` still does *not* find Find My. Lost once.
- **Moving onto a command with arguments keeps first responder** — no beep, and ↓ keeps stepping.
- **A re-skinned extension draws its tint** in the launcher rows and in the appearance picker.
- **Window management offers 45 commands**, fourths and sixths included.
- **The calculator answers `100km / 2hr` as `50 km/h`** and `$100/month * 12month` as money.
