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
    /// generated config — the flat v26 outbound shape and the classic `vnext` one alike.
    static let secretKeys: Set<String> = [
        "id", "password", "publicKey", "privateKey", "shortId",
        "pbk", "sid", "key", "psk", "token", "pass", "uuid",
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
            result += "#\(fragment)"
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

    /// A proxy URL's authority can carry `user:pass@` — strip it the way the link
    /// redactor does. Path/query are dropped: a proxy exit is authority only.
    static func redact(proxy url: URL) -> String {
        let string = url.absoluteString
        guard let schemeEnd = string.range(of: "://") else { return string }
        let authorityStart = schemeEnd.upperBound
        let authorityEnd = string[authorityStart...].firstIndex(of: "/") ?? string.endIndex
        let authority = string[authorityStart..<authorityEnd]
        let host = authority.contains("@")
            ? "\(marker)@\(authority.split(separator: "@").last ?? "")"
            : String(authority)
        return "\(string[..<authorityStart])\(host)"
    }

    /// The secret values a link carries — the userinfo (a VLESS UUID, a trojan password)
    /// plus every `secretLinkKeys` value present — so an engine message that echoes the
    /// input can be scrubbed with `scrub(_:secrets:)`.
    public static func secrets(inLink link: String) -> [String] {
        guard let components = URLComponents(string: link) else { return [] }
        var found: [String] = []
        if let user = components.user, !user.isEmpty { found.append(user) }
        if let password = components.password, !password.isEmpty { found.append(password) }
        for item in components.queryItems ?? [] {
            if secretLinkKeys.contains(item.name), let value = item.value, !value.isEmpty {
                found.append(value)
            }
        }
        return found
    }

    /// Defensive second pass for free-form text that could embed a secret verbatim —
    /// engine error messages say what they say; the link is still not allowed through.
    static func scrub(_ text: String, secrets: some Sequence<String>) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: marker) }
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
            let redacted = redact(value)
            guard case .object(let object) = redacted,
                case .string(let proto)? = object["protocol"]
            else { return "xray (invalid: no protocol)" }
            if case .object(let settings)? = object["settings"],
                case .string(let address)? = settings["address"]
            {
                var endpoint = address
                if case .number(let port)? = settings["port"] {
                    endpoint += ":\(Int(port))"
                }
                return "xray \(proto) → \(endpoint)"
            }
            return "xray \(proto)"
        case .proxy(let url):
            return "proxy \(redact(proxy: url))"
        }
    }
}
