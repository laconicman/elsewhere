public import Foundation // URL/Data/URLSession are public API
import Network // ProxyConfiguration — plumbing type, surfaced only as Route
import Synchronization
internal import os

/// The fetch defaults (§5.5), named once: 25 s, 5 MB, 10 redirects.
public enum FetchLimits {
    public static let timeout: Duration = .seconds(25)
    public static let maxBodyBytes = 5_000_000
    public static let maxRedirects = 10
    /// What a fetch advertises it wants (§5.5).
    public static let accept = "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
    public static let acceptLanguage = "en,ru;q=0.8"
}

/// One fetch's inputs — the CLI's flags and the M2 tool's parameters both land here.
public struct FetchRequest: Sendable {
    public enum Method: String, Sendable {
        case get
        case head
    }

    public var url: URL
    public var method: Method
    /// Extra headers — set after the built-ins, so the caller wins.
    public var headers: [String: String]
    /// The User-Agent the fetch sends (config or `--user-agent`; D8).
    public var userAgent: String
    public var timeout: Duration
    public var maxBodyBytes: Int
    public var maxRedirects: Int
    /// `--allow-private`: lift the private-address guard for this fetch.
    public var allowPrivate: Bool

    public init(
        url: URL,
        method: Method = .get,
        headers: [String: String] = [:],
        userAgent: String,
        timeout: Duration = FetchLimits.timeout,
        maxBodyBytes: Int = FetchLimits.maxBodyBytes,
        maxRedirects: Int = FetchLimits.maxRedirects,
        allowPrivate: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.userAgent = userAgent
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
        self.maxRedirects = maxRedirects
        self.allowPrivate = allowPrivate
    }
}

/// What a fetch learned — the body and everything an agent needs to judge it.
public struct FetchResult: Sendable {
    public var requestURL: URL
    public var finalURL: URL
    public var status: Int
    /// Response headers, keys lowercased — `headers["content-type"]`, not the wire
    /// spelling (HTTP field names are case-insensitive; one normalization for all).
    /// URL-shaped values carry no userinfo — same rule as a printed URL.
    public var headers: [String: String]
    public var contentType: String?
    public var body: Data
    /// The body hit `maxBodyBytes` mid-stream and was cut there.
    public var truncated: Bool
    public var elapsed: Duration
    /// The exit the request went through (a `Route`'s name — `"direct"` too).
    public var exit: String
    /// The hop targets followed, in order.
    public var redirects: [URL]

    public init(
        requestURL: URL, finalURL: URL, status: Int, headers: [String: String],
        contentType: String?, body: Data, truncated: Bool, elapsed: Duration,
        exit: String, redirects: [URL]
    ) {
        self.requestURL = requestURL
        self.finalURL = finalURL
        self.status = status
        self.headers = headers
        self.contentType = contentType
        self.body = body
        self.truncated = truncated
        self.elapsed = elapsed
        self.exit = exit
        self.redirects = redirects
    }
}

/// Redirect decision per hop — pure so the tests need no URLSession. The hop's URL is
/// re-checked by the private-address guard (§5.9), and the count has a hard limit.
public enum RedirectPolicy {
    public enum Decision: Sendable {
        case follow
        case refuse(ElsewhereError)
        /// `maxRedirects == 0`: not a breach — the 3xx is the fetch's result.
        case stop
    }

    /// `count` is this hop's ordinal — hop `maxRedirects + 1` is refused.
    /// Judgement order: zero means "do not follow" — the 3xx completes as the
    /// result and nothing is judged or recorded; an unparseable `Location`
    /// (a nil `hop`) is refused; then the limit, then the private-address guard.
    public static func decide(hop: URL?, count: Int, limits: FetchRequest) -> Decision {
        if limits.maxRedirects == 0 { return .stop }
        guard let hop else {
            return .refuse(.fetch("redirect to an unparseable URL"))
        }
        if count > limits.maxRedirects {
            return .refuse(.fetch("redirect limit (\(limits.maxRedirects)) reached"))
        }
        do throws(ElsewhereError) {
            try PrivateAddressGuard.check(hop, allowPrivate: limits.allowPrivate)
        } catch {
            return .refuse(error)
        }
        return .follow
    }
}

/// `route` → the `ProxyConfiguration` URLSession gets (§3.2, verified 2026-10-23):
/// `proxyConfigurations` takes Network's `ProxyConfiguration` — there is no
/// `HTTPProxyConfiguration` type. `allowFailover` is left at its default false,
/// always: a proxy failure must be an error, never a silent direct fetch (rule 5).
/// Internal: a Network type can't sit in the public surface (rule 1).
enum ProxySessionFactory {
    /// - Throws: `.exit` when an external proxy URL has no usable port (a hand-edited
    ///   config can carry one; `exits add` refuses it earlier).
    static func configuration(for route: Route) throws(ElsewhereError) -> ProxyConfiguration {
        switch route {
        case .inbound(_, let port):
            guard let endpoint = NWEndpoint.Port(rawValue: port) else {
                throw .exit("inbound port \(port) is not a TCP port")
            }
            return ProxyConfiguration(
                httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: endpoint))
        case .external(let exit, let url):
            guard let host = url.host(percentEncoded: false),
                let port = url.port,
                let endpoint = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
                endpoint.rawValue != 0
            else { throw .exit("proxy exit '\(exit)' has no usable host:port") }
            let target = NWEndpoint.hostPort(host: .init(host), port: endpoint)
            let configuration: ProxyConfiguration
            switch url.scheme?.lowercased() {
            case "http":
                configuration = ProxyConfiguration(httpCONNECTProxy: target)
            case "https":
                // TLS to the proxy itself, then CONNECT inside it.
                configuration = ProxyConfiguration(
                    httpCONNECTProxy: target, tlsOptions: NWProtocolTLS.Options())
            case "socks5", "socks5h":
                configuration = ProxyConfiguration(socksv5Proxy: target)
            case .some(let scheme):
                // An unknown scheme must not silently become a CONNECT proxy.
                throw .exit(
                    "proxy exit '\(exit)' has scheme '\(scheme)'; "
                        + "http, https, socks5 and socks5h are supported")
            case .none:
                throw .exit(
                    "proxy exit '\(exit)' has no scheme; "
                        + "http, https, socks5 and socks5h are supported")
            }
            if let user = url.user, !user.isEmpty {
                configuration.applyCredential(username: user, password: url.password ?? "")
            }
            return configuration
        }
    }
}

