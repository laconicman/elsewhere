import Foundation

/// A JSON document as a typed Swift value: `xray` exits store raw outbound objects, and
/// `XrayConfigBuilder` composes converted outbounds without re-serialising text.
///
/// Numbers are `Double` — the only precision Xray's config accepts and the one
/// `JSONSerialization` round-trips without fidelity surprises (ports fit exactly).
public indirect enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // JSONDecoder is strict: each decode succeeds only for its own JSON type, so the
        // order below is by likelihood, not disambiguation — except that `null` must come
        // last (it is the absence of a value).
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object): try container.encode(object)
        case .array(let array): try container.encode(array)
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    /// A stored `xray` value may be the bare outbound or INCY's `{"outbounds":[<one>]}`
    /// export wrapper — the one place that unwraps, so `ExitResolver`, `summary` and
    /// `describe` agree (a hand-edited wrapper still lists correctly). Anything that is
    /// not exactly one wrapped object comes back unchanged; `ExitResolver` turns that
    /// case into `.exit`.
    var singleOutbound: JSONValue {
        guard case .array(let outbounds) = self["outbounds"], outbounds.count == 1,
            case .object = outbounds[0]
        else { return self }
        return outbounds[0]
    }
}

extension JSONValue {
    /// The `JSONSerialization`-compatible shape (`[String: Any]` / `[Any]` / `NSNumber`)
    /// — `XrayConfigBuilder` serializes through it with `.sortedKeys`, which renders a
    /// whole-number `Double` like 49152 as the integer `49152`, the form Xray's uint16
    /// fields require. A golden test pins that.
    public var anyValue: Any {
        switch self {
        case .object(let object): object.mapValues(\.anyValue)
        case .array(let array): array.map(\.anyValue)
        case .string(let string): string
        case .number(let number): number
        case .bool(let bool): bool
        case .null: NSNull()
        }
    }
}
