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

- **Find the anchor by tree, never by commit.** Upstream rewrites its history, so the commit this fork
  last merged is not reachable from `base/main` later. See [Why the merge base lies](#why-the-merge-base-lies).
- **Every merge must re-check the [Smallcast-only table](#smallcast-only-features).** Every one of those
  eighteen entries reaches into a file upstream also owns, so "take upstream's file" deletes part of it
  with no conflict to warn you. Four have been lost that way, one of them twice.
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

In the August 2026 sync this turned 103 replayed commits into 29 real ones.

## The procedure

Work in a worktree named for the sync (`git wt sync-base-main`), never in `main`.

1. **Re-tie the histories.** `git merge -s ours <anchor>` records the anchor as merged without touching
   a single file. Commit it on its own — it is plumbing, and its message should say which old tip it
   stands in for.
2. **Merge for real.** `git merge --no-commit --no-ff base/main`. It now sees only the genuinely new
   commits.
3. **Fold the `Tinycast/` tree.** Git's directory-rename detection handles only part of the
   `Tinycast/` → `Smallcast/` move, so upstream's new files land at `Tinycast/...` beside this fork's
   copies. For every path still under `Tinycast/`, write upstream's content to the matching
   `Smallcast/` path and remove the original. Delete `Tinycast.xcodeproj` outright.
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
| `abue-ammar` | `arthur-fontaine` | the Homebrew tap, the release feed, the website URL |

Never rename inside `website/` (upstream's own site, left as Tinycast's) or `pnpm-lock.yaml` (integrity
hashes). Afterwards, `grep -rniI 'tinycast\|abue-ammar' --exclude-dir=.git --exclude-dir=website
--exclude=pnpm-lock.yaml .` must return nothing.

## Smallcast-only features

Nothing upstream is comparable, so the rule is always **keep**. The danger is never the fork-only
*file* — it survives untouched. It is the hook inside a file upstream also owns, which "take upstream's
version" deletes without a conflict to warn you.

| Feature | Fork-only files | Hooks in shared files — the part that gets lost |
| --- | --- | --- |
| **Recent list on ↑** — launches and calculations, newest first | `Launcher/Model/LaunchHistoryStore.swift`, `Launcher/Service/HistoryFeed.swift`, `Launcher/UI/RecentList.swift`, `Launcher/UI/RecentScreen.swift`, `Tests/launch-history-test.swift` | `PaletteMode.recent` (case + title + symbol + placeholder); `RootPaletteView.screen`'s `.recent` branch, its two `@Environment` reads, and **`openRecentFromTop()` called before the compact guard in the ↑ handler**; `AppCore.launchHistory` and the `launchHistory:` argument to `LauncherCoordinator`; `launchHistory.record` in `LauncherCoordinator.launch`; `PaletteWindowController` injecting `core.launchHistory` |
| **`CalcHistoryRow` is not `private`** | — | `Calculator/UI/CalculatorHistoryView.swift` — `RecentList` draws calculation rows with it, and upstream's copy is `private` |
| **Settings › Search** — see and reset what ranking learned | `Launcher/Settings/SearchSettingsView.swift` | `SettingsTab.search` (case, title, symbol, `SettingsSection.launcher` list) and the `SettingsDetailView` switch case |
| **`LauncherRankingStore.reset(since:)`** — forget a window, not everything | — | `Launcher/Model/LauncherRankingStore.swift`; the Search pane is its only caller |
| **Settings › Miscellaneous** — the currency consent switch | `Calculator/Settings/MiscellaneousSettingsView.swift` | `SettingsTab.miscellaneous` and the `SettingsDetailView` case. Upstream **deleted its own copy of this file**, so the conflict is modify/delete: keep ours |
| **Calculation autosave** — remember one you only looked at | — | `PaletteState.onWillReset` (declared, and fired at the *start* of `prepare`); `AppCore` wiring it to `calculatorCoordinator.commitCalculation`; `CalculatorCoordinator.commitCalculation` plus the `palette:` and `currencyRates:` init parameters |
| **Escape clears before it dismisses** | — | `RootPaletteView`'s escape handler — the `!vm.query.isEmpty` branch calling `calculatorCoordinator.clearSearch()` |
| **A typed search survives a dismissal** (30 s) | — | `PaletteHideReason`; `PaletteWindowController.typedQueryGrace`, `hide(restoreFocus:reason:)` and `schedulePopToRoot(reason:)` guarding on `interval > 0`; `PaletteCoordinator.hidePalette(restoreFocus:reason:)`; the four `.dismissed` sites (three toggles, Escape, `windowDidResignKey`) |
| **Consent before any exchange-rate fetch** | — | `Calculator/Service/CurrencyRateStore.swift` — `isEnabled`, `setEnabled`, `refreshNow`, `provider`, `providerURL`, and the gate in `init`, `start` and `fetchAndStore`. Upstream fetches unconditionally |
| **Derived units** — `100km / 2hr`, `$30/hr * 40hr` | `Calculator/Model/CalcDimension.swift` (`CalcDimension`, `CompoundUnit`, `UnitFormatting`) | `CalcQuantity`: `QuantityValue.Kind.compound`, `unitForm`, `narrowed`, `composed`, the `^` whole-power branch, the `.compound` arms of `multiply` / `divide` / `addOrSubtract` / `convertedResult`, `compoundResult`, and `allowBareUnit` threaded through `parseExpression` / `parseOperand` / `parsePrefix` |
| **Money as a dimension** — what makes a rate possible | — | `CalcUnits`: `UnitCategory.money`, `UnitDef.currency`, `UnitDef.priced(at:)`; `CalcCurrency.unitDef` |
| **Month and year units** — so any rate converts | — | `CalcUnits` — the two `UnitDef`s and their `"month"` / `"year"` plural entries |
| **`CalcUnits.ordered`** | — | `CalcUnits` — declaration order, which is what `CompoundUnit.namedEquivalent` searches |
| **Typo tolerance** | — | `SearchRelevance`: the `typo` tier, `isLiteral` excluding it, `Band.nameTypo` at 0, `bandCount` derived from the top band, `typoScore`, `FuzzyMatch.allowedDistance(forQueryLength:)`, and the `typo:` argument to `consider`. `Tests/fuzz-test.swift`'s typo block and its two hardcoded band indices |
| **Fourths and sixths** — 42 window commands, not upstream's 32 | — | `WindowManagement/WindowCommand.swift` (ten `ID` cases) and `WindowManagement/WindowLayout.swift` (their geometry). `Tests/window-command-test.swift` asserts the count, so a stale number is the tell |
| **AI chat** — a streamed conversation against your own provider | all of `Features/AI/` (three providers: OpenAI-compatible, LM Studio, Ollama), `Platform/Keychain.swift`, `Tests/ai-test.swift` | `PaletteMode.aiChat` / `.aiChats` (case + title + symbol + placeholder); `RootPaletteView`'s two screen branches, its two `@Environment` reads, the `askAI(key:modifiers:)` / `holds(_:in:)` pair called **first** in the ↵ handler, the `AIChatShortcutKeys` modifier, `.aiChat` in `showActionGroup`, the `aiCoordinator.stop()` in `onChange(of: vm.mode)`, and the `AIChatListScreen` arms of the delete and ⌃X handlers; `CommandID.askAI` / `.searchAIChats`; `HotKeyAction.askAI` / `.searchAIChats` plus `builtInActions`, `HotKeyManager`'s two callbacks and its display-name and `perform` arms, `LegacyHotKeyRecords`; `SettingsTab.ai`; the nine `AppSettings` / `AppSettingsKey` values and their `SettingsBackupCoverage` entries; `AppCore`'s three stores, two coordinators, `track` and hotkey closures; `PaletteWindowController` and `SettingsCoordinator` injecting them |
| **Fallback commands** — a no-result search offers what accepts any text | `Launcher/Model/FallbackCommand.swift`, `Launcher/UI/FallbackCoordinator.swift`, `Launcher/Settings/FallbackCommandsSection.swift`, `Tests/fallback-test.swift` | `LauncherScreen`'s `Row.fallback` case, its `fallbacks` build in `init` and its `activate` / `actions` / `primaryActionTitle` arms; `LauncherList`'s `fallbacks` / `selectedFallbackID` / `query` / `onFallback` parameters, its `Row.fallback` case and `fallbackRows`; `FallbackCommandsSection()` in `SearchSettingsView`; `FileSearchCoordinator.show(query:)`; `QuicklinkCoordinator.openQuicklink`'s `prefilledArgument:`; `SnippetTemplateEngine.usesArguments` |
| **Branding and the dev channel** | `Smallcast.entitlements`, `smallcast.icon/`, `project.yml` | `About` links, the release tap owner and the updater feed in `Updates/Service/UpdateCheckStore.swift` — both must point at this fork, or the app updates itself into Tinycast |

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
| Region auto-conversion, crypto | Upstream | — |
| Window management | Upstream, **plus** this fork's fourths and sixths | Upstream's catalog is 32 commands and this one is 42; `window-command-test` asserts the count, so a stale number there is the tell |
| Palette search field position | Upstream — one structural position, conditional *width* | Putting it inside a branch tears down its field editor and drops first responder mid-navigation |
| Notes, in-app updater, launcher aliases, ⌘-digit favorites, clipboard type filter, input-source switcher, Space switching | Upstream only — new features arriving with the sync | — |
| Light appearance | Upstream. The `.darkAqua` lock is gone, and `AGENTS.md` is upstream's | — |
| `AGENTS.md` and `docs/` | Upstream's, renamed — the whole directory comes from there | Re-add the sections describing the Smallcast-only features above, including this file's link |

## After the merge

- `xcodegen generate` — new upstream files arrive under the `Smallcast` glob, but the project still has
  to be regenerated and committed.
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
- **The first Escape clears the query**, the second dismisses. Lost once.
- **Reopening within 30 s of dismissing keeps what was typed.** Lost once.
- **A typo still finds the app** (`chorme` → Google Chrome), and `finder` still does *not* find Find My. Lost once.
- **Moving onto a command with arguments keeps first responder** — no beep, and ↓ keeps stepping.
- **A re-skinned extension draws its tint** in the launcher rows and in the appearance picker.
- **Window management offers 42 commands**, fourths and sixths included.
- **The calculator answers `100km / 2hr` as `50 km/h`** and `$30/hr * 40hr` as money.
