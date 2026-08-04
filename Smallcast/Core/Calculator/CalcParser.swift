import Foundation

enum CalcToken: Equatable, Sendable {
    case number(Double)
    /// Radix-prefixed integer literal (0xff / 0b1010 / 0o777), kept exact for base conversion.
    case intLiteral(UInt64, radix: Int)
    /// Lowercased word (function, constant, unit, or connector); `²`/`³` fold to "2"/"3" so `m²` and `m2` match, while `°` is kept.
    case ident(String)
    case op(Character)  // + - * / ^ ! % ( )
    case arrow  // -> or →
}

enum CalcTokenizer {
    /// nil on any character that can't be calculator input — the caller treats that as "not a calculation", never an error.
    static func tokenize(_ input: String) -> [CalcToken]? {
        let chars = Array(input)
        var tokens: [CalcToken] = []
        var i = 0

        func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
                continue
            }

            // Radix literals: 0x… / 0b… / 0o… — needs ≥1 digit after the prefix, else fall through so "0" parses as a plain number.
            if ch == "0", i + 2 < chars.count,
                let radix = ["x": 16, "b": 2, "o": 8][String(chars[i + 1]).lowercased()]
            {
                let start = i + 2
                var end = start
                while end < chars.count, chars[end].isHexDigit { end += 1 }
                if end > start, let value = UInt64(String(chars[start..<end]), radix: radix) {
                    tokens.append(.intLiteral(value, radix: radix))
                    i = end
                    continue
                }
            }

            if isDigit(ch) || (ch == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
                var text = ""
                var seenDot = false
                while i < chars.count {
                    let c = chars[i]
                    if isDigit(c) {
                        text.append(c)
                    } else if c == "," && i + 1 < chars.count && isDigit(chars[i + 1]) {
                        // grouping separator between digits — skip
                    } else if c == "." && !seenDot {
                        seenDot = true
                        text.append(c)
                    } else {
                        break
                    }
                    i += 1
                }
                guard let value = Double(text) else { return nil }
                tokens.append(.number(value))
                continue
            }

            if ch.isLetter || ch == "°" {
                var text = ""
                while i < chars.count {
                    let c = chars[i]
                    if c.isLetter || c == "°" || isDigit(c) {
                        text.append(c)
                    } else if c == "²" {
                        text.append("2")
                    } else if c == "³" {
                        text.append("3")
                    } else {
                        break
                    }
                    i += 1
                }
                tokens.append(.ident(text.lowercased()))
                continue
            }

            switch ch {
            // Currency symbols are units, so they become idents like any other unit name — `CalcUnits.money`
            // keys them by the glyph itself. They can't join the letter run above: `$` isn't a letter, and
            // `100usd` must still read as two tokens.
            case "$", "€", "£", "¥", "₹", "₩", "₪", "₺":
                tokens.append(.ident(String(ch)))
            case "+", "(", ")", "!", "%", "^":
                tokens.append(.op(ch))
            case "*", "×":
                tokens.append(.op("*"))
            case "/", "÷":
                tokens.append(.op("/"))
            case "−":
                tokens.append(.op("-"))
            case "-":
                if i + 1 < chars.count, chars[i + 1] == ">" {
                    tokens.append(.arrow)
                    i += 1
                } else {
                    tokens.append(.op("-"))
                }
            case "→":
                tokens.append(.arrow)
            case "=":
                // Tolerate a trailing "=" ("2+2="); anywhere else it's not calculator input.
                guard i == chars.count - 1 else { return nil }
            default:
                return nil
            }
            i += 1
        }
        return tokens
    }
}

/// A dimensional value: `si` is the magnitude in SI base units, `unit` how the user wrote it (and so how it renders back). Producing one is the whole point of `evaluateQuantity`.
struct CalcQuantityValue: Equatable, Sendable {
    let si: Double
    let unit: CompoundUnit

    /// The number to print in front of `unit.symbol`.
    var magnitude: Double { si / unit.siFactor }
}

/// Precedence-climbing evaluator over the token stream (evaluates while parsing, no AST), returning nil for anything malformed or non-finite.
enum CalcParser {
    /// What a unit-carrying expression evaluated to. `.mismatch` is reported instead of a silent nil so the card can name both sides ("Cannot add Length and Weight.").
    enum QuantityResult: Equatable {
        case value(CalcQuantityValue)
        case mismatch(CalcDimension, CalcDimension)
        case none
    }

    /// Scalar entry point: an expression that ends up carrying units is *not* a plain number, so it reads as nil here exactly like any other unparseable input. `rates` is still needed to *recognize* currencies — that's what lets the ones in `10 $ / 2 $` cancel to a plain 5.
    static func evaluate(_ tokens: [CalcToken], rates: CurrencyRates) -> Double? {
        var parser = Parser(tokens: tokens, rates: rates)
        guard let result = parser.parseExpression(minBP: 0), parser.isAtEnd, result.unit == nil,
            result.effective.isFinite
        else { return nil }
        return result.effective
    }

