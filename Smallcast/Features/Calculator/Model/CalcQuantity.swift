import Foundation

/// Typed arithmetic for measurements and consent-gated currencies.
enum CalcQuantity {
    static func evaluate(
        _ tokens: [CalcToken], query: String, currency: CurrencySource,
        preserveStandaloneUnit: Bool = false
    ) -> CalcResult? {
        let split = splitConversion(tokens)
        if split.targetName != nil, isSimpleConversionSource(split.expressionTokens) {
            return nil
        }

        var parser = QuantityParser(tokens: split.expressionTokens, currency: currency)
        guard let value = parser.parse() else {
            guard let message = parser.issue else { return nil }
            return CalcResult(expression: query, payload: .error(message: message))
        }
        guard parser.dimensionCount > 0 else { return nil }

        if parser.usedCurrency {
            switch currency {
            case .off:
                return nil
            case .on(nil):
                return CalcResult(
                    expression: query,
                    payload: .error(
                        message: "Exchange rates unavailable — check your connection."))
            case .on(let rates?):
                if let code = parser.currencyCodes.first(where: { rates.rate(for: $0) == nil }) {
                    return CalcResult(
                        expression: query,
                        payload: .error(message: "No exchange rate for \(code)."))
                }
            }
        }

        if let targetName = split.targetName {
            return convertedResult(
                value, targetName: targetName, expressionTokens: split.expressionTokens,
                query: query, currency: currency)
        }

        guard let unit = value.unit else {
            guard parser.operationCount > 0 else { return nil }
            return CalcResult(
                expression: expressionText(split.expressionTokens),
                sourceBadge: "Expression", targetBadge: "Result",
                payload: .value(
                    display: CalcFormatter.display(value.effective),
                    copyText: CalcFormatter.copyText(value.effective)))
        }

        // A lone amount of money is its own answer; a lone `50cm` auto-converts below instead.
        if let money = unit.singleUnit, money.currency != nil {
            return result(
                value.amount, unit: unit,
                expression: parser.operationCount == 0
                    ? "\(CalcFormatter.display(value.amount)) \(money.symbol)"
                    : expressionText(split.expressionTokens))
        }

        if !preserveStandaloneUnit, parser.operationCount == 0, parser.dimensionCount == 1,
            case .ident(let finalName)? = split.expressionTokens.last,
            CalcUnits.byName[finalName] != nil
        {
            return nil
        }
        guard parser.operationCount > 0 || preserveStandaloneUnit else { return nil }
        return result(
            value.amount, unit: unit, expression: expressionText(split.expressionTokens))
    }

    private static func convertedResult(
        _ value: QuantityValue, targetName: String, expressionTokens: [CalcToken],
        query: String, currency: CurrencySource
    ) -> CalcResult? {
        let expression = expressionText(expressionTokens)
        guard let from = value.unit else { return nil }
        guard let to = targetUnit(named: targetName, currency: currency) else { return nil }

        guard from.dimension == to.dimension else {
            return conversionError(
                query, from: from.dimension.displayName, to: to.dimension.displayName)
        }
        guard let output = convert(value.amount, from: from, to: to), output.isFinite else {
            return nil
        }
        return result(output, unit: to, expression: expression)
    }

    /// The target of a `to`/`in`/`→` conversion: a table unit, else a currency priced at today's
    /// snapshot. A currency the snapshot doesn't quote resolves to nil, so no card is shown.
    private static func targetUnit(named name: String, currency: CurrencySource) -> CompoundUnit? {
        if let unit = CalcUnits.byName[name] { return CompoundUnit(unit) }
        guard case .on(let rates) = currency, let rates,
            let unit = CalcCurrency.unit(named: name)?.priced(at: rates)
        else { return nil }
        return CompoundUnit(unit)
    }

    /// Affine units (temperature) only ever stand alone, so the offset path is the single-unit one;
    /// everything else converts by the ratio of SI factors, compound units included.
    fileprivate static func convert(
        _ amount: Double, from: CompoundUnit, to: CompoundUnit
    ) -> Double? {
        if let from = from.singleUnit, let to = to.singleUnit,
            from.offset != 0 || to.offset != 0
        {
            return convertUnit(amount, from: from, to: to)
        }
        let factor = from.siFactor / to.siFactor
        return factor.isFinite ? amount * factor : nil
    }

