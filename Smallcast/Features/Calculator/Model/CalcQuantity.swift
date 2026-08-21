import Foundation

/// Typed arithmetic for measurements and currencies.
enum CalcQuantity {
    static func evaluate(
        _ tokens: [CalcToken], query: String, rates: CurrencyRates?, region: String? = nil,
        preserveStandaloneUnit: Bool = false
    ) -> CalcResult? {
        let split = splitConversion(tokens)
        if split.targetName != nil, isSimpleConversionSource(split.expressionTokens) {
            return nil
        }

        var parser = QuantityParser(tokens: split.expressionTokens, rates: rates)
        guard let value = parser.parse() else {
            guard let message = parser.issue else { return nil }
            return CalcResult(expression: query, payload: .error(message: message))
        }
        guard parser.dimensionCount > 0 else { return nil }

        if parser.usedCurrency {
            guard let rates else {
                return CalcResult(
                    expression: query,
                    payload: .error(
                        message: "Exchange rates unavailable — check your connection."))
            }
            if let code = parser.currencyCodes.first(where: { rates.rate(for: $0) == nil }) {
                return CalcResult(
                    expression: query,
                    payload: .error(message: "No exchange rate for \(code)."))
            }
        }

        if let targetName = split.targetName {
            return convertedResult(
                value, targetName: targetName, expressionTokens: split.expressionTokens,
                query: query, rates: rates)
        }

        switch value.kind {
        case .scalar:
            guard parser.operationCount > 0 else { return nil }
            return CalcResult(
                expression: expressionText(split.expressionTokens),
                sourceBadge: "Expression", targetBadge: "Result",
                payload: .value(
                    display: CalcFormatter.display(value.effective),
                    copyText: CalcFormatter.copyText(value.effective)))
        case .unit(let unit):
            // A bare `50cm` auto-converts below; with an operator the typed units are kept.
            if !preserveStandaloneUnit, parser.operationCount == 0, parser.dimensionCount == 1,
                case .ident(let finalName)? = split.expressionTokens.last,
                CalcUnits.byName[finalName] != nil
            {
                return nil
            }
            guard parser.operationCount > 0 || preserveStandaloneUnit else { return nil }
            return measurementResult(
                value.amount, unit: unit, expression: expressionText(split.expressionTokens))
        case .compound(let compound):
            return compoundResult(
                value.amount, unit: compound,
                expression: expressionText(split.expressionTokens))
        case .currency(let definition):
            guard parser.operationCount == 0 else {
                return currencyResult(
                    value.amount, definition: definition,
                    expression: expressionText(split.expressionTokens))
            }
            let expression = "\(CalcFormatter.display(value.amount)) \(definition.code)"
            // A bare amount names no target, so the Mac's own currency becomes one once it's typed.
            guard !preserveStandaloneUnit, let target = regionTarget(region, from: definition),
                let output = rates?.convert(value.amount, from: definition.code, to: target.code)
            else {
                return currencyResult(value.amount, definition: definition, expression: expression)
            }
            return currencyResult(
                output, definition: target, expression: expression, sourceBadge: definition.name)
        }
    }

    /// Nil where converting says nothing: no region, an unknown one, or the currency already typed.
    private static func regionTarget(_ region: String?, from: CurrencyDef) -> CurrencyDef? {
        guard let target = region.flatMap({ CalcCurrency.byName[$0.lowercased()] }),
            target.code != from.code
        else { return nil }
        return target
    }

