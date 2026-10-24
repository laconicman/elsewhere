public import ElsewhereKit // the options carry the Kit's XrayLog
public import Foundation // URL is public API

/// What `elsewhere serve` was told at launch, which no tool argument can change
/// (the plan's "serve flags, not tool inputs" decision): private destinations
/// stay refused unless `--allow-private`, the engine rides the system path under
/// `--via-system`, and the tunnel idles off after `idleStop` with no calls.
public struct ServeOptions: Sendable {
    /// Idle time after the last call's end before the engine stops; `nil` never
    /// idles off (`--idle-stop 0`).
    public var idleStop: Duration?
    /// `--allow-private`, applied to every fetch/whoami in the process — a serve
    /// flag, never a tool argument, so a page cannot talk a model into fetching
    /// the LAN.
    public var allowPrivate: Bool
    /// `--via-system`: outbounds unbound, riding the system path (the system VPN
    /// when one is up).
    public var viaSystem: Bool
    /// The engine log shape — serve defaults to a file; stdout is the protocol.
    public var log: XrayConfigBuilder.XrayLog
    /// `--log-tsv` target — one row per call and per lifecycle edge.
    public var tsvLog: URL?

    public init(
        idleStop: Duration? = .seconds(600), // 10 minutes — Duration has no .minutes
        allowPrivate: Bool = false,
        viaSystem: Bool = false,
        log: XrayConfigBuilder.XrayLog = .silent,
        tsvLog: URL? = nil
    ) {
        self.idleStop = idleStop
        self.allowPrivate = allowPrivate
        self.viaSystem = viaSystem
        self.log = log
        self.tsvLog = tsvLog
    }

    /// The interface the engine binds under these options — `--via-system`
    /// unbinds whatever the file says.
    public func bindInterface(for config: ElsewhereConfig) -> BindInterface {
        viaSystem ? .none : config.bindInterface
    }
}