    /// One renderer for both flavours: an amount of money reads as `1,234.00 USD`, everything else
    /// as `12 km/h`. A rate built on money (`$/h`) is a measurement, not an amount, so it takes the
    /// measurement form.
    private static func result(
        _ amount: Double, unit: CompoundUnit, expression: String
    ) -> CalcResult {
        if let money = unit.singleUnit, money.currency != nil {
            let formatted = CalcFormatter.currency(amount)
            return CalcResult(
                expression: expression,
                sourceBadge: "Expression", targetBadge: money.name,
                payload: .value(
                    display: "\(CalcFormatter.grouped(formatted)) \(money.symbol)",
                    copyText: "\(formatted) \(money.symbol)"))
        }
        return CalcResult(
            expression: expression,
            sourceBadge: "Expression", targetBadge: unit.name,
            payload: .value(
                display: "\(CalcFormatter.display(amount)) \(unit.symbol)",
                copyText: "\(CalcFormatter.copyText(amount)) \(unit.symbol)"))
    }

    private static func conversionError(_ query: String, from: String, to: String) -> CalcResult {
        CalcResult(
            expression: query,
            payload: .error(message: "Cannot convert \(from) to \(to)."))
    }

    fileprivate static func convertUnit(_ amount: Double, from: UnitDef, to: UnitDef) -> Double {
        (amount * from.factor + from.offset - to.offset) / to.factor
    }

    private static func splitConversion(
        _ tokens: [CalcToken]
    ) -> (expressionTokens: [CalcToken], targetName: String?) {
        guard tokens.count >= 3, CalcUnits.isConnector(tokens[tokens.count - 2]),
            case .ident(let targetName) = tokens[tokens.count - 1]
        else { return (tokens, nil) }

        var depth = 0
        for token in tokens.dropLast(2) {
            if case .op("(") = token { depth += 1 }
            if case .op(")") = token { depth -= 1 }
        }
        guard depth == 0 else { return (tokens, nil) }
        return (Array(tokens.dropLast(2)), targetName)
    }

    private static func isSimpleConversionSource(_ tokens: [CalcToken]) -> Bool {
        switch tokens.count {
        case 1:
            if case .ident = tokens[0] { return true }
        case 2:
            switch (tokens[0], tokens[1]) {
            case (.number, .ident), (.compactNumber, .ident),
                (.ident, .number), (.ident, .compactNumber):
                return true
            default:
                break
            }
        default:
            break
        }
        return false
    }

    /// Normalized echo for the card's left column: symbols, pretty glyphs, `amount code` money.
    private static func expressionText(_ tokens: [CalcToken]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(tokens.count)
        var attachNext = true

        func add(_ piece: String, attached: Bool = false) {
            if attachNext || attached, !parts.isEmpty {
                parts[parts.count - 1] += piece
            } else {
                parts.append(piece)
            }
            attachNext = false
        }

        var index = 0
        while index < tokens.count {
            // Money is written sign-first (`$10`), so echo the amount ahead of its code.
            if case .ident(let name) = tokens[index], CalcUnits.byName[name] == nil,
                let definition = CalcCurrency.byName[name], index + 1 < tokens.count,
                let amount = numberValue(tokens[index + 1])
            {
                add(CalcFormatter.copyText(amount))
                add(definition.code)
                index += 2
                continue
            }

            switch tokens[index] {
            case .number(let value), .compactNumber(let value):
                add(CalcFormatter.copyText(value))
            case .intLiteral(let value, _):
                add(String(value))
            case .ident(let name):
                add(CalcUnits.byName[name]?.symbol ?? CalcCurrency.byName[name]?.code ?? name)
            case .op("("):
                add("(")
                attachNext = true
            case .op(")"):
                add(")", attached: true)
            case .op("%"):
                add("%", attached: true)
            case .op("!"):
                add("!", attached: true)
            case .op("*"):
                add("×")
            case .op("/"):
                add("÷")
            case .op(let op):
                add(String(op))
                if op == "-" || op == "+" { attachNext = isSign(at: index, tokens) }
            case .arrow:
                add("→")
            }
            index += 1
        }
        return parts.joined(separator: " ")
    }

