import ArgumentParser
import ElsewhereKit
import Foundation

/// `--exit NAME` / `--direct` — the selection triad shared by fetch/whoami/run.
/// Neither means "the configured default".
struct ExitOptions: ParsableArguments {
    @Option(name: .customLong("exit"), help: "Route through the named exit.")
    var exitName: String?

    @Flag(help: "Route through the direct lane — bound to the physical interface, past any system VPN.")
    var direct = false

    func validate() throws {
        guard !(exitName != nil && direct) else {
            throw ValidationError("pass --exit NAME or --direct, not both")
        }
    }

    var selection: ExitSelection {
        // `--exit direct` names the direct lane, like the flag does.
        if direct || exitName == "direct" { return .direct }
        if let exitName { return .named(exitName) }
        return .default
    }
}

/// How the engine rides the network (`--via-system`) and where its console log goes
/// (`--xray-log`, `ELSEWHERE_XRAY_LOG`; silent by default).
struct TunnelOptions: ParsableArguments {
    @Flag(
        name: .customLong("via-system"),
        help: "Don't bind the engine's sockets to the physical interface — ride the system path, i.e. the system VPN when one is up.")
    var viaSystem = false

    @Option(
        name: .customLong("xray-log"),
        help: "Write the engine's warnings to this file; env ELSEWHERE_XRAY_LOG; default silent. A leading ~ is expanded.")
    var xrayLog: String?

    /// Flag beats env, env beats silent. Both are JSON/shell text — `UserPath`
    /// expands a leading `~`.
    var log: XrayConfigBuilder.XrayLog {
        if let xrayLog { return .file(UserPath.expanded(xrayLog)) }
        if let path = ProcessInfo.processInfo.environment["ELSEWHERE_XRAY_LOG"],
            !path.isEmpty
        { return .file(UserPath.expanded(path)) }
        return .silent
    }

    /// `--via-system` unbinds; otherwise the config's `bindInterface` stands.
    func bindInterface(from config: ElsewhereConfig) -> BindInterface {
        viaSystem ? .none : config.bindInterface
    }
}
