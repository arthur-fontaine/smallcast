import Foundation

/// A single evaluated calculator answer for the launcher's inline card.
struct CalcResult: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        /// `display` is grouped and human-facing ("1,234,567"); `copyText` is the same answer without grouping, for pasting onwards.
        case value(display: String, copyText: String)
        /// A friendly error ("Cannot convert Weight to Time.") — only for a clear conversion attempt, never a half-typed expression.
        case error(message: String)
    }

    /// Normalized echo of what was evaluated, shown on the card's left side ("3×3", "10 km").
    let expression: String
    /// Optional word-name pills beneath each side of the card ("Meters"→"Feet", "12:18 AM"→"9:00 AM"); nil for plain arithmetic.
    let sourceBadge: String?
    let targetBadge: String?
    let payload: Payload

    init(expression: String, sourceBadge: String? = nil, targetBadge: String? = nil, payload: Payload) {
        self.expression = expression
        self.sourceBadge = sourceBadge
        self.targetBadge = targetBadge
        self.payload = payload
    }

    /// True only for a copyable value — error cards are informational and have no primary action or actions menu.
    var isActionable: Bool {
        if case .value = payload { return true }
        return false
    }
}

/// Entry point turning a raw query into a calculator answer (or nil when it isn't calculator input), via a pure pre-filter → base → unit → arithmetic pipeline; kept Foundation-only so `Tools/calc-test.swift` compiles it standalone.
enum CalcEngine {
    /// Public entry: evaluates against the live clock.
    static func evaluate(_ raw: String, rates: CurrencyRates = .bundled) -> CalcResult? {
        evaluate(raw, now: Date(), calendar: .current, rates: rates)
    }

    /// `now`/`calendar`/`rates` are injected so the date/time and currency paths are deterministic under `Tools/calc-test.swift`.
    static func evaluate(
        _ raw: String, now: Date, calendar: Calendar, rates: CurrencyRates = .bundled
    ) -> CalcResult? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256 else { return nil }

        // Date/time first: `hrs till july` carries no digit, so it must run before the numeric reject below.
        if let dateTime = CalcDateTime.evaluate(query, now: now, calendar: calendar) { return dateTime }

        guard let raw = CalcTokenizer.tokenize(query), !raw.isEmpty else { return nil }
        let tokens = CalcUnits.normalizingCurrencyPrefixes(raw)

        // A lone literal or constant is more likely an app search than a calculation, so no card — except a radix literal ("0xff"), where echoing the decimal is useful.
        if tokens.count == 1 {
            if case .intLiteral(let value, let radix) = tokens[0], radix != 10 {
                let display = CalcFormatter.grouped(String(value))
                return CalcResult(
                    expression: query,
                    sourceBadge: "Hexadecimal", targetBadge: "Decimal",
                    payload: .value(display: display, copyText: String(value)))
            }
            return nil
        }

        if let base = baseConversion(tokens, query: query) { return base }

        // Conversions run before the numeric reject below: `m to ft`, `day s` carry no digit.
        if let conversion = CalcUnits.parseConversion(tokens, rates: rates)
            ?? CalcUnits.parseUnitPairConversion(tokens, rates: rates)
        {
            switch conversion {
            case .value(let input, let from, let to, let output):
                let rendered = self.rendered(output, to.symbol, money: to.category == .money)
                return CalcResult(
                    expression: quantityText(input, from.symbol, money: from.category == .money),
                    sourceBadge: from.name,
                    targetBadge: to.name,
                    payload: .value(display: rendered.display, copyText: rendered.copyText))
            case .mismatch(let from, let to):
                return CalcResult(
                    expression: query,
                    payload: .error(
                        message:
                            "Cannot convert \(from.category.displayName) to \(to.category.displayName)."
                    ))
            }
        }

        // Keyword-less conversion: `1m` → feet+inches, `1hr` → 60 min, `5$` → euros.
        if let bare = CalcUnits.parseBareConversion(tokens, rates: rates) {
            let rendered = self.rendered(
                bare.output, bare.to.symbol, money: bare.to.category == .money)
            let display =
                bare.compound ? CalcFormatter.compoundFeetInches(bare.output) : rendered.display
            let copyText = bare.compound ? display : rendered.copyText
            return CalcResult(
                expression: quantityText(
                    bare.input, bare.from.symbol, money: bare.from.category == .money),
                sourceBadge: bare.from.name,
                targetBadge: bare.to.name,
                payload: .value(display: display, copyText: copyText))
        }

