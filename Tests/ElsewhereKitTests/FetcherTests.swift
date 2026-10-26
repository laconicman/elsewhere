import Foundation
import Testing
@testable import ElsewhereKit

/// The fetch path end-to-end on loopback: URLSession → HTTP CONNECT into the
/// engine's `mixed` inbound → `direct` outbound → `TestHTTPServer`. Engine-touching —
/// serialized through `.engineGate` like every suite that owns a core.
@Suite("Fetcher — one URL through a lane", .serialized, .engineGate)
struct FetcherTests {
    /// Starts the fixture server and a direct-only tunnel; the body gets the lane
    /// route and the server's base URL.
    private func withServerAndRoute(
        _ body: (Route, URL) async throws -> Void
    ) async throws {
        let server = try TestHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let supervisor = TunnelSupervisor()
        let lanes = try await supervisor.start(
            exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
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

    private func request(_ url: URL, method: FetchRequest.Method = .get) -> FetchRequest {
        FetchRequest(
            url: url, method: method, userAgent: "elsewhere-tests", allowPrivate: true)
    }

    @Test func okReturnsStatusBodyAndHeaders() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("ok")), via: route)
            #expect(result.status == 200)
            #expect(result.body == Data(TestHTTPServer.okBody.utf8))
            #expect(result.contentType?.contains("text/html") == true)
            #expect(result.truncated == false)
            #expect(result.exit == "direct")
            #expect(result.redirects.isEmpty)
            #expect(result.finalURL == result.requestURL)
        }
    }

    /// A `Location`-style header can carry `user:pass@` — every header value is
    /// scrubbed the way a printed URL is, so `--json` and `--head` never show it.
    @Test func urlShapedHeadersLoseTheirUserinfo() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("userinfo")), via: route)
            #expect(result.headers["content-location"] == "http://127.0.0.1/x")
            #expect(result.headers["link"] == #"<http://127.0.0.1/n>; rel="next""#)
            #expect(result.headers.values.allSatisfy { !$0.contains("secret") })
        }
    }

    @Test func aBodyOverTheCapIsCutAndFlagged() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("big")), via: route)
            #expect(result.truncated)
            #expect(result.body.count == FetchLimits.maxBodyBytes)
        }
    }

    @Test func aDeclaredCharsetDecodesTheBody() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("cp1251")), via: route)
            let decoded = try #require(
                TextDecoder.decode(result.body, contentType: result.contentType))
            #expect(decoded.text == "Привет")
            #expect(decoded.encoding == "windows-1251")
        }
    }

    @Test func aBinaryBodyIsNotText() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("bin")), via: route)
            #expect(TextDecoder.decode(result.body, contentType: result.contentType) == nil)
            #expect(result.body.count == 4)
        }
    }

    @Test func aRedirectIsFollowedAndRecorded() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("redir")), via: route)
            #expect(result.status == 200)
            #expect(result.redirects == [base.appendingPathComponent("ok")])
            #expect(result.finalURL == base.appendingPathComponent("ok"))
        }
    }

    /// `--no-redirects` (`maxRedirects: 0`): the 3xx itself is the result — the
    /// Location header says where it pointed, `redirects` stays empty.
    @Test func aStoppedRedirectIsTheResult() async throws {
        try await withServerAndRoute { route, base in
            var stop = request(base.appendingPathComponent("redir"))
            stop.maxRedirects = 0
            let result = try await Fetcher.fetch(stop, via: route)
            #expect(result.status == 302)
            #expect(result.headers["location"] == "/ok")
            #expect(result.redirects.isEmpty)
            #expect(result.finalURL == result.requestURL)
        }
    }

    @Test func aRedirectLoopHitsTheLimit() async throws {
        try await withServerAndRoute { route, base in
            do {
                _ = try await Fetcher.fetch(
                    request(base.appendingPathComponent("loop")), via: route)
                Issue.record("expected .fetch")
            } catch ElsewhereError.fetch(let message) {
                #expect(message.contains("redirect limit"))
            }
        }
    }

    /// `--timeout` bounds the whole fetch, not one read: a trickle beats every
    /// per-read wait but the resource bound still fires at the limit.
    @Test func aTricklingBodyHitsTheResourceTimeout() async throws {
        try await withServerAndRoute { route, base in
            var slow = request(base.appendingPathComponent("trickle"))
            slow.timeout = .seconds(1)
            let began = ContinuousClock.now
            do {
                _ = try await Fetcher.fetch(slow, via: route)
                Issue.record("expected .fetch")
            } catch ElsewhereError.fetch {
                #expect(ContinuousClock.now - began < .seconds(3))
            }
        }
    }

    @Test func headReturnsHeadersAndNoBody() async throws {
        try await withServerAndRoute { route, base in
            let result = try await Fetcher.fetch(
                request(base.appendingPathComponent("head"), method: .head), via: route)
            #expect(result.status == 200)
            #expect(result.body.isEmpty)
            #expect(result.headers["content-length"] != nil)
        }
    }

    @Test func aConnectionRefusedPortIsAFetchError() async throws {
        // A port that was bound and is now closed — connection refused.
        let closed = try TestHTTPServer()
        let closedPort = try await closed.start()
        closed.stop()
        try await withServerAndRoute { route, _ in
            do {
                _ = try await Fetcher.fetch(
                    request(try #require(URL(string: "http://127.0.0.1:\(closedPort)/"))),
                    via: route)
                Issue.record("expected .fetch")
            } catch ElsewhereError.fetch {
            }
        }
    }
}
