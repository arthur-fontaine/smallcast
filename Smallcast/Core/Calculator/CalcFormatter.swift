import Foundation

/// Hand-rolled, locale-independent number formatting (`.` decimal, `,` grouping), deterministic so the test harness can assert exact strings and the palette renders identically across locales.
enum CalcFormatter {
    /// Human-facing: ≤10 significant digits, trailing zeros trimmed, thousands separators.
    static func display(_ value: Double) -> String {
        grouped(copyText(value))
    }

    /// Same rounding, no grouping — what lands on the pasteboard.
    static func copyText(_ value: Double) -> String {
        let v = value == 0 ? 0 : value  // normalize -0
        // Integers print in full (not exponent form) while they're exactly representable.
        if v.rounded() == v && abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.10g", v)
    }

    /// Money quoted to the cent. Ten significant digits of a currency amount is noise, and so are the
    /// trailing zeros a fixed two-decimal format would add, so this rounds and then trims like every
    /// other value ("86.5 €", not "86.49610678 €" or "86.50 €"). Sub-cent amounts — a per-second wage,
    /// a weak currency's smallest unit — keep full precision rather than collapsing to zero.
    static func moneyDisplay(_ value: Double) -> String {
        grouped(moneyCopyText(value))
    }

    static func moneyCopyText(_ value: Double) -> String {
        guard value == 0 || abs(value) >= 0.005 else { return copyText(value) }
        return copyText((value * 100).rounded() / 100)
    }

    /// A length in feet rendered as whole feet + remaining inches ("3 feet 3.370078740 inches"); used only for the bare metric-length auto-conversion. Sub-foot values drop the feet part.
    static func compoundFeetInches(_ feet: Double) -> String {
        let sign = feet < 0 ? "-" : ""
        let magnitude = abs(feet)
        let wholeFeet = magnitude.rounded(.towardZero)
        let inches = (magnitude - wholeFeet) * 12
        let feetPart = wholeFeet == 0 ? "" : "\(sign)\(display(wholeFeet)) \(wholeFeet == 1 ? "foot" : "feet")"
        let inchText = display(inches)
        let inchPart = "\(inchText) \(inchText == "1" ? "inch" : "inches")"
        if feetPart.isEmpty { return "\(sign)\(inchPart)" }
        return "\(feetPart) \(inchPart)"
    }

    /// Insert `,` every three integer digits. Exponent-form strings pass through untouched.
    static func grouped(_ text: String) -> String {
        guard !text.contains("e"), !text.contains("E") else { return text }
        let sign = text.hasPrefix("-") ? "-" : ""
        let unsigned = sign.isEmpty ? text : String(text.dropFirst())
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intDigits = Array(parts[0])
        guard intDigits.count > 3 else { return text }

        var groupedInt = ""
        for (i, digit) in intDigits.enumerated() {
            if i > 0 && (intDigits.count - i) % 3 == 0 { groupedInt.append(",") }
            groupedInt.append(digit)
        }
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        return sign + groupedInt + fraction
    }
}
