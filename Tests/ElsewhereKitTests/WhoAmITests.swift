import Foundation
import Testing
@testable import ElsewhereKit

/// `whoami` against the fixture `/cdn-cgi/trace`: the first URL answers, then a
/// broken first URL proves the fallback. Engine-touching — `.engineGate`.
@Suite("WhoAmI — trace through a lane, with fallback", .serialized, .engineGate)
struct WhoAmITests {
    private func withServerAndRoute(
        _ body: (Route, URL) async throws -> Void
    ) async throws {
        let server = try TestHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let supervisor = TunnelSupervisor()
        let lanes = try await supervisor.start(
            exits: [], bindInterface: nil, log: .silent, excludingPorts: [])
        do {
            try await body(
                .inbound(exit: "direct", port: lanes[0].inboundPort),
                try #require(URL(string: "http://127.0.0.1:\(port)")))
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()
    }

    @Test func aTraceEndpointYieldsAnIdentity() async throws {
        try await withServerAndRoute { route, base in
            let trace = try await WhoAmI.trace(
                via: route, userAgent: "elsewhere-tests",
                traceURLs: [base.appendingPathComponent("cdn-cgi/trace")],
                allowPrivate: true)
            #expect(trace == Trace(ip: "203.0.113.9", loc: "ZZ", colo: "AAA"))
        }
    }

    @Test func aFailingFirstURLFallsBack() async throws {
        let closed = try TestHTTPServer()
        let closedPort = try await closed.start()
        closed.stop()
        try await withServerAndRoute { route, base in
            let trace = try await WhoAmI.trace(
                via: route, userAgent: "elsewhere-tests",
                traceURLs: [
                    URL(string: "http://127.0.0.1:\(closedPort)/cdn-cgi/trace")!,
                    base.appendingPathComponent("cdn-cgi/trace"),
                ],
                allowPrivate: true)
            #expect(trace.ip == "203.0.113.9")
        }
    }

    @Test func allURLsFailingThrowsTheLast() async throws {
        let closed = try TestHTTPServer()
        let closedPort = try await closed.start()
        closed.stop()
        try await withServerAndRoute { route, _ in
            do {
                _ = try await WhoAmI.trace(
                    via: route, userAgent: "elsewhere-tests",
                    traceURLs: [URL(string: "http://127.0.0.1:\(closedPort)/cdn-cgi/trace")!],
                    allowPrivate: true)
                Issue.record("expected a throw")
            } catch ElsewhereError.fetch {
            }
        }
    }
}