    /// True when `+`/`-` negates the operand that follows rather than joining two of them.
    private static func isSign(at index: Int, _ tokens: [CalcToken]) -> Bool {
        guard index > 0 else { return true }
        if case .op(let previous) = tokens[index - 1] {
            return previous != ")" && previous != "%" && previous != "!"
        }
        return false
    }

    fileprivate static func numberValue(_ token: CalcToken) -> Double? {
        switch token {
        case .number(let value), .compactNumber(let value):
            return value
        default:
            return nil
        }
    }
}

private struct QuantityValue {
    var amount: Double
    /// Nil for a plain number; otherwise the unit as written, `km/h` and `kg/(m·s²)` included.
    var unit: CompoundUnit?
    var isPercent = false

    var effective: Double {
        isPercent ? amount / 100 : amount
    }

    var isScalar: Bool { unit == nil }
    var dimension: CalcDimension { unit?.dimension ?? .scalar }
}

private struct QuantityParser {
    let tokens: [CalcToken]
    let currency: CurrencySource
    var position = 0
    var operationCount = 0
    var dimensionCount = 0
    var usedCurrency = false
    var currencyCodes: [String] = []
    var issue: String?

    private static let unaryBindingPower = 25

    private var current: CalcToken? {
        position < tokens.count ? tokens[position] : nil
    }

    private var currencyEnabled: Bool {
        if case .on = currency { return true }
        return false
    }

    private var rates: CurrencyRates? {
        if case .on(let rates) = currency { return rates }
        return nil
    }

    mutating func parse() -> QuantityValue? {
        guard let value = parseExpression(minBindingPower: 0), position == tokens.count,
            value.effective.isFinite
        else { return nil }
        return value
    }

    private mutating func parseExpression(
        minBindingPower: Int, allowBareUnit: Bool = false
    ) -> QuantityValue? {
        guard var left = parseOperand(allowBareUnit: allowBareUnit) else { return nil }
        while let binary = peekBinary(left: left), binary.bindingPower >= minBindingPower {
            if binary.consumesToken { position += 1 }
            operationCount += 1
            guard
                let right = parseExpression(
                    minBindingPower: binary.rightBindingPower,
                    // `60km / h` — a denominator names the unit without repeating "1".
                    allowBareUnit: binary.op == "*" || binary.op == "/"),
                let combined = apply(
                    binary.op, left, right, implicit: !binary.consumesToken)
            else { return nil }
            left = combined
        }
        return left
    }

    /// An operator, its binding power, its right operand's minimum, and whether it consumes.
    struct BinaryOp {
        let op: Character
        let bindingPower: Int
        let rightBindingPower: Int
        let consumesToken: Bool
    }

    private func peekBinary(left: QuantityValue) -> BinaryOp? {
        switch current {
        case .op(let op) where op == "+" || op == "-":
            return BinaryOp(op: op, bindingPower: 10, rightBindingPower: 11, consumesToken: true)
        case .op(let op) where op == "*" || op == "/":
            return BinaryOp(op: op, bindingPower: 20, rightBindingPower: 21, consumesToken: true)
        case .ident("of"):
            return BinaryOp(op: "*", bindingPower: 20, rightBindingPower: 21, consumesToken: true)
        case .op("^"):
            return BinaryOp(op: "^", bindingPower: 30, rightBindingPower: 30, consumesToken: true)
        default:
            // Juxtaposition against a bracket multiplies, matching the scalar parser.
            if case .op("(") = current {
                return BinaryOp(op: "*", bindingPower: 20, rightBindingPower: 21, consumesToken: false)
            }
            if !left.isScalar, startsQuantity(current) {
                return BinaryOp(op: "+", bindingPower: 10, rightBindingPower: 11, consumesToken: false)
            }
            return nil
        }
    }

    private mutating func apply(
        _ op: Character, _ left: QuantityValue, _ right: QuantityValue, implicit: Bool
    ) -> QuantityValue? {
        switch op {
        case "+", "-":
            return addOrSubtract(op, left, right, implicit: implicit)
        case "*":
            return multiply(left, right)
        case "/":
            return divide(left, right)
        case "^":
            return raise(left, to: right)
        default:
            return nil
        }
    }