    private static func convertedResult(
        _ value: QuantityValue, targetName: String, expressionTokens: [CalcToken],
        query: String, rates: CurrencyRates?
    ) -> CalcResult? {
        let expression = expressionText(expressionTokens)
        switch value.kind {
        case .scalar:
            return nil
        case .compound(let from):
            guard let to = CalcUnits.byName[targetName] else {
                guard CalcCurrency.byName[targetName] != nil else { return nil }
                return conversionError(
                    query, from: from.dimension.displayName, to: CalcCurrency.categoryName)
            }
            guard from.dimension == to.dimension else {
                return conversionError(
                    query, from: from.dimension.displayName, to: to.category.displayName)
            }
            let output = value.amount * from.siFactor / to.siFactor
            guard output.isFinite else { return nil }
            return measurementResult(output, unit: to, expression: expression)
        case .unit(let from):
            if let to = CalcUnits.byName[targetName] {
                guard from.category == to.category else {
                    return conversionError(
                        query, from: from.category.displayName, to: to.category.displayName)
                }
                let output = convertUnit(value.amount, from: from, to: to)
                guard output.isFinite else { return nil }
                return measurementResult(output, unit: to, expression: expression)
            }
            if CalcCurrency.byName[targetName] != nil {
                return conversionError(
                    query, from: from.category.displayName, to: CalcCurrency.categoryName)
            }
            return nil
        case .currency(let from):
            if let to = CalcCurrency.byName[targetName] {
                guard let rates else {
                    return CalcResult(
                        expression: query,
                        payload: .error(
                            message: "Exchange rates unavailable — check your connection."))
                }
                guard rates.rate(for: from.code) != nil else {
                    return CalcResult(
                        expression: query,
                        payload: .error(message: "No exchange rate for \(from.code)."))
                }
                guard rates.rate(for: to.code) != nil else {
                    return CalcResult(
                        expression: query,
                        payload: .error(message: "No exchange rate for \(to.code)."))
                }
                guard let output = rates.convert(value.amount, from: from.code, to: to.code)
                else { return nil }
                return currencyResult(output, definition: to, expression: expression)
            }
            if let to = CalcUnits.byName[targetName] {
                return conversionError(
                    query, from: CalcCurrency.categoryName, to: to.category.displayName)
            }
            return nil
        }
    }

    private static func measurementResult(
        _ amount: Double, unit: UnitDef, expression: String
    ) -> CalcResult {
        CalcResult(
            expression: expression,
            sourceBadge: "Expression", targetBadge: unit.name,
            payload: .value(
                display: "\(CalcFormatter.display(amount)) \(unit.symbol)",
                copyText: "\(CalcFormatter.copyText(amount)) \(unit.symbol)"))
    }

    private static func compoundResult(
        _ amount: Double, unit: CompoundUnit, expression: String
    ) -> CalcResult {
        CalcResult(
            expression: expression,
            sourceBadge: "Expression", targetBadge: unit.name,
            payload: .value(
                display: "\(CalcFormatter.display(amount)) \(unit.symbol)",
                copyText: "\(CalcFormatter.copyText(amount)) \(unit.symbol)"))
    }

    private static func currencyResult(
        _ amount: Double, definition: CurrencyDef, expression: String,
        sourceBadge: String = "Expression"
    ) -> CalcResult {
        let formatted = CalcFormatter.currency(amount)
        return CalcResult(
            expression: expression,
            sourceBadge: sourceBadge, targetBadge: definition.name,
            payload: .value(
                display: "\(CalcFormatter.grouped(formatted)) \(definition.code)",
                copyText: "\(formatted) \(definition.code)"))
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
    enum Kind {
        case scalar
        case unit(UnitDef)
        case currency(CurrencyDef)
        /// A product of unit powers the table has no single name for: `kg·m`, `USD/km`, `1/kg`.
        case compound(CompoundUnit)
    }

    var amount: Double
    var kind: Kind
    var isPercent = false

    var effective: Double {
        isPercent ? amount / 100 : amount
    }
}

private struct QuantityParser {
    let tokens: [CalcToken]
    let rates: CurrencyRates?
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
            if !isScalar(left.kind), startsQuantity(current) {
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
            guard isScalar(right.kind) else { return nil }
            let output = pow(left.effective, right.effective)
            guard output.isFinite else { return nil }
            guard !isScalar(left.kind) else {
                return QuantityValue(amount: output, kind: .scalar)
            }
            // Only a whole power keeps the dimension an integer product, so `2m^0.5` stays unanswered.
            let exponent = Int(right.effective)
            guard Double(exponent) == right.effective, let base = unitForm(left.kind),
                let raised = base.raised(to: exponent)
            else { return nil }
            return narrowed(output, raised)
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
            return QuantityValue(amount: output, kind: left.kind)
        }

