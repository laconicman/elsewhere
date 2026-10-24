import ElsewhereKit
import Foundation
import MCP
import Testing
import XrayCore
@testable import ElsewhereMCP

/// `elsewhere_whoami`: the line's shape and the failure-lines rule are
/// engine-free; the live probe runs once through the `direct` lane at the
/// loopback fixture (`context.traceURLs` is the seam).
@Suite("elsewhere_whoami — the line, the failure lines, one live probe",
       .serialized, .temporaryDirectories)
struct WhoAmIToolTests {
    private func store(_ config: ElsewhereConfig) throws -> ConfigStore {
        let store = ConfigStore(
            url: temporaryDirectory().appending(path: "config.json"))
        try store.save(config)
        return store
    }

    /// `exit NAME: ip <ip> loc <loc>[ colo <colo>]` — the CLI's whoami line.
    @Test func theLineCarriesIpLocAndAnOptionalColo() {
        #expect(
            ToolSpec.line("p", Trace(ip: "1.2.3.4", loc: "ZZ"))
                == "exit p: ip 1.2.3.4 loc ZZ")
        #expect(
            ToolSpec.line("p", Trace(ip: "1.2.3.4", loc: "ZZ", colo: "AAA"))
                == "exit p: ip 1.2.3.4 loc ZZ colo AAA")
    }

    /// Without `exit` every lane reports, failures as lines — the call itself
    /// does not fail. Engine-free: a dead `proxy` exit's error line, and
    /// `direct` (which the proxy-only session never opened) reports its `.exit`.
    @Test func theAllExitsFormReportsFailuresAsLines() async throws {
        let store = try store(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:1")!),
        ]))
        let context = ServeContext.make(
            store: store, options: ServeOptions(idleStop: nil, allowPrivate: true)
        ) { config, _, _ throws(ElsewhereError) -> TunnelSession in
            try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: false,
                bindInterface: .none, log: .silent)
        }
        let reply = try await Toolbox(specs: [.whoami(context)])
            .reply("elsewhere_whoami")
        #expect(!reply.isError)
        #expect(reply.text.contains("exit p: "), "\(reply.text)")
        #expect(
            reply.text.contains("exit direct: no route for exit 'direct'"),
            "\(reply.text)")
        await context.tunnel.close(reason: "eof")
    }

    /// A named probe through `direct`: the fixture trace yields the identity
    /// line, and closing the tunnel stops the engine.
    @Test(.engineGate, .timeLimit(.minutes(1)))
    func aNamedProbeThroughDirectShowsTheIdentity() async throws {
        let http = try TestHTTPServer()
        let port = try await http.start()
        defer { http.stop() }
        let store = try store(ElsewhereConfig())
        let options = ServeOptions(idleStop: nil, allowPrivate: true, viaSystem: true)
        let context = ServeContext.make(
            store: store, options: options,
            traceURLs: [
                URL(string: "http://127.0.0.1:\(port)/cdn-cgi/trace")!,
            ]
        ) { config, bindInterface, log throws(ElsewhereError) -> TunnelSession in
            try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: true,
                bindInterface: bindInterface, log: log)
        }
        let reply = try await Toolbox(specs: [.whoami(context)])
            .reply("elsewhere_whoami", ["exit": "direct"])
        #expect(!reply.isError)
        #expect(
            reply.text == "exit direct: ip 203.0.113.9 loc ZZ colo AAA",
            "\(reply.text)")
        await context.tunnel.close(reason: "eof")
        #expect(await XrayCore.shared.isRunning == false)
    }
}
