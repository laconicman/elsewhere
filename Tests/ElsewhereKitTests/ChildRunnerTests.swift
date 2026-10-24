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

    /// The parent's bypass list survives and gains loopback — an internal host
    /// the parent keeps off a proxy stays off ours; the exit could not resolve
    /// it anyway.
    @Test func aParentBypassListSurvivesAndGainsLoopback() {
        let env = ChildRunner.environment(
            for: .inbound(exit: "x", port: 10801),
            base: [
                "NO_PROXY": "git.corp.example, 10.0.0.0/8",
                "no_proxy": "localhost,wiki.corp.example",
            ])
        for key in ["NO_PROXY", "no_proxy"] {
            #expect(env[key] == "git.corp.example,10.0.0.0/8,localhost,"
                + "wiki.corp.example,127.0.0.1,::1")
        }
    }

    /// An empty parent list contributes nothing — loopback alone.
    @Test func anEmptyBypassListIsJustLoopback() {
        let env = ChildRunner.environment(
            for: .inbound(exit: "x", port: 10801), base: ["NO_PROXY": ""])
        for key in ["NO_PROXY", "no_proxy"] {
            #expect(env[key] == "localhost,127.0.0.1,::1")
        }
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

    /// Cancellation reaches the child: SIGTERM is forwarded (`sleep` dies to it),
    /// the reaped 128 + 15 flows back, and nothing waits the remaining ~30 s.
    @Test func cancellingTheWaitTerminatesTheChild() async throws {
        let began = ContinuousClock.now
        let task = Task {
            try await ChildRunner.run(
                ["/bin/sleep", "30"], via: .inbound(exit: "t", port: 9))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let status = try await task.value
        #expect(status == 143) // 128 + SIGTERM
        #expect(ContinuousClock.now - began < .seconds(1))
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
