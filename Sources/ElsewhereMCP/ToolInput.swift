import ElsewhereKit
import Foundation
import MCP

/// A tool call's arguments, decoded into the tool's own `Decodable` input —
/// devin-kick's `ToolInput`, adapted to this Kit's error.
enum ToolInput {
    /// `arguments` as `Input`, checked against the tool's `schema` first. Every
    /// failure is a usage error naming the field, so the model can correct the call.
    ///
    /// Two checks go beyond decoding:
    /// - A name the schema doesn't list is refused. Decoding ignores it, and a
    ///   guessed name would silently do the wrong fetch.
    /// - A text that reads as a `data:` URL is refused. swift-sdk 0.12.1 decodes
    ///   such a string into bytes (`Value.data`) and re-encodes it as base64,
    ///   so `url` would reach the fetcher rewritten (`Value.init(from:)`,
    ///   verified in its source).
    static func decode<Input: Decodable>(
        _ type: Input.Type, from arguments: [String: Value], schema: Value
    ) throws(ElsewhereError) -> Input {
        try check(.object(arguments), against: schema, at: "")
        let data: Data
        do {
            data = try JSONEncoder().encode(arguments)
        } catch {
            throw .usage("The arguments could not be read (\(error.localizedDescription)).")
        }
        do {
            return try JSONDecoder().decode(Input.self, from: data)
        } catch let error as DecodingError {
            throw .usage("Invalid arguments: \(ConfigStore.describe(error)).")
        } catch {
            throw .usage("Invalid arguments (\(error.localizedDescription)).")
        }
    }

    /// Walks `value` beside its `schema`, through object properties and array items.
    static func check(
        _ value: Value, against schema: Value?, at path: String
    ) throws(ElsewhereError) {
        switch value {
        case .data:
            // TODO(TD-9): goes once the SDK keeps such a string a string (swift-sdk#277).
            throw .usage("\(path) reads as a data: URL, which this server's MCP library turns into bytes, so it can't pass the text on as written.")
        case .object(let fields):
            guard let properties = schema?.objectValue?["properties"]?.objectValue else { return }
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                let fieldPath = path.isEmpty ? name : "\(path).\(name)"
                guard let fieldSchema = properties[name] else {
                    throw .usage("Unknown argument \(fieldPath). Arguments here: \(properties.keys.sorted().joined(separator: ", ")).")
                }
                try check(field, against: fieldSchema, at: fieldPath)
            }
        case .array(let items):
            let itemSchema = schema?.objectValue?["items"]
            for (index, item) in items.enumerated() {
                try check(item, against: itemSchema, at: "\(path)[\(index)]")
            }
        case .null, .bool, .int, .double, .string:
            return
        }
    }
}

/// JSON Schema for tool inputs, as the SDK's `Value` — the parts the three tools
/// need of devin-kick's `InputSchema`.
enum InputSchema {
    /// An object of `properties`, of which `required` must be given; no other names.
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String, minimum: Int, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "minimum": .int(minimum), "description": .string(description)]
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }
}
