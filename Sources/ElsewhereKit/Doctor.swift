import Foundation
import XrayCore // internal — the engine stays behind this module's own types (§5.1)

/// `elsewhere doctor`: a fixed battery of checks over the engine, the config, each exit
/// and the generated Xray config — the §5.7 line "config present+0600, each link
/// converts, config passes testXray, interface chosen, ports free, Xray version, INCY
/// detected on 10808, redacted", in that order.
///
/// Nothing thrown escapes: a broken thing is a check, not an exit status. And no detail
/// ever carries a secret — every engine message is scrubbed with the secrets collected
/// from the links and their converted outbounds.
public enum Doctor {
    public enum Verdict: String, Sendable, Equatable {
        case ok, info, warning, failure
    }

    public struct Check: Sendable, Equatable {
        public let name: String
        public let verdict: Verdict
        public let detail: String

        public init(name: String, verdict: Verdict, detail: String) {
            self.name = name
            self.verdict = verdict
            self.detail = detail
        }
    }

    /// The checks, in display order. `localProxyPort` is where a system proxy would
    /// listen (INCY uses 10808); it is also excluded from the candidate inbound ports.
    public static func run(
        store: ConfigStore,
        environment: [String: String],
        localProxyPort: UInt16 = 10808
    ) async -> [Check] {
        var checks: [Check] = []

        // Secrets to scrub, populated once the config is read: every link's credentials
        // plus the raw link, and every secret field inside each resolved outbound — the
        // engine can echo either in an error. `scrubbed` adds the pattern pass, so even
        // a failure before the config is loaded (the engine check itself) can't print
        // anything secret-shaped.
        var secrets: [String] = []
        func scrubbed(_ text: String, extraSecrets: [String] = []) -> String {
            Redactor.scrubPatterns(Redactor.scrub(text, secrets: secrets + extraSecrets))
        }

        // 1. The engine answers. Cold first call ~16 ms (Go runtime init), per the spike.
        do {
            let version = try await XrayCore.shared.version()
            checks.append(Check(name: "engine", verdict: .ok, detail: "Xray-core \(version)"))
        } catch {
            checks.append(Check(
                name: "engine", verdict: .failure,
                detail: scrubbed(error.localizedDescription)))
        }

        // 2. The config: synthesized, present (+ permissions), or missing.
        let envSynthesized = environment["ELSEWHERE_LINK"]?.isEmpty == false
        var config: ElsewhereConfig?
        if envSynthesized {
            checks.append(Check(
                name: "config", verdict: .info,
                detail: "synthesized from ELSEWHERE_LINK; the file is ignored"))
            config = try? store.load(environment: environment)
        } else {
            do {
                let loaded = try store.load(environment: environment)
                config = loaded
                if ConfigStore.permissionsAreStrict(store.url) {
                    checks.append(Check(name: "config", verdict: .ok, detail: store.url.path))
                } else {
                    checks.append(Check(
                        name: "config", verdict: .warning,
                        detail: "\(store.url.path) — permissions looser than 0600"))
                }
            } catch {
                checks.append(Check(
                    name: "config", verdict: .failure,
                    detail: scrubbed(error.localizedDescription)))
            }
        }

        secrets = config?.exits.values.flatMap { exit -> [String] in
            guard case .link(let link) = exit else { return [] }
            return Redactor.secrets(inLink: link) + [link]
        } ?? []

        // 3. Each exit resolves (links/xray through the engine; proxies get a port probe).
        var resolved: [(name: String, outbound: JSONValue)] = []
        for (name, exit) in (config?.exits ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch exit {
            case .link, .xray:
                do {
                    if let outbound = try await ExitResolver.outbound(for: exit, named: name) {
                        resolved.append((name, outbound))
                        let outboundSecrets = Redactor.secrets(in: outbound)
                        checks.append(Check(
                            name: "exit \(name)", verdict: .ok,
                            detail: scrubbed(describe(outbound), extraSecrets: outboundSecrets)))
                    }
                } catch {
                    checks.append(Check(
                        name: "exit \(name)", verdict: .failure,
                        detail: scrubbed(error.localizedDescription)))
                }
            case .proxy(let url):
                let summary = Redactor.summary(of: exit)
                let host = url.host(percentEncoded: false)
                if let host, isLoopback(host) {
                    if let port = url.port, let port16 = UInt16(exactly: port), port16 > 0 {
                        if await LoopbackProbe.isListening(port: port16) {
                            checks.append(Check(
                                name: "exit \(name)", verdict: .ok,
                                detail: "\(summary) — listening"))
                        } else {
                            checks.append(Check(
                                name: "exit \(name)", verdict: .warning,
                                detail: "\(summary) — nothing listening on \(host):\(port)"))
                        }
                    } else {
                        checks.append(Check(
                            name: "exit \(name)", verdict: .warning,
                            detail: "\(summary) — no usable port"))
                    }
                } else {
                    checks.append(Check(
                        name: "exit \(name)", verdict: .info, detail: "\(summary) — external"))
                }
            }
        }

        // 4. The default names a real exit (or warns — `fetch` needs `--exit` without one).
        if let config {
            if let `default` = config.default {
                if config.exits[`default`] != nil {
                    checks.append(Check(name: "default", verdict: .ok, detail: `default`))
                } else {
                    checks.append(Check(
                        name: "default", verdict: .failure,
                        detail: "'\(`default`)' is not among the exits"))
                }
            } else {
                checks.append(Check(
                    name: "default", verdict: .warning,
                    detail: "no default exit; name one with `exits default NAME` or pass --exit"))
            }
        }

        // 5. Interface binding (§3.3): resolved name, pinned name, or unbound by choice.
        var interface: String?
        if let config {
            switch config.bindInterface {
            case .none:
                checks.append(Check(
                    name: "interface", verdict: .info, detail: "outbounds unbound (via system)"))
            case .named(let name):
                interface = name
                checks.append(Check(name: "interface", verdict: .ok, detail: name))
            case .auto:
                if let found = await InterfaceResolver.physicalInterfaceName() {
                    interface = found
                    checks.append(Check(name: "interface", verdict: .ok, detail: found))
                } else {
                    checks.append(Check(
                        name: "interface", verdict: .warning,
                        detail: "no physical interface found; outbounds would run unbound"))
                }
            }
        }

        // 6. Candidate ports — one per resolved exit + one for `direct`, never INCY's.
        var ports: [UInt16] = []
        do {
            ports = try await XrayCore.shared.freePorts(
                resolved.count + 1, excluding: [localProxyPort])
            checks.append(Check(
                name: "ports", verdict: .ok,
                detail: "\(ports.count) candidates for \(resolved.count) exits + direct"))
        } catch {
            checks.append(Check(
                name: "ports", verdict: .failure,
                detail: scrubbed(error.localizedDescription)))
        }

        // 7. The assembled config passes the engine's own validation — the live proof
        // that a converted outbound splices (C5 §3: `test` binds no sockets).
        if !resolved.isEmpty, ports.count == resolved.count + 1 {
            var portsByName: [String: UInt16] = [:]
            for (index, lane) in resolved.enumerated() {
                portsByName[lane.name] = ports[index]
            }
            do {
                let built = try XrayConfigBuilder.build(
                    exits: resolved, ports: portsByName,
                    directPort: ports[resolved.count], bindInterface: interface, log: .silent)
                try await XrayCore.shared.test(configJSON: built.configJSON)
                checks.append(Check(
                    name: "xray config", verdict: .ok,
                    detail: "assembles and validates (\(resolved.count + 1) inbounds)"))
            } catch {
                let outboundSecrets = resolved.flatMap { Redactor.secrets(in: $0.outbound) }
                checks.append(Check(
                    name: "xray config", verdict: .failure,
                    detail: scrubbed(error.localizedDescription, extraSecrets: outboundSecrets)))
            }
        }

        // 8. A local proxy already listening — INCY's mixed inbound is declared as a
        // `proxy` exit when wanted (D10: never a dependency).
        if await LoopbackProbe.isListening(port: localProxyPort) {
            checks.append(Check(
                name: "local proxy", verdict: .info,
                detail: "a local proxy listens on 127.0.0.1:\(localProxyPort) (INCY?) — "
                    + "`exits add incy --proxy http://127.0.0.1:\(localProxyPort)` uses it as an exit"))
        } else {
            checks.append(Check(
                name: "local proxy", verdict: .info,
                detail: "nothing on 127.0.0.1:\(localProxyPort)"))
        }

        return checks
    }

