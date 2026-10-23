import Foundation
import Testing
@testable import ElsewhereKit

/// `environment(for:)` is pure; `run` really spawns — `/usr/bin/true` and
/// `/usr/bin/false` are the fixed points (no network anywhere).
@Suite("ChildRunner — proxy env and the child's own status")
struct ChildRunnerTests {
    @Test func anInboundRouteAdvertisesTheMixedInbound() throws {
        let env = ChildRunner.environment(
            for: .inbound(exit: "x", port: 10801), base: ["KEEP": "me"])
        #expect(env["KEEP"] == "me")
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            #expect(env[key] == "http://127.0.0.1:10801")
        }
        for key in ["ALL_PROXY", "all_proxy"] {
            // `socks5h` — the `h` keeps DNS remote (the exit resolves, not the LAN).
            #expect(env[key] == "socks5h://127.0.0.1:10801")
        }
        for key in ["NO_PROXY", "no_proxy"] {
            #expect(env[key] == "localhost,127.0.0.1,::1")
        }
    }

    @Test func anExternalRoutePassesItsURLThrough() throws {
        let url = try #require(URL(string: "socks5h://u:p@proxy.example.com:1080"))
        let env = ChildRunner.environment(for: .external(exit: "incy", url: url), base: [:])
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
            "ALL_PROXY", "all_proxy"] {
            #expect(env[key] == "socks5h://u:p@proxy.example.com:1080")
        }
        #expect(env["NO_PROXY"] == "localhost,127.0.0.1,::1")
    }

    @Test func trueExitsZero() async throws {
        let status = try await ChildRunner.run(
            ["/usr/bin/true"], via: .inbound(exit: "t", port: 9))
        #expect(status == 0)
    }

    @Test func falseExitsOne() async throws {
        let status = try await ChildRunner.run(
            ["/usr/bin/false"], via: .inbound(exit: "t", port: 9))
        #expect(status == 1)
    }

    @Test func anEmptyCommandIsUsage() async {
        do {
            _ = try await ChildRunner.run([], via: .inbound(exit: "t", port: 9))
            Issue.record("expected .usage")
        } catch ElsewhereError.usage {
        } catch {
            Issue.record("expected .usage, got \(error)")
        }
    }
}
