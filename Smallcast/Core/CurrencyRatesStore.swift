import Foundation

/// Keeps the calculator's money units priced. The rates are the ECB's daily reference rates, read
/// through frankfurter.dev (no key, no account, one ~600-byte response) and cached to disk so a launch
/// without a network still converts at yesterday's rates instead of not at all.
///
/// The snapshot is published, not read from the engine: `CalcEngine` takes it as a parameter, so this
/// store is the only thing that knows rates can change.
@MainActor
final class CurrencyRatesStore: ObservableObject {
    /// Starts as the snapshot compiled into the app (`CurrencyRates.bundled`), replaced by the cache on
    /// `start()` and by the day's rates once the fetch lands.
    @Published private(set) var rates: CurrencyRates = .bundled

    private static let endpoint = URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR")!
    /// Reference rates are published once a working day, so this is about surviving a long uptime — a
    /// menu-bar app is often left running for weeks — not about tracking the market.
    private static let refreshInterval: Duration = .seconds(6 * 3600)

    private let fileURL: URL
    private var refreshTask: Task<Void, Never>?

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.smallcast.app"
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("currency-rates.json")
    }

    func start() {
        guard refreshTask == nil else { return }
        if let cached = try? JSONDecoder().decode(CurrencyRates.self, from: Data(contentsOf: fileURL))
        {
            rates = cached
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// One attempt at the day's rates. Every failure — offline, a bad response, a currency list that
    /// won't decode — leaves `rates` exactly as it was, which is the whole point of shipping a fallback.
    func refresh() async {
        guard let fetched = await Self.fetch() else { return }
        guard fetched != rates else { return }
        rates = fetched
        try? JSONEncoder().encode(fetched).write(to: fileURL, options: .atomic)
    }

    /// `nonisolated` so neither the request nor the decode occupies the main actor.
    private nonisolated static func fetch() async -> CurrencyRates? {
        guard let (data, response) = try? await URLSession.shared.data(from: endpoint),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try? JSONDecoder().decode(Response.self, from: data),
            !payload.rates.isEmpty
        else { return nil }
        return CurrencyRates(date: payload.date, perEUR: payload.rates)
    }

    private struct Response: Decodable {
        let date: String
        let rates: [String: Double]
    }
}
