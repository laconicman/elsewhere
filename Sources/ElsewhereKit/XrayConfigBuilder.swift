import Foundation

/// Assembles the Xray config passed to `XrayCore.run` (§5.3): one loopback `mixed`
/// inbound per exit plus one for `direct`, the outbounds, and tag-to-tag field routing.
/// Pure — ports and converted outbounds arrive as arguments so goldens need no engine.
///
/// Normalisation per outbound: `tag` set to `out:<name>`, `sendThrough` deleted (the
/// share-link fragment quirk), `protocol` required — deliberately no allowlist beyond
/// presence: the engine's own `test` validates protocols with its own message (C5).
public enum XrayConfigBuilder {
    /// One inbound→outbound pair: how `fetch --exit NAME` finds its proxy port.
    public struct Lane: Sendable, Equatable {
        public let exitName: String
        public let inboundPort: UInt16
        public let inboundTag: String
        public let outboundTag: String

        public init(exitName: String, inboundPort: UInt16, inboundTag: String, outboundTag: String) {
            self.exitName = exitName
            self.inboundPort = inboundPort
            self.inboundTag = inboundTag
            self.outboundTag = outboundTag
        }
    }

    /// The generated config's `log` block. Xray's console logger writes to **stdout**
    /// (`app/log/log_creator.go` at v26.10.21 → `CreateStdoutLogWriter`), and this tool's
    /// stdout is the payload (CLI) or the protocol (MCP) — so the default is silence.
    /// The banner can only be silenced by `loglevel: "none"` or a file redirect (C5 §7,
    /// swift-libxray TD-6); there is no "errors to stderr" option to preserve.
    public enum XrayLog: Sendable, Equatable {
        /// `"log":{"access":"none","loglevel":"none"}` — nothing on stdout, ever.
        case silent
        /// `"log":{"access":"none","error":"<path>","loglevel":"warning"}` — to a file.
        case file(String)
    }

    /// - Parameters:
    ///   - exits: `(config name, converted outbound)` pairs — `proxy` exits never reach
    ///     here; URLSession talks to them directly (§5.5).
    ///   - ports: inbound port per exit name, from `XrayCore.freePorts` (candidates, not
    ///     reservations — TD-2).
    ///   - directPort: the `direct` lane's inbound port — `nil` emits no `direct`
    ///     inbound/outbound/rule/lane at all (A9: only the lanes a call needs are
    ///     built; `Doctor`/`ExitValidator` still validate the full shape).
    ///   - bindInterface: the resolved interface name (`nil` = `BindInterface.none` —
    ///     `--via-system`), applied to every outbound including `direct` (§3.3).
    ///   - log: the `log` block — ``XrayLog/silent`` by default, since the engine's
    ///     console log writes to this process's stdout.
    /// - Returns: the JSON text (`.sortedKeys`, so goldens compare as text) and lanes.
    public static func build(
        exits: [(name: String, outbound: JSONValue)],
        ports: [String: UInt16],
        directPort: UInt16?,
        bindInterface: String?,
        log: XrayLog = .silent
    ) throws(ElsewhereError) -> (configJSON: String, lanes: [Lane]) {
        var inbounds: [JSONValue] = []
        var outbounds: [JSONValue] = []
        var rules: [JSONValue] = []
        var lanes: [Lane] = []

        for (name, outbound) in exits {
            guard let port = ports[name] else {
                throw .exit("no inbound port allocated for exit '\(name)'")
            }
            inbounds.append(inbound(tag: "in:\(name)", port: port))
            outbounds.append(try normalize(outbound, tag: "out:\(name)", interface: bindInterface))
            rules.append(rule(inbound: "in:\(name)", outbound: "out:\(name)"))
            lanes.append(Lane(
                exitName: name, inboundPort: port,
                inboundTag: "in:\(name)", outboundTag: "out:\(name)"))
        }

        // `direct` exists when the caller asks for it (`nil` = not this call, A9) —
        // and binds the interface too, so `--direct` is genuinely direct (§3.3).
        if let directPort {
            inbounds.append(inbound(tag: "in:direct", port: directPort))
            outbounds.append(try normalize(
                .object(["protocol": .string("freedom")]),
                tag: "out:direct", interface: bindInterface))
            rules.append(rule(inbound: "in:direct", outbound: "out:direct"))
            lanes.append(Lane(
                exitName: "direct", inboundPort: directPort,
                inboundTag: "in:direct", outboundTag: "out:direct"))
        }

        let root = JSONValue.object([
            "log": logBlock(log),
            "inbounds": .array(inbounds),
            "outbounds": .array(outbounds),
            // AsIs by inbound tag (§3.4): no `dns` block, destinations travel by hostname.
            "routing": .object([
                "domainStrategy": .string("AsIs"),
                "rules": .array(rules),
            ]),
        ])

        do {
            let data = try JSONSerialization.data(
                withJSONObject: root.anyValue, options: [.sortedKeys])
            return (String(decoding: data, as: UTF8.self), lanes)
        } catch {
            throw .config("cannot serialize generated Xray config: \(error.localizedDescription)")
        }
    }

    static func logBlock(_ log: XrayLog) -> JSONValue {
        switch log {
        case .silent:
            .object(["access": .string("none"), "loglevel": .string("none")])
        case .file(let path):
            .object([
                "access": .string("none"), "error": .string(path), "loglevel": .string("warning"),
            ])
        }
    }

    /// The `mixed` inbound speaks HTTP CONNECT and SOCKS on one loopback port (§3.2);
    /// `udp: false` — the tunnel carries TCP only (§5.9).
    static func inbound(tag: String, port: UInt16) -> JSONValue {
        .object([
            "tag": .string(tag),
            "listen": .string("127.0.0.1"),
            "port": .number(Double(port)),
            "protocol": .string("mixed"),
            "settings": .object(["udp": .bool(false)]),
        ])
    }

    static func rule(inbound: String, outbound: String) -> JSONValue {
        .object([
            "type": .string("field"),
            "inboundTag": .array([.string(inbound)]),
            "outboundTag": .string(outbound),
        ])
    }

    /// Tag, strip `sendThrough`, require `protocol`, merge `sockopt.interface` into any
    /// existing `streamSettings` rather than replacing them (§5.3).
    static func normalize(_ outbound: JSONValue, tag: String, interface: String?) throws(ElsewhereError)
        -> JSONValue
    {
        guard case .object(var object) = outbound else {
            throw .exit("outbound for '\(tag)' must be a JSON object")
        }
        guard case .string = object["protocol"] else {
            throw .exit("outbound for '\(tag)' has no 'protocol'")
        }
        object["tag"] = .string(tag)
        object.removeValue(forKey: "sendThrough")
        if let interface {
            var stream = object["streamSettings"]?.objectValue ?? [:]
            var sockopt = stream["sockopt"]?.objectValue ?? [:]
            sockopt["interface"] = .string(interface)
            stream["sockopt"] = .object(sockopt)
            object["streamSettings"] = .object(stream)
        }
        return .object(object)
    }
}

extension JSONValue {
    /// Convenience for the builder's merges — nil unless the value is an object.
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    /// Keyed lookup — nil unless the value is an object and the key is present.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
