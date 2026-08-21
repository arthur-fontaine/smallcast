import Foundation

/// The block structure of a reply. Pure and separate from the view because a streamed answer is
/// re-split on every chunk, and because getting fences right is the part worth pinning in a harness.
enum AIMarkdownBlock: Equatable, Identifiable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, text: String)
    case quote(String)
    /// `language` is whatever followed the opening fence; empty when it named none.
    case code(language: String, text: String)
    case rule

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text): return "p:\(text)"
        case .bullet(let text): return "b:\(text)"
        case .numbered(let index, let text): return "n\(index):\(text)"
        case .quote(let text): return "q:\(text)"
        case .code(let language, let text): return "c:\(language):\(text)"
        case .rule: return "rule"
        }
    }

    private static let fence = "```"

    /// An unterminated fence is normal mid-stream, so it closes at the end of what has arrived.
    static func parse(_ source: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var paragraph: [String] = []
        var fenced: [String]?
        var language = ""
        var numbered = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        for rawLine in lines {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(fence) {
                if let body = fenced {
                    blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                    fenced = nil
                    language = ""
                } else {
                    flush()
                    fenced = []
                    language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if fenced != nil {
                fenced?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
                numbered = 0
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 4), text: text))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            if let text = Self.numberedItem(trimmed) {
                flush()
                numbered += 1
                blocks.append(.numbered(index: numbered, text: text))
                continue
            }
            paragraph.append(trimmed)
        }
        if let body = fenced {
            blocks.append(.code(language: language, text: body.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    /// `1. text` or `1) text` → `text`.
    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
