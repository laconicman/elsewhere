import Foundation

/// The config-aware tunnel a command holds (§5.4): resolves exits to routes, starts the
/// engine for the Xray lanes it needs, and stops it on `close`. Per A9 the CLI starts
/// only the lanes a call needs — a `proxy` exit never touches the engine at all.
public actor TunnelSession {
    private let supervisor: TunnelSupervisor
    private var routes: [String: Route]
    private var startedEngine: Bool

    private init(supervisor: TunnelSupervisor, routes: [String: Route], startedEngine: Bool) {
        self.supervisor = supervisor
        self.routes = routes
        self.startedEngine = startedEngine
    }

    /// Opens a session for `exits`: `link`/`xray` exits resolve to engine lanes,
    /// `proxy` exits become external routes without starting the engine.
    /// `includeDirect` asks for the `direct` lane too — needed when the direct path is
    /// a route of its own (`--direct`), not merely built alongside.
    ///
    /// - Parameters:
    ///   - bindInterface: applied to every outbound; `.auto` that resolves to no
    ///     physical interface is a start error, never a quiet unbind (A8).
    ///   - interfaceResolver: the test seam (same shape as `Doctor`).
    /// - Throws: `.exit` for an unknown name, `.engine`/`.tunnel` from the supervisor,
    ///   and `.tunnel` when `.auto` finds no physical interface.
    public static func open(
        config: ElsewhereConfig,
        exits: Set<String>,
        includeDirect: Bool,
        bindInterface: BindInterface,
        log: XrayConfigBuilder.XrayLog,
        supervisor: TunnelSupervisor = TunnelSupervisor(),
        interfaceResolver: @Sendable (BindInterface) async -> String? = InterfaceResolver.resolve
    ) async throws(ElsewhereError) -> TunnelSession {
        var routes: [String: Route] = [:]
        var xrayExits: [(name: String, outbound: JSONValue)] = []
        // A loopback proxy exit's port must not be issued as an inbound — URLSession
        // would reach the proxy on a port the engine took (same rule as Doctor's).
        var excludedPorts: [UInt16] = []
        for name in exits.sorted() {
            guard let exit = config.exits[name] else {
                throw .exit("no exit named '\(name)'")
            }
            switch exit {
            case .proxy(let url):
                routes[name] = .external(exit: name, url: url)
                if let host = url.host(percentEncoded: false),
                    LoopbackProbe.isLoopbackHost(host),
                    let port = url.port, let port16 = UInt16(exactly: port)
                { excludedPorts.append(port16) }
            case .link, .xray:
                // .link/.xray always resolve non-nil; the resolver's own errors carry
                // the typed cases already (.engine scrubbed, .exit on shape).
                if let outbound = try await ExitResolver.outbound(for: exit, named: name) {
                    xrayExits.append((name, outbound))
                }
            }
        }

        var startedEngine = false
        if !xrayExits.isEmpty || includeDirect {
            let interface = await interfaceResolver(bindInterface)
            if bindInterface == .auto, interface == nil {
                throw .tunnel(
                    "no physical interface found; the tunnel refuses to start unbound — "
                        + "set bindInterface to a name or `none` to run via the system path")
            }
            let lanes = try await supervisor.start(
                exits: xrayExits, bindInterface: interface, log: log,
                excludingPorts: excludedPorts)
            startedEngine = true
            for lane in lanes {
                routes[lane.exitName] = .inbound(exit: lane.exitName, port: lane.inboundPort)
            }
        }
        return TunnelSession(
            supervisor: supervisor, routes: routes, startedEngine: startedEngine)
    }

    /// The route for an exit name — `"direct"` names the direct lane like any other.
    /// - Throws: `.exit` when the session was opened without that lane.
    public func route(for name: String) throws(ElsewhereError) -> Route {
        guard let route = routes[name] else {
            throw .exit("no route for exit '\(name)' in this session")
        }
        return route
    }

    /// Stops the engine if this session started it; idempotent, never throws.
    public func close() async {
        if startedEngine {
            startedEngine = false
            await supervisor.stop()
        }
    }
}