    /// Dimensional entry point: `1 km + 1 m`, `100 km / 2 h`, `60 mph * 2 hr`. Returns `.none` for a scalar or unparseable expression, leaving the caller's other paths to handle it.
    static func evaluateQuantity(_ tokens: [CalcToken], rates: CurrencyRates) -> QuantityResult {
        var parser = Parser(tokens: tokens, rates: rates)
        let result = parser.parseExpression(minBP: 0)
        if let (lhs, rhs) = parser.mismatch { return .mismatch(lhs, rhs) }
        guard let result, parser.isAtEnd, let unit = result.unit, result.value.isFinite else {
            return .none
        }
        return .value(CalcQuantityValue(si: result.value, unit: unit))
    }

    // Capture-free closures (not bare C function references) so every entry infers `@Sendable` under both language modes — the harness compiles this in Swift 5.
    fileprivate static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { sqrt($0) }, "log": { log10($0) }, "ln": { log($0) }, "sin": { sin($0) },
        "cos": { cos($0) }, "tan": { tan($0) }, "abs": { abs($0) }, "floor": { floor($0) },
        "ceil": { ceil($0) }, "round": { $0.rounded() },
    ]

    fileprivate static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]
}

private struct Parser {
    /// A value that may still be a "percent" (`20%`): additive ops treat it as a relative change, everything else as value/100. With a `unit`, `value` is the magnitude in SI base units — that's what makes `1 km + 1 m` a single addition.
    struct Value {
        var value: Double
        var unit: CompoundUnit? = nil
        var isPercent = false
        var effective: Double { isPercent ? value / 100 : value }
    }

    let tokens: [CalcToken]
    let rates: CurrencyRates
    var pos = 0
    /// Set when `+`/`-` (or a conversion) meets two different dimensions; the parse then fails, but the caller can still say what didn't line up.
    var mismatch: (CalcDimension, CalcDimension)?

    init(tokens: [CalcToken], rates: CurrencyRates) {
        self.tokens = tokens
        self.rates = rates
    }

    var isAtEnd: Bool { pos == tokens.count }
    private var current: CalcToken? { pos < tokens.count ? tokens[pos] : nil }

    // Binding powers: additive 10, multiplicative (incl. "of") 20, unary minus 25, power 30 (right-assoc), postfix ! % deg tightest.
    private static let additiveBP = 10
    private static let unaryBP = 25

    mutating func parseExpression(minBP: Int) -> Value? {
        guard var lhs = parseOperand() else { return nil }
        while true {
            if let (op, bp, rightBP) = peekBinary(), bp >= minBP {
                pos += 1
                guard let rhs = parseExpression(minBP: rightBP) else { return nil }
                guard let combined = apply(op, lhs, rhs) else { return nil }
                lhs = combined
                continue
            }
            // Two quantities of the same dimension written side by side add up: `5 ft 10 in`, `1 hr 30 min`.
            guard minBP <= Self.additiveBP, let combined = parseImplicitSum(lhs) else { break }
            lhs = combined
        }
        return lhs
    }

    /// Speculative: the parser is a value type, so a lookahead that doesn't pan out is discarded by simply not writing `self` back.
    private mutating func parseImplicitSum(_ lhs: Value) -> Value? {
        guard let unit = lhs.unit, !lhs.isPercent else { return nil }
        var lookahead = self
        guard let rhs = lookahead.parseOperand(), let rhsUnit = rhs.unit, !rhs.isPercent,
            rhsUnit.dimension == unit.dimension
        else { return nil }
        self = lookahead
        return Value(value: lhs.value + rhs.value, unit: unit)
    }

    /// (operator, its binding power, minimum bp for its right operand).
    private func peekBinary() -> (Character, Int, Int)? {
        switch current {
        case .op(let op) where op == "+" || op == "-": return (op, 10, 11)
        case .op(let op) where op == "*" || op == "/": return (op, 20, 21)
        case .ident("of"): return ("*", 20, 21)
        case .op("^"): return ("^", 30, 30)  // right-associative: 2^3^2 = 512
        default: return nil
        }
    }

    private mutating func apply(_ op: Character, _ lhs: Value, _ rhs: Value) -> Value? {
        switch op {
        // `450 + 20%` reads as a relative change: 450 * 1.2 — and `1 km + 10%` keeps the unit.
        case "+", "-":
            let sign: Double = op == "+" ? 1 : -1
            if rhs.isPercent {
                return Value(value: lhs.effective * (1 + sign * rhs.value / 100), unit: lhs.unit)
            }
            // Adding across units is the one place two different dimensions is an error worth naming.
            if let lhsUnit = lhs.unit, let rhsUnit = rhs.unit {
                guard lhsUnit.dimension == rhsUnit.dimension else {
                    mismatch = (lhsUnit.dimension, rhsUnit.dimension)
                    return nil
                }
                return Value(value: lhs.value + sign * rhs.value, unit: lhsUnit)
            }
            // A quantity and a bare number don't add up ("2 m + 3"); that's a half-typed expression, not
            // a dimension clash, so it fails quietly rather than as an error card.
            guard lhs.unit == nil, rhs.unit == nil else { return nil }
            return Value(value: lhs.effective + sign * rhs.effective)

        // Multiplying and dividing compose units: `km / h` is a speed even with no such table entry.
        case "*":
            return dimensional(lhs.effective * rhs.effective, lhs, rhs, dividing: false)
        case "/":
            return dimensional(lhs.effective / rhs.effective, lhs, rhs, dividing: true)

        // Only an integer power keeps a unit meaningful: `(2 m)^2` is 4 m², `2^0.5 m` is not.
        case "^":
            let result = pow(lhs.effective, rhs.effective)
            guard let lhsUnit = lhs.unit else {
                return rhs.unit == nil ? Value(value: result) : nil
            }
            guard rhs.unit == nil, rhs.effective.rounded() == rhs.effective,
                abs(rhs.effective) <= 3, let unit = lhsUnit.raised(to: Int(rhs.effective))
            else { return nil }
            return Value(value: result, unit: unit)

        default: return nil
        }
    }

