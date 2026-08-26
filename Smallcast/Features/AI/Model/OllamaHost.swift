import Foundation

/// An `OLLAMA_HOST` value resolved into an address a client can actually connect to. Ollama accepts
/// a bare port, a host, a `host:port`, or any of those with a scheme, and documents `0.0.0.0` as the
/// way to serve the network — which is a bind address, never somewhere to send a request.
struct OllamaHost: Equatable, Sendable {
    static let defaultPort = 11434

    let host: String
    let port: Int
    let secure: Bool

    /// An IPv6 literal is only a URL host inside brackets.
    var baseURL: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return "\(secure ? "https" : "http")://\(name):\(port)/v1"
    }

    /// Nil for a value that names no usable address, so the static default stands rather than a
    /// seeded address that cannot answer.
    static func parse(_ value: String) -> Self? {
        var rest = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        var secure = false
        if let separator = rest.range(of: "://") {
            let scheme = rest[rest.startIndex..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            secure = scheme == "https"
            rest = String(rest[separator.upperBound...])
        }
        // A path is a bind address's business, not a client's; `/v1` is appended by `baseURL`.
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[rest.startIndex..<slash]) }
        guard !rest.isEmpty else { return nil }
        // A bare number is a port, which is the shorthand the docs use for changing only that.
        if let port = Int(rest) { return resolved(host: "", port: port, secure: secure) }
        let (host, portText) = split(rest)
        guard let portText else { return resolved(host: host, port: defaultPort, secure: secure) }
        guard let port = Int(portText) else { return nil }
        return resolved(host: host, port: port, secure: secure)
    }

    /// IPv6 arrives bracketed, so the last colon only separates a port outside those brackets.
    private static func split(_ value: String) -> (host: String, port: String?) {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return (value, nil) }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let after = value[value.index(after: close)...]
            guard after.hasPrefix(":") else { return (host, nil) }
            return (host, String(after.dropFirst()))
        }
        // More than one colon and no brackets is a bare IPv6 literal: all of it is the host.
        guard value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":") else {
            return (value, nil)
        }
        return (String(value[value.startIndex..<colon]), String(value[value.index(after: colon)...]))
    }

    /// A wildcard bind means every interface, so the address to ask is the local one.
    private static func resolved(host: String, port: Int, secure: Bool) -> Self? {
        guard (1...65535).contains(port) else { return nil }
        let wildcards: Set<String> = ["", "0.0.0.0", "::", "*", "[::]"]
        let name = wildcards.contains(host) ? "localhost" : host
        return Self(host: name, port: port, secure: secure)
    }
}
