import Foundation

/// The funnel every printable form of a link or outbound passes through (§5.2): the
/// link is the secret, and it never reaches a log, an error message, or a tool result
/// in raw form. The tests grep every output path for the synthetic link's secrets.
public enum Redactor {
    /// The one placeholder — a single ellipsis, never a length hint of the original.
    static let marker = "…"

    /// Query parameters in a share link whose *values* are credentials. `pbk` is the
    /// REALITY public key; `sid`/`spx`/`key`/`psk`/`pass`/`password` cover the rest.
    static let secretLinkKeys: Set<String> = ["pbk", "sid", "password", "pass", "key", "psk", "spx"]

    /// Query parameters shown in the clear — they describe the transport, not the caller.
    static let visibleLinkKeys: Set<String> = ["type", "security", "mode"]

    /// Object keys whose values are secrets anywhere in an Xray outbound or the
    /// generated config — the flat v26 outbound shape and the classic `vnext` one
    /// alike. `secretKey`/`preSharedKey`/`spiderX` cover WireGuard and REALITY's raw
    /// forms; `user`/`email` because an account name is identifying too.
    static let secretKeys: Set<String> = [
        "id", "password", "publicKey", "privateKey", "shortId",
        "pbk", "sid", "key", "psk", "token", "pass", "uuid",
        "secretKey", "preSharedKey", "spiderX", "email", "user",
    ]

    /// A share link with the credentials replaced: `vless://…@host:port?type=xhttp&
    /// security=reality&pbk=…&sid=…&mode=stream-one#Name`. Scheme, host:port, the
    /// `type`/`security`/`mode` parameters and the fragment survive; userinfo and secret
    /// parameters show as `…`; other parameters are dropped. An unparseable string is
    /// collapsed to the marker alone — safer to show nothing than something.
    public static func redact(link: String) -> String {
        guard let components = URLComponents(string: link),
            let scheme = components.scheme
        else { return marker }
        var result = "\(scheme)://\(marker)@"
        if let host = components.host {
            result += host
            if let port = components.port {
                result += ":\(port)"
            }
        }
        var query: [String] = []
        for item in components.queryItems ?? [] {
            if visibleLinkKeys.contains(item.name), let value = item.value {
                query.append("\(item.name)=\(value)")
            } else if secretLinkKeys.contains(item.name) {
                query.append("\(item.name)=\(marker)")
            }
        }
        if !query.isEmpty {
            result += "?\(query.joined(separator: "&"))"
        }
        if let fragment = components.fragment {
            // The label is free text — it can repeat the link's own credentials.
            result += "#\(scrub(fragment, secrets: secrets(inLink: link)))"
        }
        return result
    }

    /// Replaces the value under every `secretKeys` member with `…`, recursively —
    /// objects inside arrays included. Keys not in the set pass through untouched, so
    /// hosts, ports and protocols remain diagnosable.
    public static func redact(_ json: JSONValue) -> JSONValue {
        switch json {
        case .object(let object):
            .object(object.reduce(into: [:]) { result, pair in
                result[pair.key] = secretKeys.contains(pair.key) ? .string(marker) : redact(pair.value)
            })
        case .array(let array):
            .array(array.map(redact))
        case .string, .number, .bool, .null:
            json
        }
    }

    /// The string values under every `secretKeys` member anywhere in the JSON —
    /// the secrets a resolved outbound carries, for `scrub(_:secrets:)` on engine
    /// messages that can echo config text back.
    static func secrets(in json: JSONValue) -> [String] {
        switch json {
        case .object(let object):
            object.flatMap { key, value in
                if secretKeys.contains(key), case .string(let secret) = value, !secret.isEmpty {
                    return [secret]
                }
                return secrets(in: value)
            }
        case .array(let array):
            array.flatMap(secrets(in:))
        case .string, .number, .bool, .null:
            []
        }
    }

