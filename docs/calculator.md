# Inline calculator

`Core/Calculator/` is a **Foundation-only** engine (no AppKit / SwiftUI imports) fronted by
`CalcMemo`, a one-deep memo mirroring `AppIndex`'s. It must stay Foundation-only because the
`Tools/calc-test.swift` harness compiles the real engine sources — including `CalcDateTime`.

## Evaluation pipeline

`CalcEngine.evaluate` runs:

1. Natural-language date/time (`CalcDateTime`, e.g. `hrs till 9am`, `days till 9april`,
   `today + 3 weeks`)
2. Numeric reject
3. Tokenize, then `CalcUnits.normalizingCurrencyPrefixes` (`$5` → `5 $`)
4. Base conversion
5. Explicit unit conversion (`10km to mi`)
6. **Bare-unit auto-conversion** (`1m` → feet + inches, `1hr` → 60 min, via
   `CalcUnits.parseBareConversion` + the `autoTargets` map)
7. **Dimensional arithmetic** (`1km + 1m`, `100km / 2h` → km/h — see below)
8. Natural-language percent (`20% off 500`)
9. Plain arithmetic

## Dimensional arithmetic

`CalcQuantity.swift` gives every unit a `Dimension` (exponents over length, mass, time, information,
angle, temperature) and an SI factor, so the parser can carry units through an expression instead of
only converting between two of them:

- **Sums across units** — `1 km + 1 m` → `1.001 km`, `1 GB + 500 MB` → `1.5 GB`. The result reads in the
  unit written first; different dimensions produce a named error ("Cannot add Length and Weight.").
- **Adjacent quantities add up** — `5 ft 10 in`, `1 hr 30 min`.
- **Derived units** — `100 km / 2 h` → `50 km/h`, `2 m * 3 m` → `6 m²`, `60 mph * 2 hr` → `120 mi`,
  `1 kg * 9.81 m / 1 s^2` → `9.81 kg·m/s²`. Units that fully cancel leave a plain number
  (`10 km / 2 km` → `5`).
- **Either side of a conversion may be compound** — `1km+1m to ft`, `10 m/s to km/h`.
- **A rate converts on both halves at once** — `1km/h to m/month`, `0.22$/h to $/month`,
  `2000 €/month to $/year`. Nothing special-cases these; they're two compound units of the same
  dimension, so the line above already covers them.

A `CompoundUnit` is the ordered product of table units the user actually wrote; at display time
`namedEquivalent` looks for a table unit with the same dimension *and* size (`km·h⁻¹` → `km/h`,
`km·km` → `km²`, `mph·hr` → `mi`) and falls back to composing the symbol (`kg/(m·s²)`).

`month` and `year` are ordinary time units sized to the Gregorian average (365.2425 days, and a twelfth
of that) — the only reading under which a per-month rate means anything definite. Date arithmetic is
untouched by them: `today + 3 weeks` still goes through `CalcDateTime`, which walks the real calendar.

Two deliberate exclusions: **temperatures never attach to a number** (they're affine — `20°C + 5°C` has
no meaning, while Kelvin, a ratio scale, is fine), and **`deg` stays the trig postfix** (`sin 30deg`)
rather than the angle unit. A *lone* quantity (`5 km`) is left to the bare-unit path above, which
converts it to a counterpart instead of echoing it back.

## Money

Currencies are a unit category like any other (`CalcDimension.money`), so everything above falls out of
the dimensional layer: `100 $ to €`, `10 $ + 5 €` (reads in the unit written first), `10 $ / 2 $` → a
plain 5, `10 $ to kg` → "Cannot convert Money to Weight." What's different is that a currency has **no
fixed size** — `CalcUnits.money` holds only the ISO code and how to render it, and
`CalcUnits.unit(named:rates:)` stamps on a factor from the day's snapshot. A currency the snapshot
doesn't quote resolves to nothing at all rather than to a guessed rate.

- **`CurrencyRates`** (`Core/Calculator/CalcCurrency.swift`) is that snapshot: units per 1 EUR, the ECB's
  own base. It's *injected* into `CalcEngine.evaluate`, exactly like `now` / `calendar`, which keeps the
  engine a pure function and lets `calc-test.swift` assert money answers against pinned rates instead of
  whatever the market did today. `CurrencyRates.bundled` ships with the app so the first launch converts.
- **`CurrencyRatesStore`** (`Core/CurrencyRatesStore.swift`) is the only thing that knows rates change:
  it fetches the ECB daily reference rates through frankfurter.dev (no key, ~600 bytes), caches them
  under `~/Library/Caches/<bundle-id>/currency-rates.json`, and re-checks every 6 hours so a menu-bar app
  left running for weeks doesn't drift. Every failure leaves the snapshot in hand untouched.
- **`CalcMemo` is keyed on the rates as well as the query**, so a card priced at the cached snapshot
  recomputes the moment today's lands.
- Amounts are quoted **to the cent** (`CalcFormatter.moneyDisplay`) rather than to the engine's ten
  significant digits, with trailing zeros trimmed like every other value ("90.91 €", "110 $"). Sub-cent
  amounts keep full precision instead of collapsing to zero.
- A symbol may lead its amount (`$5`) — that's what step 3 of the pipeline normalizes. Only the glyphs
  move: `php 8` is a search for the language, not eight pesos.
- `¥` reads as yen and `$` as US dollars; the other claimants to those glyphs are reachable by code
  (`cny`, `cad`, `aud`). `pound` stays the unit of weight — GBP is `gbp`, `£` or `sterling`.

Date/time depends on the clock, so it takes an injected `now` / `calendar` — the public `evaluate(_:)`
uses the live clock, and `evaluate(_:now:calendar:rates:)` lets `calc-test.swift` assert exact strings
against a fixed clock and fixed rates.

## Result and rendering

`CalcResult` carries an `expression` (left), a `display` / `copyText` payload (right), and optional
`sourceBadge` / `targetBadge` word-name pills. `CalculatorCard` renders it as a two-column card.

When the launcher or Calculator History query evaluates to a result the card is pinned at the top of
the list (flat selection index 0, shifting rows by one) and Enter copies the answer + records it to
`CalculatorHistoryStore`.

## What reaches the history

Copying isn't the only way in — a calculation you only *looked at* is still one you did. `AppCore`
records whatever the search evaluates to at the moments the query stops being edited:

- **Escape** clearing the field (`clearSearch`)
- every **`PaletteViewModel.prepare`** — the pop-to-root reset after the window closes, a mode switch, a
  fresh summon — via the `onWillReset` hook, which fires while the query is still readable

Editing never commits, which is what makes the rule feel right: growing `1+2` into `1+21` records only
the latter, and closing the palette then reopening within the 30-second grace to keep typing replaces
the pending calculation instead of saving it. Committing the same thing twice is harmless —
`record` drops a repeat of the newest entry, so the copy path and a following reset can't duplicate.

Only the two screens that show the card (`.launcher`, `.calculatorHistory`) count: inside a running
extension command the search bar belongs to the extension, and text typed into its filter isn't a
calculation.