    /// Combines the two operands' units, dropping to a plain number when everything cancels (`10 km / 2 km`).
    private func dimensional(_ value: Double, _ lhs: Value, _ rhs: Value, dividing: Bool) -> Value? {
        guard lhs.unit != nil || rhs.unit != nil else { return Value(value: value) }
        // A percent is a ratio, not a unit — it scales the other side and contributes nothing.
        let lhsUnit = lhs.isPercent ? nil : lhs.unit
        let rhsUnit = rhs.isPercent ? nil : rhs.unit
        return Value(value: value, unit: CompoundUnit.combine(lhsUnit, rhsUnit, dividing: dividing))
    }

    /// One prefix item plus all its postfixes (`!`, `%`, `deg`, a unit) — postfixes bind tightest.
    private mutating func parseOperand() -> Value? {
        guard var value = parsePrefix() else { return nil }
        loop: while true {
            switch current {
            case .op("!"):
                guard !value.isPercent, value.unit == nil, let fact = factorial(value.value) else {
                    return nil
                }
                value = Value(value: fact)
            case .op("%"):
                guard !value.isPercent, value.unit == nil else { return nil }
                value.isPercent = true
            // `deg` stays the trig postfix (`sin 30deg`) rather than the angle unit — that's what every
            // expression using it means, and `30 deg to rad` is handled by the conversion path.
            case .ident("deg"):
                guard !value.isPercent, value.unit == nil else { return nil }
                value = Value(value: value.value * .pi / 180)
            case .ident(let name):
                guard let unit = attachableUnit(name), !value.isPercent, value.unit == nil
                else { break loop }
                value = Value(value: value.value * unit.siFactor, unit: CompoundUnit(unit))
            default:
                break loop
            }
            pos += 1
        }
        return value
    }

    /// A unit a number can be written against. Temperatures are excluded because they're affine: `20°C + 5°C` has no meaning, while `20 K + 5 K` (a ratio scale, no offset) does.
    private func attachableUnit(_ name: String) -> UnitDef? {
        guard let unit = CalcUnits.unit(named: name, rates: rates), unit.offset == 0 else {
            return nil
        }
        return unit
    }

    private mutating func parsePrefix() -> Value? {
        switch current {
        case .number(let n):
            pos += 1
            return Value(value: n)
        case .intLiteral(let n, _):
            pos += 1
            return Value(value: Double(n))
        case .op("-"):
            pos += 1
            guard let operand = parseExpression(minBP: Self.unaryBP) else { return nil }
            return Value(value: -operand.effective, unit: operand.unit)
        case .op("+"):
            pos += 1
            return parseExpression(minBP: Self.unaryBP)
        case .op("("):
            pos += 1
            guard let inner = parseExpression(minBP: 0), case .op(")") = current else { return nil }
            pos += 1
            return inner
        case .ident(let name):
            if let constant = CalcParser.constants[name] {
                pos += 1
                return Value(value: constant)
            }
            if let fn = CalcParser.functions[name] {
                pos += 1
                let argument: Value?
                if case .op("(") = current {
                    pos += 1
                    argument = parseExpression(minBP: 0)
                    guard case .op(")") = current else { return nil }
                    pos += 1
                } else {
                    // Bare application: `sqrt 64`, `sin 30deg` — the argument is one operand, so `sqrt 64 + 36` is sqrt(64) + 36.
                    argument = parseOperand()
                }
                // A dimensional argument has no meaning here — `sqrt 4 m` isn't 2 of anything.
                guard let argument, argument.unit == nil else { return nil }
                return Value(value: fn(argument.effective))
            }
            // A unit with no number in front is one of it — the same default `parseConversion` applies
            // to `day to s`, and what makes the "h" in `km/h` parse.
            if let unit = attachableUnit(name) {
                pos += 1
                return Value(value: unit.siFactor, unit: CompoundUnit(unit))
            }
            return nil
        default:
            return nil
        }
    }

    /// Factorial for non-negative integers; 170! is the last value representable as a Double.
    private func factorial(_ v: Double) -> Double? {
        guard v >= 0, v.rounded() == v, v <= 170 else { return nil }
        var result = 1.0
        var n = 2.0
        while n <= v {
            result *= n
            n += 1
        }
        return result
    }
}