        switch (left.kind, right.kind) {
        case (.scalar, .scalar):
            return QuantityValue(
                amount: left.effective + direction * right.effective, kind: .scalar)
        case (.unit(let lhs), .unit(let rhs)):
            guard lhs.category == rhs.category else {
                return fail(
                    "Cannot \(op == "+" ? "add" : "subtract") \(lhs.category.displayName) and \(rhs.category.displayName)."
                )
            }
            if lhs.category == .temperature, lhs.symbol != rhs.symbol {
                return fail("Cannot combine temperatures with different units.")
            }
            // Composite ("5 feet 3 inches") answers in its leading unit; `+`/`-` in the last.
            if implicit {
                let converted = CalcQuantity.convertUnit(right.amount, from: rhs, to: lhs)
                return QuantityValue(
                    amount: left.amount + direction * converted, kind: .unit(lhs))
            }
            let converted = CalcQuantity.convertUnit(left.amount, from: lhs, to: rhs)
            return QuantityValue(
                amount: converted + direction * right.amount, kind: .unit(rhs))
        case (.currency(let lhs), .currency(let rhs)):
            if implicit {
                guard let converted = convertedCurrency(right.amount, from: rhs, to: lhs)
                else { return nil }
                return QuantityValue(
                    amount: left.amount + direction * converted, kind: .currency(lhs))
            }
            guard let converted = convertedCurrency(left.amount, from: lhs, to: rhs)
            else { return nil }
            return QuantityValue(
                amount: converted + direction * right.amount, kind: .currency(rhs))
        case (.unit(let lhs), .currency):
            return fail(
                "Cannot \(op == "+" ? "add" : "subtract") \(lhs.category.displayName) and Currency."
            )
        case (.currency, .unit(let rhs)):
            return fail(
                "Cannot \(op == "+" ? "add" : "subtract") Currency and \(rhs.category.displayName)."
            )
        // A compound adds to anything of its own dimension; a bare number takes the unit beside it.
        case (.compound, _), (_, .compound):
            if isScalar(left.kind) || isScalar(right.kind) {
                guard !implicit else { return nil }
                return isScalar(left.kind)
                    ? QuantityValue(
                        amount: left.effective + direction * right.amount, kind: right.kind)
                    : QuantityValue(
                        amount: left.amount + direction * right.effective, kind: left.kind)
            }
            guard let lhs = unitForm(left.kind), let rhs = unitForm(right.kind) else { return nil }
            guard lhs.dimension == rhs.dimension else {
                return fail(
                    "Cannot \(op == "+" ? "add" : "subtract") \(lhs.dimension.displayName) and \(rhs.dimension.displayName)."
                )
            }
            // Composite ("5 feet 3 inches") answers in its leading unit; `+`/`-` in the last.
            if implicit {
                let converted = right.amount * rhs.siFactor / lhs.siFactor
                return QuantityValue(
                    amount: left.amount + direction * converted, kind: .compound(lhs))
            }
            let converted = left.amount * lhs.siFactor / rhs.siFactor
            return QuantityValue(
                amount: converted + direction * right.amount, kind: .compound(rhs))
        // A bare number takes the unit beside it; adjacency stays silent, being a half-typed unit.
        case (.unit, .scalar), (.currency, .scalar):
            guard !implicit else { return nil }
            return QuantityValue(
                amount: left.amount + direction * right.effective, kind: left.kind)
        case (.scalar, .unit), (.scalar, .currency):
            guard !implicit else { return nil }
            return QuantityValue(
                amount: left.effective + direction * right.amount, kind: right.kind)
        }
    }