    private mutating func addOrSubtract(
        _ op: Character, _ left: QuantityValue, _ right: QuantityValue, implicit: Bool
    ) -> QuantityValue? {
        let direction = op == "+" ? 1.0 : -1.0
        if right.isPercent {
            let output = left.effective * (1 + direction * right.amount / 100)
            return QuantityValue(amount: output, unit: left.unit)
        }

        switch (left.unit, right.unit) {
        case (nil, nil):
            return QuantityValue(amount: left.effective + direction * right.effective, unit: nil)
        case (let lhs?, let rhs?):
            guard lhs.dimension == rhs.dimension else {
                return fail(
                    "Cannot \(op == "+" ? "add" : "subtract") \(lhs.dimension.displayName) and "
                        + "\(rhs.dimension.displayName).")
            }
            if lhs.dimension == UnitCategory.temperature.dimension,
                lhs.symbol != rhs.symbol
            {
                return fail("Cannot combine temperatures with different units.")
            }
            // Composite ("5 feet 3 inches") answers in its leading unit; `+`/`-` in the last.
            if implicit {
                guard let converted = CalcQuantity.convert(right.amount, from: rhs, to: lhs)
                else { return nil }
                return QuantityValue(amount: left.amount + direction * converted, unit: lhs)
            }
            guard let converted = CalcQuantity.convert(left.amount, from: lhs, to: rhs)
            else { return nil }
            return QuantityValue(amount: converted + direction * right.amount, unit: rhs)
        // A bare number takes the unit beside it; adjacency stays silent, being a half-typed unit.
        case (.some, nil):
            guard !implicit else { return nil }
            return QuantityValue(
                amount: left.amount + direction * right.effective, unit: left.unit)
        case (nil, .some):
            guard !implicit else { return nil }
            return QuantityValue(
                amount: left.effective + direction * right.amount, unit: right.unit)
        }
    }

    /// Units multiply into a product: `1kg * 1m` is `1 kg·m`, `20 * $3/h` is `60 $/h`. Temperature is
    /// the exception — an affine scale has no meaningful product.
    private mutating func multiply(
        _ left: QuantityValue, _ right: QuantityValue
    ) -> QuantityValue? {
        guard !isAffine(left), !isAffine(right) else {
            return fail("Multiplication of temperature values is not supported.")
        }
        return combined(
            left.effective * right.effective,
            CompoundUnit.combine(left.unit, right.unit, dividing: false))
    }

    /// Division builds the reciprocal term, which is what makes `100km / 2h` a speed and `$20 / 4h`
    /// a rate. Matching units cancel, so `km / km` is a plain number.
    private mutating func divide(
        _ left: QuantityValue, _ right: QuantityValue
    ) -> QuantityValue? {
        guard !isAffine(left), !isAffine(right) else {
            return fail("Division of temperature values is not supported.")
        }
        let output = left.effective / right.effective
        guard output.isFinite else { return nil }
        return combined(output, CompoundUnit.combine(left.unit, right.unit, dividing: true))
    }

    /// Units that cancel dimensionally without cancelling by symbol — `5kg / 500g` — leave a
    /// compound that measures nothing. Folding its factor into the amount is what makes that a plain
    /// 10 rather than "0.01 kg/g".
    private func combined(_ amount: Double, _ unit: CompoundUnit?) -> QuantityValue? {
        guard let unit else { return QuantityValue(amount: amount, unit: nil) }
        guard unit.dimension.isScalar else { return QuantityValue(amount: amount, unit: unit) }
        let output = amount * unit.siFactor
        return output.isFinite ? QuantityValue(amount: output, unit: nil) : nil
    }

    /// `(2m)^2` is an area; a non-integer power of a unit has no meaning, so only scalars take one.
    private mutating func raise(_ left: QuantityValue, to right: QuantityValue) -> QuantityValue? {
        guard right.isScalar else { return nil }
        guard let unit = left.unit else {
            let output = pow(left.effective, right.effective)
            return output.isFinite ? QuantityValue(amount: output, unit: nil) : nil
        }
        guard !isAffine(left), right.effective == right.effective.rounded(),
            abs(right.effective) <= 8, let raised = unit.raised(to: Int(right.effective))
        else { return nil }
        let output = pow(left.amount, right.effective)
        return output.isFinite ? QuantityValue(amount: output, unit: raised) : nil
    }

