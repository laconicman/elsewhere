import Foundation
import Testing
@testable import ElsewhereKit

/// `RedirectPolicy.decide` is pure — hop count and the private-address guard are the
/// whole contract, no URLSession needed.
@Suite("RedirectPolicy — hop limit, private hops, follow")
struct RedirectPolicyTests {
    private func request(
        maxRedirects: Int = 10, allowPrivate: Bool = false
    ) -> FetchRequest {
        FetchRequest(
            url: URL(string: "https://example.com/")!, userAgent: "t",
            maxRedirects: maxRedirects, allowPrivate: allowPrivate)
    }

    @Test func aPublicHopIsFollowed() throws {
        let decision = RedirectPolicy.decide(
            hop: try #require(URL(string: "https://example.org/next")),
            count: 1, limits: request())
        guard case .follow = decision else {
            Issue.record("expected .follow, got \(decision)")
            return
        }
    }

    @Test func theHopBeyondTheLimitIsRefused() throws {
        let decision = RedirectPolicy.decide(
            hop: try #require(URL(string: "https://example.org/next")),
            count: 11, limits: request(maxRedirects: 10))
        guard case .refuse(.fetch(let message)) = decision else {
            Issue.record("expected .refuse(.fetch), got \(decision)")
            return
        }
        #expect(message.contains("10"))
    }

    @Test func theLimitHopItselfIsFollowed() throws {
        let decision = RedirectPolicy.decide(
            hop: try #require(URL(string: "https://example.org/next")),
            count: 10, limits: request(maxRedirects: 10))
        guard case .follow = decision else {
            Issue.record("expected .follow, got \(decision)")
            return
        }
    }

    @Test func aPrivateHopIsRefused() throws {
        let decision = RedirectPolicy.decide(
            hop: try #require(URL(string: "http://169.254.169.254/")),
            count: 1, limits: request())
        guard case .refuse(.refused) = decision else {
            Issue.record("expected .refuse(.refused), got \(decision)")
            return
        }
    }

    @Test func allowPrivateFollowsAPrivateHop() throws {
        let decision = RedirectPolicy.decide(
            hop: try #require(URL(string: "http://127.0.0.1/")),
            count: 1, limits: request(allowPrivate: true))
        guard case .follow = decision else {
            Issue.record("expected .follow, got \(decision)")
            return
        }
    }
}

/// `key=value` lines → `Trace`; `colo` is optional, `ip` and `loc` are not.
@Suite("TraceParser — the cdn-cgi/trace shape")
struct TraceParserTests {
    @Test func ipLocColoParse() throws {
        let trace = try #require(
            TraceParser.parse("fl=1\nip=203.0.113.9\nts=1.0\ncolo=AAA\nloc=ZZ\n"))
        #expect(trace == Trace(ip: "203.0.113.9", loc: "ZZ", colo: "AAA"))
    }

    @Test func coloIsOptional() throws {
        let trace = try #require(TraceParser.parse("ip=203.0.113.9\nloc=ZZ\n"))
        #expect(trace == Trace(ip: "203.0.113.9", loc: "ZZ", colo: nil))
    }

    @Test(arguments: [
        "loc=ZZ\n",
        "ip=203.0.113.9\n",
        "<html>not a trace</html>",
        "",
    ])
    func missingFieldsAreNil(text: String) {
        #expect(TraceParser.parse(text) == nil)
    }

    @Test func equalsInsideAValueSurvives() throws {
        let trace = try #require(
            TraceParser.parse("ip=203.0.113.9\nloc=ZZ\nuag=Mozilla/5.0=x\n"))
        #expect(trace.ip == "203.0.113.9")
    }
}

/// The four supported schemes build; anything else is a named `.exit`, never a
/// silent CONNECT (`ProxyConfiguration` isn't introspectable — construction is the
/// observable).
@Suite("ProxySessionFactory — the scheme decides the transport")
struct ProxySessionFactoryTests {
    @Test(arguments: ["http", "https", "socks5", "socks5h"])
    func supportedSchemesBuild(scheme: String) throws {
        let url = try #require(URL(string: "\(scheme)://u:p@proxy.example:1080"))
        _ = try ProxySessionFactory.configuration(for: .external(exit: "x", url: url))
    }

    @Test func anUnknownSchemeIsAnExitError() throws {
        let url = try #require(URL(string: "gopher://proxy.example:70"))
        do {
            _ = try ProxySessionFactory.configuration(for: .external(exit: "x", url: url))
            Issue.record("expected .exit")
        } catch ElsewhereError.exit(let message) {
            #expect(message.contains("scheme 'gopher'"))
            #expect(message.contains("supported"))
        }
    }

    @Test func aMissingPortIsAnExitError() throws {
        let url = try #require(URL(string: "http://proxy.example"))
        do {
            _ = try ProxySessionFactory.configuration(for: .external(exit: "x", url: url))
            Issue.record("expected .exit")
        } catch ElsewhereError.exit(let message) {
            #expect(message.contains("host:port"))
        }
    }
}