    private mutating func multiply(
        _ left: QuantityValue, _ right: QuantityValue
    ) -> QuantityValue? {
        switch (left.kind, right.kind) {
        case (.scalar, .scalar):
            return QuantityValue(amount: left.effective * right.effective, kind: .scalar)
        case (.scalar, _):
            return QuantityValue(
                amount: left.effective * right.effective, kind: right.kind)
        case (_, .scalar):
            return QuantityValue(
                amount: left.effective * right.effective, kind: left.kind)
        default:
            return composed(left, right, dividing: false)
        }
    }

    private mutating func divide(
        _ left: QuantityValue, _ right: QuantityValue
    ) -> QuantityValue? {
        switch (left.kind, right.kind) {
        case (.scalar, .scalar):
            return finiteDivision(left.effective, right.effective, kind: .scalar)
        case (.unit, .scalar), (.currency, .scalar):
            return finiteDivision(left.effective, right.effective, kind: left.kind)
        case (.scalar, .unit), (.scalar, .currency):
            return composed(left, right, dividing: true)
        case (.unit(let lhs), .unit(let rhs)):
            guard lhs.category == rhs.category else {
                return composed(left, right, dividing: true)
            }
            guard lhs.category != .temperature else {
                return fail("Division of temperature values is not supported.")
            }
            let numerator = left.amount * lhs.factor
            let denominator = right.amount * rhs.factor
            return finiteDivision(numerator, denominator, kind: .scalar)
        case (.currency(let lhs), .currency(let rhs)):
            guard let denominator = convertedCurrency(right.amount, from: rhs, to: lhs)
            else { return nil }
            return finiteDivision(left.amount, denominator, kind: .scalar)
        case (.unit, .currency), (.currency, .unit):
            return composed(left, right, dividing: true)
        default:
            return composed(left, right, dividing: true)
        }
    }

    private func finiteDivision(
        _ numerator: Double, _ denominator: Double, kind: QuantityValue.Kind
    ) -> QuantityValue? {
        let output = numerator / denominator
        return output.isFinite ? QuantityValue(amount: output, kind: kind) : nil
    }

    private mutating func parseOperand(allowBareUnit: Bool = false) -> QuantityValue? {
        guard var value = parsePrefix(allowBareUnit: allowBareUnit) else { return nil }
        while true {
            switch current {
            case .ident(let name):
                guard isScalar(value.kind), !value.isPercent,
                    let kind = dimension(named: name)
                else { return value }
                value.kind = kind
                dimensionCount += 1
                position += 1
            case .op("%"):
                guard isScalar(value.kind), !value.isPercent else { return nil }
                value.isPercent = true
                position += 1
            case .op("!"):
                guard isScalar(value.kind), !value.isPercent,
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
            return QuantityValue(amount: value, kind: .scalar)
        case .intLiteral(let value, _):
            position += 1
            return QuantityValue(amount: Double(value), kind: .scalar)
        case .op("-"):
            position += 1
            guard let value = parseExpression(minBindingPower: Self.unaryBindingPower)
            else { return nil }
            return QuantityValue(amount: -value.effective, kind: value.kind)
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
                return QuantityValue(amount: 1, kind: .unit(unit))
            }
            guard let definition = CalcCurrency.byName[name] else { return nil }
            // Money is written sign-first (`$10`), so the amount follows its currency here.
            guard let amount = number(at: position + 1) else {
                guard allowBareUnit else { return nil }
                position += 1
                recordCurrency(definition.code)
                dimensionCount += 1
                return QuantityValue(amount: 1, kind: .currency(definition))
            }
            position += 2
            recordCurrency(definition.code)
            dimensionCount += 1
            return QuantityValue(amount: amount, kind: .currency(definition))
        default:
            return nil
        }
    }

