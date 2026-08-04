import Foundation

/// A set of exchange rates quoted the way the ECB publishes them: units of each currency per 1 EUR.
///
/// The snapshot is *injected* into `CalcEngine.evaluate` rather than read from a global, for the same
/// reason `now` / `calendar` are: it keeps the engine a pure function of its input, and it lets
/// `Tools/calc-test.swift` assert exact currency answers against pinned rates.
struct CurrencyRates: Equatable, Sendable, Codable {
    /// The ECB publication day the rates are from ("2026-08-04") — shown nowhere yet, but it's what
    /// tells a cached snapshot's age from the snapshot itself.
    let date: String
    private let perEUR: [String: Double]

    init(date: String, perEUR: [String: Double]) {
        self.date = date
        self.perEUR = perEUR
    }

    /// What one unit of `code` is worth in EUR — the factor that puts a currency on the money
    /// dimension's base. Nil for a currency this snapshot doesn't quote, which keeps that currency out
    /// of the unit table entirely rather than converting it at a made-up rate.
    func eurPerUnit(_ code: String) -> Double? {
        if code == "EUR" { return 1 }
        guard let rate = perEUR[code], rate > 0, rate.isFinite else { return nil }
        return 1 / rate
    }

    /// Shipped with the app so the very first launch — and any launch offline — still converts.
    /// ECB reference rates; `CurrencyRatesStore` replaces this with a fresh set moments after start.
    static let bundled = CurrencyRates(
        date: "2026-08-04",
        perEUR: [
            "AUD": 1.6377, "BGN": 1.9558, "BRL": 5.8503, "CAD": 1.6191, "CHF": 0.9319,
            "CNY": 7.7767, "CZK": 24.2, "DKK": 7.4754, "GBP": 0.85639, "HKD": 9.0316,
            "HUF": 362.3, "IDR": 20712.15, "ILS": 3.485, "INR": 109.8285, "ISK": 142.0,
            "JPY": 181.26, "KRW": 1643.32, "MXN": 19.9072, "MYR": 4.7125, "NOK": 10.9925,
            "NZD": 1.9568, "PHP": 70.243, "PLN": 4.3063, "RON": 5.251, "SEK": 10.9925,
            "SGD": 1.4767, "THB": 38.385, "TRY": 54.7606, "USD": 1.1515, "ZAR": 18.9316,
        ])
}

extension CalcUnits {
    /// The currencies the calculator knows, keyed by the tokenizer's ident form. Kept apart from the
    /// main `catalog` because a currency has no fixed size: the `UnitDef` handed out by
    /// `unit(named:rates:)` is stamped with a factor from the live snapshot, so these entries carry
    /// only the ISO code and how to render it.
    ///
    /// Every currency the ECB quotes gets its code as both an alias and its display symbol; the five
    /// with a symbol nobody has to decode get that instead. `¥` reads as yen and `$` as US dollars —
    /// the other claimants to those glyphs are reachable by code (`cny`, `cad`, `aud`).
    static let money: [String: UnitDef] = {
        var table: [String: UnitDef] = [:]
        func add(_ code: String, _ symbol: String, _ name: String, _ aliases: [String] = []) {
            let def = UnitDef(symbol, name, .money, 1, currency: code)
            table[code.lowercased()] = def
            for alias in aliases { table[alias] = def }
        }

        add("USD", "$", "US Dollars", ["$", "dollar", "dollars"])
        add("EUR", "€", "Euros", ["€", "euro", "euros"])
        add("GBP", "£", "British Pounds", ["£", "sterling"])
        add("JPY", "¥", "Japanese Yen", ["¥", "yen"])
        add("INR", "₹", "Indian Rupees", ["₹", "rupee", "rupees"])
        add("CHF", "CHF", "Swiss Francs", ["franc", "francs"])
        add("CAD", "CAD", "Canadian Dollars")
        add("AUD", "AUD", "Australian Dollars")
        add("NZD", "NZD", "New Zealand Dollars")
        add("CNY", "CNY", "Chinese Yuan", ["yuan", "rmb"])
        add("SEK", "SEK", "Swedish Kronor")
        add("NOK", "NOK", "Norwegian Kroner")
        add("DKK", "DKK", "Danish Kroner")
        add("PLN", "PLN", "Polish Zloty", ["zloty"])
        add("CZK", "CZK", "Czech Koruny")
        add("HUF", "HUF", "Hungarian Forint")
        add("RON", "RON", "Romanian Leu")
        add("BGN", "BGN", "Bulgarian Lev")
        add("TRY", "TRY", "Turkish Lira", ["₺"])
        add("ILS", "ILS", "Israeli Shekels", ["₪", "shekel", "shekels"])
        add("KRW", "KRW", "South Korean Won", ["₩", "won"])
        add("SGD", "SGD", "Singapore Dollars")
        add("HKD", "HKD", "Hong Kong Dollars")
        add("MXN", "MXN", "Mexican Pesos", ["peso", "pesos"])
        add("BRL", "BRL", "Brazilian Reais")
        add("ZAR", "ZAR", "South African Rand", ["rand"])
        add("ISK", "ISK", "Icelandic Krónur")
        add("PHP", "PHP", "Philippine Pesos")
        add("IDR", "IDR", "Indonesian Rupiah")
        add("MYR", "MYR", "Malaysian Ringgit", ["ringgit"])
        add("THB", "THB", "Thai Baht", ["baht"])
        return table
    }()

    /// The glyph aliases — the only currency names that may be written *in front* of their amount.
    static let moneySymbols: Set<String> = ["$", "€", "£", "¥", "₹", "₩", "₪", "₺"]

    /// `$5` reads as `5 $`. Writing the symbol in front of the amount is the English convention, and
    /// swapping it here — once, before any parse path runs — is what lets every one of them see the
    /// single shape it knows (`0.22 $ / h`).
    ///
    /// Only glyphs move. A code or a word in front of a number is nobody's convention, and treating
    /// `php 8` as eight pesos would turn a search for the language into a currency card.
    static func normalizingCurrencyPrefixes(_ tokens: [CalcToken]) -> [CalcToken] {
        var tokens = tokens
        var index = 0
        while index + 1 < tokens.count {
            guard case .ident(let name) = tokens[index], moneySymbols.contains(name),
                case .number = tokens[index + 1]
            else {
                index += 1
                continue
            }
            tokens.swapAt(index, index + 1)
            index += 2
        }
        return tokens
    }
}