    /// A proxy URL's authority can carry `user:pass@` and its query can carry anything —
    /// rebuilt as `scheme://[…@]host[:port]`, credentials as `…`, and path/query/fragment
    /// dropped outright: a proxy exit is authority only.
    static func redact(proxy url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme
        else { return marker }
        var result = "\(scheme)://"
        if components.user != nil || components.password != nil {
            result += "\(marker)@"
        }
        if let host = components.host {
            result += host.contains(":") ? "[\(host)]" : host // bracket an IPv6 literal
        }
        if let port = components.port {
            result += ":\(port)"
        }
        return result
    }

    /// The secret values a link carries — the userinfo (a VLESS UUID, a trojan password)
    /// plus every `secretLinkKeys` value present, in BOTH decoded and percent-encoded
    /// form (`p@ss` and `p%40ss`): an engine error can echo either spelling, so the
    /// scrub list carries both, deduplicated.
    public static func secrets(inLink link: String) -> [String] {
        guard let components = URLComponents(string: link) else { return [] }
        var found: [String] = []
        for user in [components.user, components.percentEncodedUser].compactMap({ $0 })
        where !user.isEmpty {
            found.append(user)
        }
        for password in [components.password, components.percentEncodedPassword].compactMap({ $0 })
        where !password.isEmpty {
            found.append(password)
        }
        // `percentEncodedQueryItems` keeps the raw wire spelling — the key names carry
        // no escapes, so the secretLinkKeys match holds on both lists.
        for item in (components.queryItems ?? []) + (components.percentEncodedQueryItems ?? []) {
            if secretLinkKeys.contains(item.name), let value = item.value, !value.isEmpty {
                found.append(value)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Defensive second pass for free-form text that could embed a secret verbatim —
    /// engine error messages say what they say; the link is still not allowed through.
    static func scrub(_ text: String, secrets: some Sequence<String>) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: marker) }
    }

    /// The last line of defense, for text whose secrets cannot be enumerated — engine
    /// errors, decode failures, anything headed for output. Three patterns, each
    /// replaced by the marker:
    /// - `scheme://…` — a share link is a URL-like token;
    /// - a UUID — the VLESS/trojan userinfo shape;
    /// - a 32+ run of `[A-Za-z0-9_-]` — a base64url key (REALITY `pbk`, private keys).
    /// Breadth is deliberate: a false `…` costs one readable word, a miss costs an exit.
    /// A file path or a short hex id passes through untouched.
    public static func scrubPatterns(_ text: String) -> String {
        text
            .replacing(/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s"'<>]+/, with: { _ in marker })
            .replacing(
                /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/,
                with: { _ in marker })
            .replacing(/[A-Za-z0-9_-]{32,}/, with: { _ in marker })
    }

    /// `link …` / `xray <protocol> → <address>:<port>` / `proxy http://host:port` — the
    /// one-line shape `exits list` and `doctor` print for a stored exit. For an `xray`
    /// exit the protocol and endpoint are read *after* redaction, so nothing under a
    /// secret key can leak through the summary.
    public static func summary(of exit: Exit) -> String {
        switch exit {
        case .link(let link):
            return "link \(redact(link: link))"
        case .xray(let value):
            // `singleOutbound`: a hand-edited `{"outbounds":[<one>]}` wrapper still
            // summarizes by its inner protocol rather than as "invalid".
            let redacted = redact(value.singleOutbound)
            guard case .object(let object) = redacted,
                case .string(let proto)? = object["protocol"]
            else { return "xray (invalid: no protocol)" }
            if case .object(let settings)? = object["settings"],
                case .string(let address)? = settings["address"]
            {
                return "xray \(proto) → \(endpoint(address, port: settings["port"]))"
            }
            return "xray \(proto)"
        case .proxy(let url):
            return "proxy \(redact(proxy: url))"
        }
    }

    /// `address:port` for a port read from a `JSONValue` — `Int(exactly:)` plus the
    /// uint16 range, because the number is a `Double` and `Int(_:)` traps on values
    /// outside `Int`'s range or with a fraction; a hand-edited exit must crash nothing.
    static func endpoint(_ address: String, port: JSONValue?) -> String {
        guard case .number(let number) = port else { return address }
        guard let port = Int(exactly: number), (0...65535).contains(port) else {
            return "\(address):<invalid port>"
        }
        return "\(address):\(port)"
    }
}
