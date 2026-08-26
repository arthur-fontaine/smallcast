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
  seventeen entries reaches into a file upstream also owns, so "take upstream's file" deletes part of it
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

In the first August 2026 sync this turned 103 replayed commits into 29 real ones. The second one needed
none of it: `419a5b4` was still reachable from `base/main`, the merge base already pointed at it, and the
merge saw exactly the 20 new commits. So run the check first — the plumbing commit is only earned when
the merge base actually walks back past a sync.

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
| `TINYCAST` | `SMALLCAST` | shouted env vars — `SMALLCAST` for custom commands, `SMALLCAST_TEST_JOBS` for the runner |
| `abue-ammar` | `arthur-fontaine` | the Homebrew tap, the release feed, the website URL |

Never rename inside `website/` (upstream's own site, left as Tinycast's), `pnpm-lock.yaml` (integrity
hashes), or the two places that name Tinycast on purpose: this file, and `AGENTS.md`'s pointer to it.
Afterwards, `grep -rniI 'tinycast\|abue-ammar' --exclude-dir=.git --exclude-dir=website
--exclude-dir=node_modules --exclude=pnpm-lock.yaml --exclude=upstream.md --exclude=AGENTS.md .` must
return nothing.

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
| **Escape hands focus back from a field** | — | `PalettePanel.escapeEndsEditing` / `reportEndOfEditing` and `onFieldEditorEndedEditing`; `PaletteWindowController` bumping `palette.focusToken` from it. Upstream leaves the panel with no first responder |
| **A typed search survives a dismissal** (30 s) | — | `PaletteHideReason`; `PaletteWindowController.typedQueryGrace`, `hide(restoreFocus:reason:)` and `schedulePopToRoot(reason:)` guarding on `interval > 0`; `PaletteCoordinator.hidePalette(restoreFocus:reason:)`; the four `.dismissed` sites (three toggles, Escape, `windowDidResignKey`) |
| **Consent before any exchange-rate fetch** | — | `Calculator/Service/CurrencyRateStore.swift` — `isEnabled`, `setEnabled`, `refreshNow`, `provider`, `providerURL`, and the gate in `init`, `start` and `fetchAndStore`. Upstream fetches unconditionally |
| **Derived units** — `100km / 2hr`, `$30/hr * 40hr` | `Calculator/Model/CalcDimension.swift` (`CalcDimension`, `CompoundUnit`, `UnitFormatting`) | `CalcQuantity`: `QuantityValue.Kind.compound`, `unitForm`, `narrowed`, `composed`, the `^` whole-power branch, the `.compound` arms of `multiply` / `divide` / `addOrSubtract` / `convertedResult`, `compoundResult`, and `allowBareUnit` threaded through `parseExpression` / `parseOperand` / `parsePrefix` |
| **Money as a dimension** — what makes a rate possible | — | `CalcUnits`: `UnitCategory.money`, `UnitDef.currency`, `UnitDef.priced(at:)`; `CalcCurrency.unitDef` |
| **Month and year units** — so any rate converts | — | `CalcUnits` — the two `UnitDef`s and their `"month"` / `"year"` plural entries |
| **`CalcUnits.ordered`** | — | `CalcUnits` — declaration order, which is what `CompoundUnit.namedEquivalent` searches |
| **Typo tolerance** | — | `SearchRelevance`: the `typo` tier, `isLiteral` excluding it, `Band.nameTypo` at 0, `bandCount` derived from the top band, `typoScore`, `FuzzyMatch.allowedDistance(forQueryLength:)`, and the `typo:` argument to `consider`. `Tests/fuzz-test.swift`'s typo block and its two hardcoded band indices |
| **Sixths, and four fourths** — 44 window commands, not upstream's 34 | — | `WindowManagement/WindowCommand.swift` (the six `Sixth` cases, the four single-fourth cases and the `sixths` group) and `WindowManagement/WindowLayout.swift` (their geometry). `Tests/window-command-test.swift` asserts the catalog count and each group's, so a stale number is the tell |
| **Fallback commands** — a no-result search offers what accepts any text | `Launcher/Model/FallbackCommand.swift`, `Launcher/UI/FallbackCoordinator.swift`, `Launcher/Settings/FallbackCommandsSection.swift`, `Tests/fallback-test.swift` | `LauncherScreen`'s `Row.fallback` case, its `fallbacks` build in `init` and its `activate` / `actions` / `primaryActionTitle` arms; `LauncherList`'s `fallbacks` / `selectedFallbackID` / `query` / `onFallback` parameters, its `Row.fallback` case and `fallbackRows`; `FallbackCommandsSection()` in `SearchSettingsView`; `FileSearchCoordinator.show(query:)`; `QuicklinkCoordinator.openQuicklink`'s `prefilledArgument:`; `SnippetTemplateEngine.usesArguments`; the three `AppSettingsKey` values and their `SettingsBackupCoverage` entries. `FallbackCommandID.askAI` runs through upstream's `aiChatCoordinator` — see the AI chat row below |
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
| Window management | Upstream, **plus** this fork's sixths and single fourths | Upstream's catalog is 34 commands and this one is 44. Upstream's own `fourths` group holds only First / Last Three Fourths, so the two sets union rather than collide — reconcile case by case, then fix the count and the group counts in `window-command-test` |
| Escape clears before it dismisses | Upstream's `PaletteEscapeAction.resolve` | Contributed upstream from here and restructured there. Keep two things on top of it: `.clearQuery` routes through `CalculatorCoordinator.clearSearch` so a looked-at calculation is still remembered, and `.hidePalette` passes `reason: .dismissed` so the 30 s typed-query grace still applies. A third rider: the `.exitScreen` case and its `mode != .launcher` arm, `PaletteWindowController.exitScreen` as the one funnel a bare backspace also uses, and `PaletteCoordinator.exitScreen` forwarding to it. **`palette-escape-test` asserts this**, so taking upstream's resolve *and* upstream's harness reverts both with nothing failing |
| AI chat | Upstream's, entirely — five providers, an optional ChatGPT subscription through Codex, model discovery, system prompts, chat history and markdown tables | This fork shipped its own AI chat in PR #18 the day before this sync, so both existed at once. Upstream's `openAICompatible` provider plus its loopback handling covers LM Studio and Ollama, so nothing was lost but the named presets. Three things ride on top, all in files upstream owns: the `AIProviderKind.ollama` / `.lmStudio` presets with their `title` / `defaultBaseURL` / `modelPlaceholder` arms, the `acceptsUnlistedModels` gate that replaced a bare `== .openAICompatible` check, `AIModelDiscovery.isEmbedding`, and the `adoptLocalAddress(for:)` call in `AISettingsView`'s `onChange(of: connection.provider)`; `FallbackCoordinator`'s `.askAI` arm calling `startNewChat()` / `showChat()` / `send(_:)`; and `aiEnabled` staying out of settings backups because it doubles as consent to send typed text off the Mac. `ai-provider-test` asserts each preset's two endpoints |
| Parenthesised conversions | Upstream — `QuantityParser.converted` returns a `QuantityValue` now, not a `CalcResult` | This fork's compound-unit conversion moved with it: the `.compound` arm belongs in `converted` and reports through `fail(_:)`, while `convertedResult` only formats |
| Palette search field position | Upstream — one structural position, conditional *width* | Putting it inside a branch tears down its field editor and drops first responder mid-navigation |
| Notes, in-app updater, launcher aliases, ⌘-digit favorites, clipboard type filter, input-source switcher, Space switching | Upstream only — new features arriving with the sync | — |
| The Calendar and meeting screens, extension OAuth, Raycast v2 encrypted import, release notes in the update window | Upstream only — new features arriving with the sync | Each brings its own `SettingsTab` case, `AppCore` store and harness. `Info.plist` gains camera and calendar usage strings, and `project.yml` ships `NOTICE.md` as a resource for the brand marks |
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
- **The first Escape clears the query**, the second dismisses — and clearing still commits the
  calculation that was on screen.
- **Escape on a sub-screen goes back, it does not close.** Only the launcher's own Escape dismisses.
- **Escape inside an extension's form field** clears the field and leaves the palette closeable.
- **Reopening within 30 s of dismissing keeps what was typed.** Lost once.
- **A typo still finds the app** (`chorme` → Google Chrome), and `finder` still does *not* find Find My. Lost once.
- **Moving onto a command with arguments keeps first responder** — no beep, and ↓ keeps stepping.
- **A re-skinned extension draws its tint** in the launcher rows and in the appearance picker.
- **Window management offers 42 commands**, fourths and sixths included.
- **The calculator answers `100km / 2hr` as `50 km/h`** and `$30/hr * 40hr` as money.