    /// True for a value on an affine scale — a lone °C or °F, which only adds and converts.
    private func isAffine(_ value: QuantityValue) -> Bool {
        (value.unit?.singleUnit?.offset ?? 0) != 0
    }

    private mutating func parseOperand(allowBareUnit: Bool = false) -> QuantityValue? {
        guard var value = parsePrefix(allowBareUnit: allowBareUnit) else { return nil }
        while true {
            switch current {
            case .ident(let name):
                guard value.isScalar, !value.isPercent, let unit = unit(named: name)
                else { return value }
                value.unit = CompoundUnit(unit)
                dimensionCount += 1
                position += 1
            case .op("%"):
                guard value.isScalar, !value.isPercent else { return nil }
                value.isPercent = true
                position += 1
            case .op("!"):
                guard value.isScalar, !value.isPercent,
                    let factorial = CalcParser.factorial(value.amount)
                else { return nil }
                value.amount = factorial
                position += 1
            default:
                return value
            }
        }
    }

    private mutating func parsePrefix(allowBareUnit: Bool = false) -> QuantityValue? {
        switch current {
        case .number(let value), .compactNumber(let value):
            position += 1
            return QuantityValue(amount: value, unit: nil)
        case .intLiteral(let value, _):
            position += 1
            return QuantityValue(amount: Double(value), unit: nil)
        case .op("-"):
            position += 1
            guard let value = parseExpression(minBindingPower: Self.unaryBindingPower)
            else { return nil }
            return QuantityValue(amount: -value.effective, unit: value.unit)
        case .op("+"):
            position += 1
            return parseExpression(minBindingPower: Self.unaryBindingPower)
        case .op("("):
            position += 1
            guard let value = parseExpression(minBindingPower: 0),
                case .op(")") = current
            else { return nil }
            position += 1
            return value
        case .ident(let name):
            if let unit = CalcUnits.byName[name] {
                guard allowBareUnit else { return nil }
                position += 1
                dimensionCount += 1
                return QuantityValue(amount: 1, unit: CompoundUnit(unit))
            }
            // Money is written sign-first (`$10`), so the amount follows its currency here.
            guard currencyEnabled, let unit = money(named: name) else { return nil }
            guard let amount = number(at: position + 1) else {
                guard allowBareUnit else { return nil }
                position += 1
                dimensionCount += 1
                return QuantityValue(amount: 1, unit: CompoundUnit(unit))
            }
            position += 2
            dimensionCount += 1
            return QuantityValue(amount: amount, unit: CompoundUnit(unit))
        default:
            return nil
        }
    }

    private mutating func unit(named name: String) -> UnitDef? {
        if let unit = CalcUnits.byName[name] { return unit }
        guard currencyEnabled else { return nil }
        return money(named: name)
    }

    /// A currency priced at today's snapshot. With no snapshot, or none quoting this currency, the
    /// code is still recorded and the unit stands in at parity — `evaluate` turns that record into
    /// the "rates unavailable" / "no exchange rate" message before any amount is shown.
    private mutating func money(named name: String) -> UnitDef? {
        guard let unpriced = CalcCurrency.unit(named: name) else { return nil }
        recordCurrency(unpriced.currency ?? "")
        guard let rates, let priced = unpriced.priced(at: rates) else { return unpriced }
        return priced
    }

    private mutating func recordCurrency(_ code: String) {
        usedCurrency = true
        if !currencyCodes.contains(code) { currencyCodes.append(code) }
    }

    private func number(at index: Int) -> Double? {
        guard index < tokens.count else { return nil }
        return CalcQuantity.numberValue(tokens[index])
    }

    private func startsQuantity(_ token: CalcToken?) -> Bool {
        switch token {
        case .number, .compactNumber, .intLiteral:
            return true
        case .ident(let name):
            return currencyEnabled && CalcUnits.byName[name] == nil
                && CalcCurrency.byName[name] != nil
                && number(at: position + 1) != nil
        default:
            return false
        }
    }

    private mutating func fail(_ message: String) -> QuantityValue? {
        issue = message
        return nil
    }
}
