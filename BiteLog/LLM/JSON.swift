import Foundation

/// A JSON value: tool schemas, tool arguments, provider-specific request fields,
/// and a provider's own form of a reply (sent back unchanged).
nonisolated enum JSON: Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { o[key] } else { nil }
    }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
    var int: Int? { double.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
    var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// Keys sorted, so the same value always encodes to the same bytes (prompt
    /// caches match on exact bytes).
    func data(pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    func text(pretty: Bool = false) throws -> String {
        String(decoding: try data(pretty: pretty), as: UTF8.self)
    }

    /// This object with `other`'s keys added or replaced.
    func merging(_ other: JSON) -> JSON {
        guard case .object(var o) = self, case .object(let extra) = other else { return self }
        o.merge(extra) { _, new in new }
        return .object(o)
    }
}

nonisolated extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if let i = Int(exactly: n) { try c.encode(i) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

nonisolated extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
                            ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                            ExpressibleByNilLiteral {
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
}