/// The redirect bookkeeping `URLSessionTaskDelegate` gives us: each hop through
/// ``RedirectPolicy/decide(hop:count:limits:)`` — `.follow` records the hop and passes
/// the request on; `.refuse` returns nil (URLSession stops and answers with the pre-hop
/// response) and records the error for the fetch to rethrow afterwards; `.stop`
/// returns nil and records nothing — the 3xx itself is the result.
final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    private struct State {
        var hopCount = 0
        var hops: [URL] = []
        var refused: ElsewhereError?
    }

    private let request: FetchRequest
    private let state = Mutex(State())

    init(request: FetchRequest) {
        self.request = request
    }

    var followedHops: [URL] { state.withLock { $0.hops } }
    var refusal: ElsewhereError? { state.withLock { $0.refused } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        switch state.withLock({ s -> RedirectPolicy.Decision in
            s.hopCount += 1
            return RedirectPolicy.decide(
                hop: request.url, count: s.hopCount, limits: self.request)
        }) {
        case .follow:
            if let hop = request.url { state.withLock { $0.hops.append(hop) } }
            completionHandler(request)
        case .refuse(let error):
            state.withLock { $0.refused = error }
            completionHandler(nil)
        case .stop:
            // "Do not follow" judges nothing — the 3xx is the result and
            // `redirects` stays empty.
            completionHandler(nil)
        }
    }
}

/// One URL per call (§5.5): URLSession over `ProxyConfiguration(httpCONNECTProxy:)` to
/// a tunnel lane, or at a `proxy` exit directly. HTTP ≥ 400 is a result, not an error —
/// the caller prints the status; only transport failures throw `.fetch`.
public enum Fetcher {
    private static let logger = Logger(subsystem: "com.learnable.elsewhere", category: "fetch")

    /// - Throws: `.usage`/`.refused` from the guard, `.fetch` on transport failure,
    ///   `.fetch("interrupted")` on cancellation (the CLI maps that to 128+signal).
    public static func fetch(_ request: FetchRequest, via route: Route) async throws(ElsewhereError)
        -> FetchResult
    {
        try PrivateAddressGuard.check(request.url, allowPrivate: request.allowPrivate)
        let proxy = try ProxySessionFactory.configuration(for: route)
        // An external proxy's URL carries credentials — transport errors can echo it.
        let secrets: [String]
        if case .external(_, let proxyURL) = route {
            secrets = Redactor.secrets(inLink: proxyURL.absoluteString)
        } else { secrets = [] }

        let delegate = RedirectDelegate(request: request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        let timeout = request.timeout.components
        let interval = TimeInterval(timeout.seconds)
            + TimeInterval(timeout.attoseconds) / 1e18
        configuration.timeoutIntervalForRequest = interval
        // …and for the resource — `--timeout` bounds the whole fetch, not one read.
        configuration.timeoutIntervalForResource = interval
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method == .head ? "HEAD" : "GET"
        urlRequest.setValue(FetchLimits.accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue(FetchLimits.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let started = ContinuousClock.now
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
            // A refused redirect completes the task with the pre-hop response — the
            // refusal is the verdict, not that 3xx.
            if let refusal = delegate.refusal { throw refusal }
            guard let http = response as? HTTPURLResponse else {
                throw ElsewhereError.fetch("no HTTP response")
            }
            var body = Data()
            var truncated = false
            for try await byte in bytes {
                if body.count < request.maxBodyBytes {
                    body.append(byte)
                } else {
                    truncated = true
                    break // stop reading; invalidateAndCancel tears the socket down
                }
            }
            if let refusal = delegate.refusal { throw refusal }
            let elapsed = ContinuousClock.now - started
            let millis = elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            let host = request.url.host(percentEncoded: false) ?? "-"
            logger.notice(
                "fetch exit=\(route.exitName) status=\(http.statusCode) bytes=\(body.count) ms=\(millis) host=\(host)")
            return FetchResult(
                requestURL: request.url,
                finalURL: http.url ?? request.url,
                status: http.statusCode,
                headers: http.allHeaderFields.reduce(into: [:]) {
                    $0["\($1.key)".lowercased()] = Redactor.redactUserinfo(in: "\($1.value)")
                },
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: body,
                truncated: truncated,
                elapsed: elapsed,
                exit: route.exitName,
                redirects: delegate.followedHops)
        } catch let error as ElsewhereError {
            throw error
        } catch is CancellationError {
            // Task cancellation → the CLI exits 128 + signal by its own bookkeeping.
            throw .fetch("interrupted")
        } catch {
            if let refusal = delegate.refusal { throw refusal }
            throw .fetch(
                Redactor.scrubPatterns(
                    Redactor.scrub(error.localizedDescription, secrets: secrets)))
        }
    }
}
