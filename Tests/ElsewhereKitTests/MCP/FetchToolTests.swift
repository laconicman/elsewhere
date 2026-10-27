import ElsewhereKit
import Foundation
import MCP
import Testing
import XrayCore
@testable import ElsewhereMCP

/// `elsewhere_fetch` end to end: a real `TunnelSession` over a config with no
/// exits, so the tunnel's one lane is `direct` — through the engine to the
/// loopback fixture. One engine start serves every call shape; `.engineGate`
/// serializes it with the other engine suites.
@Suite("elsewhere_fetch — headers, paging, raw, binary, HTTP errors",
       .serialized, .engineGate, .temporaryDirectories)
struct FetchToolTests {
    /// `--via-system` so no interface resolution is needed, `--allow-private`
    /// for the loopback fixture, `idleStop: nil` so nothing stops mid-test.
    private func context() throws -> ServeContext {
        let store = ConfigStore(
            url: temporaryDirectory().appending(path: "config.json"))
        try store.save(ElsewhereConfig())
        let options = ServeOptions(
            idleStop: nil, allowPrivate: true, viaSystem: true)
        return ServeContext.make(store: store, options: options) {
            config, bindInterface, log throws(ElsewhereError) -> TunnelSession in
            try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: true,
                bindInterface: bindInterface, log: log)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFetchThroughDirectServesTheToolContract() async throws {
        let http = try TestHTTPServer()
        let port = try await http.start()
        defer { http.stop() }
        let context = try context()
        let toolbox = Toolbox(specs: [.fetch(context)])
        let base = "http://127.0.0.1:\(port)"

        let ok = try await toolbox.reply(
            "elsewhere_fetch", ["url": "\(base)/ok", "exit": "direct"])
        #expect(!ok.isError)
        #expect(ok.text.hasPrefix("url: \(base)/ok\n"), "\(ok.text)")
        #expect(ok.text.contains("\nstatus: 200\n"), "\(ok.text)")
        #expect(ok.text.contains("\ncontent-type: text/html"), "\(ok.text)")
        #expect(ok.text.contains("\nexit: direct · "), "\(ok.text)")
        // `<html><body>ok</body></html>` rendered to Markdown.
        #expect(ok.text.contains("\nok"), "\(ok.text)")

        let paged = try await toolbox.reply(
            "elsewhere_fetch",
            ["url": "\(base)/ok", "exit": "direct", "max_length": 10])
        #expect(!paged.isError)
        #expect(paged.text.contains("next_start_index=10"), "\(paged.text)")

        let raw = try await toolbox.reply(
            "elsewhere_fetch", ["url": "\(base)/ok", "exit": "direct", "raw": true])
        #expect(!raw.isError)
        #expect(raw.text.contains("<html"), "\(raw.text)")

        let binary = try await toolbox.reply(
            "elsewhere_fetch", ["url": "\(base)/bin", "exit": "direct"])
        #expect(!binary.isError)
        #expect(
            binary.text.contains(
                "binary body (application/octet-stream, 4 bytes)"), "\(binary.text)")

        // HTTP ≥ 400 is a result, not an error — like the CLI's exit 0.
        let missing = try await toolbox.reply(
            "elsewhere_fetch", ["url": "\(base)/nope", "exit": "direct"])
        #expect(!missing.isError)
        #expect(missing.text.contains("\nstatus: 404\n"), "\(missing.text)")

        // `follow_redirects: false` — the 3xx is the result, `location` says
        // where it pointed.
        let stopped = try await toolbox.reply(
            "elsewhere_fetch",
            ["url": "\(base)/redir", "exit": "direct", "follow_redirects": false])
        #expect(!stopped.isError)
        #expect(stopped.text.contains("\nstatus: 302\n"), "\(stopped.text)")
        #expect(stopped.text.contains("\nlocation: /ok\n"), "\(stopped.text)")

        // …and the default still follows.
        let followed = try await toolbox.reply(
            "elsewhere_fetch", ["url": "\(base)/redir", "exit": "direct"])
        #expect(!followed.isError)
        #expect(followed.text.contains("\nstatus: 200\n"), "\(followed.text)")

        await context.tunnel.close(reason: "eof")
        #expect(await XrayCore.shared.isRunning == false)
    }
}
