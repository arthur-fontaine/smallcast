# App launcher, search & history

`AppIndex.scan()` runs off-main, enumerates the standard `/Applications` dirs, and dedups by bundle ID
(first dir wins). Icons go through a count-capped `NSCache` (`IconCache`).

## Matching

`FuzzyMatch.score` is a tiered scorer; each kind of match owns a 10 000-wide band, and
`FuzzyMatch.kind(of:)` recovers which one produced a score:

| Kind | Band | Example |
| --- | --- | --- |
| `.exact` | 100 000 | `terminal` → Terminal |
| `.prefix` | 90 000 | `saf` → Safari |
| `.wordStart` | 80 000 | `machine` → Time Machine |
| `.substring` | 70 000 | `cat` → Appli**cat**ion |
| `.subsequence` | 50 000 | `tm` → **T**ime **M**achine |
| `.typo` | 40 000 | `safri` → Safari |

The typo tier is a **bounded Damerau–Levenshtein** distance from the query to the start of the
candidate — or to the start of any of its words, so `managment` still finds Window Management. Trailing
candidate characters are free (`clipbrd` → Clipboard History); leading ones are not. The allowance
scales with query length and is **zero under four characters**, where almost everything is within one
edit. The DP bails as soon as every alignment in a row exceeds the allowance.

`AppIndex.score(_:for:)` is the launcher's whole rule: name first, else the entry's **category**
(`kindLabel` — "Window Management", "Application", an extension's title), which lands in its own low
band so a category hit never outranks a name. A category must be matched from its start or be a
near-miss of it: a mid-word substring would make "cat" list every Appli*cat*ion.

## Ranking

`AppIndex.rank` sorts by match *kind*, then **usage**, then score, then name. Comparing kinds rather
than raw scores is what lets frecency reorder equally good matches without ever promoting a worse one.

`UsageStore` records every launch (`AppCore.launch` is the single funnel) as a count, a last-used date
and the timestamps of the last 32 launches, persisted to `~/Library/Caches/<bundle-id>/usage.json`. `UsageScore` multiplies a capped count by a
recency weight that decays hard (within the hour → 100, today → 60, this week → 30, this month → 12,
older → 4): recency decides between habits, while the count is what lets a habit outrank something
opened once this morning. A launch invalidates `AppIndex`'s one-deep match memo, since the same query
ranks differently a moment later.

**Settings › Search** shows the whole thing: every remembered entry in frecency order with its launch
count, last use and a bar for its score — the same `UsageScore` the launcher sorts by, so the pane
doubles as an explanation of why a result sits where it does. Rows can be forgotten individually, and
`UsageStore.reset(_:)` forgets a window: the last hour, today, the last 7 or 30 days, or everything.

That window is why records keep timestamps at all. With only a total and a last-used date, "reset
today" could only drop a record whole — losing a habit built over months because it was touched this
morning. `UsageRecord.cleared(since:)` instead drops the timestamps inside the window, subtracts just
those from the count, and rewinds `lastUsed` to the newest survivor. Records written before timestamps
existed (or older than the 32 kept) can only be dated once, so a window keeps or drops them whole.

## Recent (history)

**↑ on an empty search** opens `PaletteMode.history` — nothing is lost, since ↑ at the top of the list
did nothing before, and the compact bar ignored it entirely. ↓ then walks the list, ↵ re-runs the entry
(or copies the calculation), ⌘⌫ forgets a single row, ⌫ / the back chevron returns to the launcher. It's
also reachable as the **Search History** command.

`HistoryFeed.build` merges `UsageStore` records with `CalculatorHistoryStore` entries and sorts by
timestamp — deliberately chronological, not ranked: this is "what did I just do", while
`AppIndex.matches` is "what am I looking for". Typing filters it through the same
`AppIndex.score(_:for:)` the launcher uses. Rows are the launcher's `AppRow` and the calculator's
`CalcHistoryRow`, under the shared `DateBucket` day headers.
