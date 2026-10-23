import ArgumentParser
import ElsewhereKit
import Foundation

/// `elsewhere whoami` — one line per exit: `exit NAME: ip <ip> loc <loc>`, the egress
/// identity the exit actually shows (`direct` counts as an exit name here).
/// `--all` probes every configured exit plus direct on one engine start (A9).
struct WhoAmICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Ask what identity an exit shows: ip and loc from Cloudflare's trace.",
        discussion: """
        --all probes every configured exit and direct on a single tunnel; one exit's
        failure is reported and the rest continue. The exit status is the first
        failure's.
        """
    )

    @OptionGroup var exits: ExitOptions
    @OptionGroup var tunnel: TunnelOptions
    @OptionGroup var options: GlobalOptions

    @Flag(help: "Probe every configured exit and direct.")
    var all = false

    @Flag(help: "Print a JSON array of {exit, ip, loc, colo} on stdout.")
    var json = false

    func validate() throws {
        if all, exits.exitName != nil || all, exits.direct {
            throw ValidationError("--all covers every exit; drop --exit/--direct")
        }
    }

    func run() async throws {
        try await exitingWithStatus { () async throws(ElsewhereError) -> Int32 in
            let config = try options.store.load(
                environment: ProcessInfo.processInfo.environment)
            let ua = config.userAgent.string
            // Sorted exits, direct last — a stable order a reader can diff.
            let names = all ? config.exits.keys.sorted() + ["direct"] : []
            return try await withSignalCancellation { () async throws(ElsewhereError) in
                if all {
                    return try await Session.withSession(
                        names: Set(config.exits.keys), includeDirect: true,
                        config: config, tunnel: tunnel
                    ) { session throws(ElsewhereError) in
                        try await probe(names, userAgent: ua) {
                            name throws(ElsewhereError) in
                            try await session.route(for: name)
                        }
                    }
                }
                let name = try exits.selection.resolve(in: config)
                return try await Session.withRoute(
                    selection: exits.selection, config: config, tunnel: tunnel
                ) { route throws(ElsewhereError) in
                    try await probe([name], userAgent: ua) { _ throws(ElsewhereError) in route }
                }
            }
        }
    }

    /// Probes `names` in order; a failure prints `elsewhere: exit NAME: …` and the
    /// rest continue. Returns the first failure's exit status.
    private func probe(
        _ names: [String], userAgent: String,
        routeFor: (String) async throws(ElsewhereError) -> Route
    ) async throws(ElsewhereError) -> Int32 {
        struct Row: Encodable { let exit, ip, loc: String; let colo: String? }
        var rows: [Row] = []
        var firstError: ElsewhereError?
        for name in names {
            do {
                let trace = try await WhoAmI.trace(
                    via: routeFor(name), userAgent: userAgent)
                if !json { emit("exit \(name): ip \(trace.ip) loc \(trace.loc)") }
                rows.append(Row(exit: name, ip: trace.ip, loc: trace.loc, colo: trace.colo))
            } catch {
                if firstError == nil { firstError = error }
                printError("exit \(name): \(error.localizedDescription)")
            }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                emit(String(decoding: try encoder.encode(rows), as: UTF8.self))
            } catch {
                throw .fetch("cannot encode the result: \(error.localizedDescription)")
            }
        }
        return firstError?.exitStatus ?? 0
    }
}