        // Dimensional arithmetic: `1 km + 1 m`, `100 km / 2 h` → km/h, `5 ft 10 in`. Runs after the
        // single-unit paths above so their curated output (`1m` → feet + inches) still wins.
        if let dimensional = dimensionalExpression(tokens, query: query, rates: rates) {
            return dimensional
        }

        // Natural-language percent: `20% off 500`, `50 as % of 200`.
        if let percent = CalcPercent.evaluate(tokens, query: query, rates: rates) { return percent }

        // Cheap reject for the arithmetic fallback: plain math always carries a digit or a constant, keeping the common app-search case a no-card.
        guard
            query.contains(where: { $0.isASCII && $0.isNumber })
                || query.lowercased().contains("e") || query.contains("π")
        else { return nil }

        guard let value = CalcParser.evaluate(tokens, rates: rates) else { return nil }
        return CalcResult(
            expression: prettyExpression(query),
            sourceBadge: "Expression",
            targetBadge: "Result",
            payload: .value(
                display: CalcFormatter.display(value),
                copyText: CalcFormatter.copyText(value)))
    }

    // MARK: - Dimensional arithmetic

    /// Anything whose value carries units: a sum across units (`1 km + 1 m`), a derived unit
    /// (`100 km / 2 h` → km/h, `2 m * 3 m` → m²), or either of those converted onwards
    /// (`1 km + 1 m to ft`). Returns nil when nothing in the expression is dimensional, so the plain
    /// arithmetic path still owns ordinary math.
    private static func dimensionalExpression(
        _ tokens: [CalcToken], query: String, rates: CurrencyRates
    ) -> CalcResult? {
        // `<expression> to <unit>`, where either side may be compound: `1 km + 1 m to ft`,
        // `10 m/s to km/h`, `0.22 $/h to $/month`.
        if let (index, target) = conversionTarget(tokens, rates: rates) {
            switch CalcParser.evaluateQuantity(Array(tokens[0..<index]), rates: rates) {
            case .value(let quantity):
                guard quantity.unit.dimension == target.dimension else {
                    return mismatchResult(
                        query: query, quantity.unit.dimension.displayName,
                        target.dimension.displayName)
                }
                // The affine term applies only to a plain temperature target — every other unit's is 0.
                let output = (quantity.si - (target.singleUnit?.offset ?? 0)) / target.siFactor
                guard output.isFinite else { return nil }
                let rendered = self.rendered(
                    output, target.symbol, money: target.dimension.isMonetary)
                return CalcResult(
                    expression: quantityText(
                        quantity.magnitude, quantity.unit.symbol,
                        money: quantity.unit.dimension.isMonetary),
                    sourceBadge: quantity.unit.name,
                    targetBadge: target.name,
                    payload: .value(display: rendered.display, copyText: rendered.copyText))
            case .mismatch(let lhs, let rhs):
                return mismatchResult(query: query, lhs.displayName, rhs.displayName, adding: true)
            case .none:
                return nil
            }
        }

        guard isCompound(tokens, rates: rates) else { return nil }
        switch CalcParser.evaluateQuantity(tokens, rates: rates) {
        case .value(let quantity):
            let output = quantity.magnitude
            guard output.isFinite else { return nil }
            let rendered = self.rendered(
                output, quantity.unit.symbol, money: quantity.unit.dimension.isMonetary)
            return CalcResult(
                expression: prettyExpression(query),
                sourceBadge: "Expression",
                targetBadge: quantity.unit.name,
                payload: .value(display: rendered.display, copyText: rendered.copyText))
        case .mismatch(let lhs, let rhs):
            return mismatchResult(query: query, lhs.displayName, rhs.displayName, adding: true)
        case .none:
            return nil
        }
    }

    /// The connector splitting `<expression> to <unit>` and the unit that follows it, searched from the
    /// right so `10 in in cm` reads the trailing "in" as the connector. A single ident is looked up
    /// directly (that's the only way an affine unit like `°F` can be a target, since a temperature never
    /// attaches to a number); anything longer is evaluated as `1 <unit expression>`, which is what makes
    /// `to km/h` work.
    private static func conversionTarget(_ tokens: [CalcToken], rates: CurrencyRates) -> (
        index: Int, unit: CompoundUnit
    )? {
        guard tokens.count >= 3 else { return nil }
        for index in stride(from: tokens.count - 2, through: 1, by: -1)
        where CalcUnits.isConnector(tokens[index]) {
            let rest = Array(tokens[(index + 1)...])
            if rest.count == 1, case .ident(let name) = rest[0],
                let unit = CalcUnits.unit(named: name, rates: rates)
            {
                return (index, CompoundUnit(unit))
            }
            if case .value(let target) = CalcParser.evaluateQuantity(
                [.number(1)] + rest, rates: rates)
            {
                return (index, target.unit)
            }
        }
        return nil
    }

    /// A lone quantity (`5 km`, `5k`) belongs to the curated bare-unit path, which converts it to a
    /// counterpart instead of echoing it back; this path only claims expressions that combine something.
    private static func isCompound(_ tokens: [CalcToken], rates: CurrencyRates) -> Bool {
        var units = 0
        for token in tokens {
            switch token {
            case .op, .arrow: return true
            case .ident(let name) where CalcUnits.unit(named: name, rates: rates) != nil: units += 1
            default: break
            }
        }
        return units >= 2
    }

    private static func mismatchResult(
        query: String, _ lhs: String, _ rhs: String, adding: Bool = false
    ) -> CalcResult {
        CalcResult(
            expression: query,
            payload: .error(
                message: adding ? "Cannot add \(lhs) and \(rhs)." : "Cannot convert \(lhs) to \(rhs)."
            ))
    }

    /// "6.213711922 mi", "160.71 $/month" — a number against its unit, quoted to the cent when what it
    /// counts is money. The one place the two precisions are chosen between, so every card agrees.
    private static func rendered(_ value: Double, _ symbol: String, money: Bool) -> (
        display: String, copyText: String
    ) {
        (
            display: quantityText(value, symbol, money: money),
            copyText: money
                ? "\(CalcFormatter.moneyCopyText(value)) \(symbol)"
                : "\(CalcFormatter.copyText(value)) \(symbol)"
        )
    }

    private static func quantityText(_ value: Double, _ symbol: String, money: Bool) -> String {
        money
            ? "\(CalcFormatter.moneyDisplay(value)) \(symbol)"
            : "\(CalcFormatter.display(value)) \(symbol)"
    }

    // MARK: - Number bases

    /// `255 to hex`, `0xff to decimal`, `0b1010 to binary` — exactly source → connector → target.
    private static func baseConversion(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard tokens.count == 3, CalcUnits.isConnector(tokens[1]),
            case .ident(let target) = tokens[2]
        else { return nil }

        let source: UInt64
        let sourceBadge: String
        switch tokens[0] {
        case .intLiteral(let value, let radix):
            source = value
            sourceBadge = baseName(forRadix: radix)
        case .number(let value)
        where value >= 0 && value.rounded() == value && value <= 9_007_199_254_740_992:
            source = UInt64(value)
            sourceBadge = "Decimal"
        default:
            return nil
        }

        let output: String
        let targetBadge: String
        switch target {
        case "hex", "hexadecimal":
            output = "0x" + String(source, radix: 16, uppercase: true)
            targetBadge = "Hexadecimal"
        case "binary", "bin":
            output = "0b" + String(source, radix: 2)
            targetBadge = "Binary"
        case "octal", "oct":
            output = "0o" + String(source, radix: 8)
            targetBadge = "Octal"
        case "decimal", "dec":
            output = CalcFormatter.grouped(String(source))
            targetBadge = "Decimal"
        default:
            return nil
        }
        let sourceText = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? query
        return CalcResult(
            expression: sourceText,
            sourceBadge: sourceBadge,
            targetBadge: targetBadge,
            payload: .value(
                display: output, copyText: output.replacingOccurrences(of: ",", with: "")))
    }

    private static func baseName(forRadix radix: Int) -> String {
        switch radix {
        case 16: return "Hexadecimal"
        case 2: return "Binary"
        case 8: return "Octal"
        default: return "Decimal"
        }
    }

    /// Light cleanup of the typed expression for the card: collapse whitespace and use pretty operator glyphs, otherwise keep what the user wrote.
    private static func prettyExpression(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "*", with: "×")
            .replacingOccurrences(of: "/", with: "÷")
    }
}
