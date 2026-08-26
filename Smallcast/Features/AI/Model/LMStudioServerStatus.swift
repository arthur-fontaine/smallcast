import Foundation

/// What `lms server status --json` reports. The port is the configured one whether or not the
/// server is up, which is what makes it worth asking for: LM Studio's is often not 1234.
struct LMStudioServerStatus: Equatable, Sendable {
    let running: Bool
    let port: Int

    var baseURL: String { "http://localhost:\(port)/v1" }

    /// Nil for anything that isn't a usable answer, so an `lms` too old for `--json` — or one that
    /// printed prose — falls through to the static default rather than seeding a broken address.
    static func decode(_ data: Data) -> Self? {
        struct Payload: Decodable {
            let running: Bool?
            let port: Int
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            (1...65535).contains(payload.port)
        else { return nil }
        return Self(running: payload.running ?? false, port: payload.port)
    }
}
