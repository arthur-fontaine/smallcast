import Foundation

/// Exponents over the fundamental dimensions the calculator models. Everything in `CalcUnits` maps onto
/// these, so arithmetic can combine units that have no table entry of their own: `km / h` is
/// length¹·time⁻¹ whether or not a "km/h" unit exists. Named `CalcDimension`, not `Dimension`, because
/// Foundation's Measurement API already owns that name.
struct CalcDimension: Equatable, Sendable {
    var length = 0
    var mass = 0
    var time = 0
    var information = 0
    var angle = 0
    var temperature = 0

    static let scalar = CalcDimension()

    var isScalar: Bool { self == .scalar }

    static func + (lhs: CalcDimension, rhs: CalcDimension) -> CalcDimension {
        CalcDimension(
            length: lhs.length + rhs.length, mass: lhs.mass + rhs.mass, time: lhs.time + rhs.time,
            information: lhs.information + rhs.information, angle: lhs.angle + rhs.angle,
            temperature: lhs.temperature + rhs.temperature)
    }

    func scaled(by power: Int) -> CalcDimension {
        CalcDimension(
            length: length * power, mass: mass * power, time: time * power,
            information: information * power, angle: angle * power,
            temperature: temperature * power)
    }

    /// Human-facing name for error messages: a category name when one matches exactly ("Speed"), else
    /// the fundamentals composed ("Length/Time²").
    var displayName: String {
        if isScalar { return "Number" }
        for category in UnitCategory.allCases where category.dimension == self {
            return category.displayName
        }
        return UnitFormatting.compose(
            terms: [
                (name: "Length", exponent: length), (name: "Mass", exponent: mass),
                (name: "Time", exponent: time), (name: "Data", exponent: information),
                (name: "Angle", exponent: angle), (name: "Temperature", exponent: temperature),
            ], separator: "·")
    }
}

extension UnitCategory {
    /// What a unit in this category measures.
    var dimension: CalcDimension {
        switch self {
        case .length: return CalcDimension(length: 1)
        case .weight: return CalcDimension(mass: 1)
        case .temperature: return CalcDimension(temperature: 1)
        case .time: return CalcDimension(time: 1)
        case .area: return CalcDimension(length: 2)
        case .volume: return CalcDimension(length: 3)
        case .digitalStorage: return CalcDimension(information: 1)
        case .angle: return CalcDimension(angle: 1)
        case .speed: return CalcDimension(length: 1, time: -1)
        case .pressure: return CalcDimension(length: -1, mass: 1, time: -2)
        case .dataRate: return CalcDimension(time: -1, information: 1)
        }
    }

    /// Multiplier from the category's own base unit to the SI base for its dimension — only the two
    /// categories whose base isn't already SI need one (liters → m³, bytes → bits).
    var siScale: Double {
        switch self {
        case .volume: return 0.001
        case .digitalStorage: return 8
        default: return 1
        }
    }
}

extension UnitDef {
    /// This unit's size in SI base units (m, kg, s, bit, rad, K).
    var siFactor: Double { factor * category.siScale }
    var dimension: CalcDimension { category.dimension }
}

/// A unit as written by the user: an ordered product of powers of table units (`km`, `km/h`, `m·s`).
/// It carries both what to *display* and the SI factor needed to get back to a magnitude.
struct CompoundUnit: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        let unit: UnitDef
        var exponent: Int
    }

    private(set) var terms: [Term]

    init(_ unit: UnitDef) {
        terms = [Term(unit: unit, exponent: 1)]
    }

    private init(terms: [Term]) {
        self.terms = terms
    }

    var dimension: CalcDimension {
        terms.reduce(.scalar) { $0 + $1.unit.dimension.scaled(by: $1.exponent) }
    }

    /// Size of one of this unit in SI base units — the divisor turning an SI magnitude into what the
    /// card displays.
    var siFactor: Double {
        terms.reduce(1.0) { $0 * pow($1.unit.siFactor, Double($1.exponent)) }
    }

    /// Raising to a power: `(km)²`. Zero collapses to a plain number.
    func raised(to power: Int) -> CompoundUnit? {
        guard power != 0 else { return nil }
        return CompoundUnit(terms: terms.map { Term(unit: $0.unit, exponent: $0.exponent * power) })
    }

    /// Terms are merged by symbol and kept in the order they were written, so `km / h` displays as
    /// "km/h" rather than in some canonical order. A term whose exponent cancels out is dropped, which
    /// is how `km / km` becomes a plain number.
    static func combine(_ lhs: CompoundUnit?, _ rhs: CompoundUnit?, dividing: Bool) -> CompoundUnit? {
        var terms = lhs?.terms ?? []
        for term in rhs?.terms ?? [] {
            let exponent = dividing ? -term.exponent : term.exponent
            if let index = terms.firstIndex(where: { $0.unit.symbol == term.unit.symbol }) {
                terms[index].exponent += exponent
            } else {
                terms.append(Term(unit: term.unit, exponent: exponent))
            }
        }
        terms.removeAll { $0.exponent == 0 }
        return terms.isEmpty ? nil : CompoundUnit(terms: terms)
    }

    /// The table unit this compound is equivalent to (`km·h⁻¹` → `km/h`, `m·m` → `m²`), or nil when
    /// nothing in the table matches and the composed form has to be rendered instead.
    var namedEquivalent: UnitDef? {
        let dimension = self.dimension
        let factor = siFactor
        guard factor.isFinite, factor > 0 else { return nil }
        return CalcUnits.ordered.first {
            $0.offset == 0 && $0.dimension == dimension
                && abs($0.siFactor - factor) <= abs(factor) * 1e-9
        }
    }

    /// The single table unit this is, when nothing has been combined — `°C` has no `namedEquivalent`
    /// (affine units are excluded from that search) but must still render as itself.
    var singleUnit: UnitDef? {
        terms.count == 1 && terms[0].exponent == 1 ? terms[0].unit : nil
    }

    /// "km/h", "m²", "kg/(m·s²)" — the named table unit when there is one, else the composed form.
    var symbol: String {
        if let unit = singleUnit ?? namedEquivalent { return unit.symbol }
        return UnitFormatting.compose(
            terms: terms.map { (name: $0.unit.symbol, exponent: $0.exponent) }, separator: "·")
    }

    /// Long label for the card badge; falls back to the symbol when the combination has no name.
    var name: String {
        (singleUnit ?? namedEquivalent)?.name ?? symbol
    }
}

/// Shared renderer for "a·b/c²"-style strings, used for both unit symbols and dimension names.
enum UnitFormatting {
    static func compose(terms: [(name: String, exponent: Int)], separator: String) -> String {
        let numerator = terms.filter { $0.exponent > 0 }
        let denominator = terms.filter { $0.exponent < 0 }
        let top =
            numerator.isEmpty
            ? "1"
            : numerator.map { power($0.name, $0.exponent) }.joined(separator: separator)
        guard !denominator.isEmpty else { return top }
        let bottom = denominator.map { power($0.name, -$0.exponent) }.joined(separator: separator)
        return denominator.count > 1 ? "\(top)/(\(bottom))" : "\(top)/\(bottom)"
    }

    private static func power(_ name: String, _ exponent: Int) -> String {
        switch exponent {
        case 1: return name
        case 2: return name + "²"
        case 3: return name + "³"
        default: return name + "^\(exponent)"
        }
    }
}