    /// `[ok]   engine      Xray-core 26.10.21` — ASCII tags and padded columns, so agents
    /// and scripts read it as easily as people do.
    public static func lines(_ checks: [Check]) -> [String] {
        let nameWidth = checks.map(\.name.count).max() ?? 0
        return checks.map { check in
            let tag = switch check.verdict {
            case .ok: "ok"
            case .info: "info"
            case .warning: "warn"
            case .failure: "FAIL"
            }
            let paddedTag = "[\(tag)]".padding(toLength: 6, withPad: " ", startingAt: 0)
            let paddedName = check.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            return "\(paddedTag) \(paddedName)  \(check.detail)"
        }
    }

    /// `vless/xhttp+reality → proxy.example.com:8443` — everything read *after* redaction,
    /// and classic `vnext`/`servers` shapes are read too (C5: the loader accepts both).
    static func describe(_ outbound: JSONValue) -> String {
        let redacted = Redactor.redact(outbound.singleOutbound)
        guard case .object(let object) = redacted,
            case .string(let proto)? = object["protocol"]
        else { return "invalid outbound (no protocol)" }
        var route = proto
        if case .object(let stream)? = object["streamSettings"] {
            if case .string(let network)? = stream["network"], network != "tcp" {
                route += "/\(network)"
            }
            if case .string(let security)? = stream["security"], security != "none" {
                route += "+\(security)"
            }
        }
        guard case .object(let settings)? = object["settings"] else { return route }
        if case .string(let address)? = settings["address"] {
            return "\(route) → \(endpoint(address, settings["port"]))"
        }
        // Classic shape: settings.vnext[0] or settings.servers[0].
        for key in ["vnext", "servers"] {
            if case .array(let list)? = settings[key],
                case .object(let first)? = list.first,
                case .string(let address)? = first["address"]
            {
                return "\(route) → \(endpoint(address, first["port"]))"
            }
        }
        return route
    }

    static func endpoint(_ address: String, _ port: JSONValue?) -> String {
        guard case .number(let port) = port else { return address }
        return "\(address):\(Int(port))"
    }

    /// The hosts a `proxy` exit gets probed on: literals only — `localhost` resolves, so
    /// a probe is meaningful there too.
    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}
