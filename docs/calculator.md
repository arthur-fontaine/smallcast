# Inline calculator

`Core/Calculator/` is a **Foundation-only** engine (no AppKit / SwiftUI imports) fronted by
`CalcMemo`, a one-deep memo mirroring `AppIndex`'s. It must stay Foundation-only because the
`Tools/calc-test.swift` harness compiles the real engine sources — including `CalcDateTime`.

## Evaluation pipeline

`CalcEngine.evaluate` runs:

1. Natural-language date/time (`CalcDateTime`, e.g. `hrs till 9am`, `days till 9april`,
   `today + 3 weeks`)
2. Numeric reject
3. Tokenize
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

A `CompoundUnit` is the ordered product of table units the user actually wrote; at display time
`namedEquivalent` looks for a table unit with the same dimension *and* size (`km·h⁻¹` → `km/h`,
`km·km` → `km²`, `mph·hr` → `mi`) and falls back to composing the symbol (`kg/(m·s²)`).

Two deliberate exclusions: **temperatures never attach to a number** (they're affine — `20°C + 5°C` has
no meaning, while Kelvin, a ratio scale, is fine), and **`deg` stays the trig postfix** (`sin 30deg`)
rather than the angle unit. A *lone* quantity (`5 km`) is left to the bare-unit path above, which
converts it to a counterpart instead of echoing it back.

Date/time depends on the clock, so it takes an injected `now` / `calendar` — the public `evaluate(_:)`
uses the live clock, and `evaluate(_:now:calendar:)` lets `calc-test.swift` assert exact strings
against a fixed clock.

## Result and rendering

`CalcResult` carries an `expression` (left), a `display` / `copyText` payload (right), and optional
`sourceBadge` / `targetBadge` word-name pills. `CalculatorCard` renders it as a two-column card.

When the launcher or Calculator History query evaluates to a result the card is pinned at the top of
the list (flat selection index 0, shifting rows by one) and Enter copies the answer + records it to
`CalculatorHistoryStore`.