    /// A kind as a product of unit powers, so arithmetic can combine kinds with no table entry.
    /// Money has no size until a snapshot prices it, so a missing rate records the issue and fails.
    private mutating func unitForm(_ kind: QuantityValue.Kind) -> CompoundUnit? {
        switch kind {
        case .scalar:
            return nil
        case .unit(let unit):
            return CompoundUnit(unit)
        case .compound(let compound):
            return compound
        case .currency(let definition):
            recordCurrency(definition.code)
            guard let rates else {
                issue = "Exchange rates unavailable — check your connection."
                return nil
            }
            guard let priced = definition.unitDef.priced(at: rates) else {
                issue = "No exchange rate for \(definition.code)."
                return nil
            }
            return CompoundUnit(priced)
        }
    }

    /// Narrows a compound to the simplest kind it is: `5kg / 500g` is a number, `$30/hr * 40hr` is
    /// money again, `100km / 2hr` is the table's own km/h. Only the scalar case moves the amount —
    /// a named equivalent is by definition the same size, and a plain number has no unit to carry it.
    private func narrowed(_ amount: Double, _ compound: CompoundUnit) -> QuantityValue? {
        guard !compound.dimension.isScalar else {
            let output = amount * compound.siFactor
            return output.isFinite ? QuantityValue(amount: output, kind: .scalar) : nil
        }
        guard let unit = compound.singleUnit ?? compound.namedEquivalent else {
            return QuantityValue(amount: amount, kind: .compound(compound))
        }
        // Money keeps its own kind, so the card formats it as currency and not as a measurement.
        guard let code = unit.currency, let definition = CalcCurrency.byName[code.lowercased()]
        else {
            return QuantityValue(amount: amount, kind: .unit(unit))
        }
        return QuantityValue(amount: amount, kind: .currency(definition))
    }

    /// The fallback for every operand pair the typed cases don't answer: carry the units through as
    /// a product of powers rather than refusing the expression.
    private mutating func composed(
        _ left: QuantityValue, _ right: QuantityValue, dividing: Bool
    ) -> QuantityValue? {
        let leftUnit = isScalar(left.kind) ? nil : unitForm(left.kind)
        if !isScalar(left.kind), leftUnit == nil { return nil }
        let rightUnit = isScalar(right.kind) ? nil : unitForm(right.kind)
        if !isScalar(right.kind), rightUnit == nil { return nil }
        guard let combined = CompoundUnit.combine(leftUnit, rightUnit, dividing: dividing) else {
            return finiteDivision(left.effective, right.effective, kind: .scalar)
        }
        let amount =
            dividing
            ? left.effective / right.effective : left.effective * right.effective
        guard amount.isFinite else { return nil }
        return narrowed(amount, combined)
    }

    private mutating func dimension(named name: String) -> QuantityValue.Kind? {
        if let unit = CalcUnits.byName[name] {
            return .unit(unit)
        }
        guard let definition = CalcCurrency.byName[name] else { return nil }
        recordCurrency(definition.code)
        return .currency(definition)
    }

    private mutating func convertedCurrency(
        _ amount: Double, from: CurrencyDef, to: CurrencyDef
    ) -> Double? {
        recordCurrency(from.code)
        recordCurrency(to.code)
        guard let rates else {
            issue = "Exchange rates unavailable — check your connection."
            return nil
        }
        guard rates.rate(for: from.code) != nil else {
            issue = "No exchange rate for \(from.code)."
            return nil
        }
        guard rates.rate(for: to.code) != nil else {
            issue = "No exchange rate for \(to.code)."
            return nil
        }
        return rates.convert(amount, from: from.code, to: to.code)
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
            return CalcUnits.byName[name] == nil && CalcCurrency.byName[name] != nil
                && number(at: position + 1) != nil
        default:
            return false
        }
    }

    private func isScalar(_ kind: QuantityValue.Kind) -> Bool {
        if case .scalar = kind { return true }
        return false
    }

    private mutating func fail(_ message: String) -> QuantityValue? {
        issue = message
        return nil
    }
}
