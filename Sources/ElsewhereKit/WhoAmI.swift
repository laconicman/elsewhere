public import Foundation // URL is public API

/// One exit's egress identity, from Cloudflare's `/cdn-cgi/trace` key=value body —
/// the shape Domicile's `TraceResponse` carries (copied, not shared: 30 lines).
public struct Trace: Sendable, Equatable {
    public var ip: String
    public var loc: String
    public var colo: String?

    public init(ip: String, loc: String, colo: String? = nil) {
        self.ip = ip
        self.loc = loc
        self.colo = colo
    }
}

/// Parses `key=value` trace lines; nil without both `ip` and `loc` — a page that
/// answers something else is not an identity.
public enum TraceParser {
    public static func parse(_ text: String) -> Trace? {
        var ip: String?
        var loc: String?
        var colo: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "=", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let value = String(fields[1])
            switch fields[0] {
            case "ip": ip = value
            case "loc": loc = value
            case "colo": colo = value
            default: break
            }
        }
        guard let ip, let loc else { return nil }
        return Trace(ip: ip, loc: loc, colo: colo)
    }
}

/// `whoami`'s trace fetch: the trace endpoints through one exit, first URL then the
/// fallback — the last error is the one thrown.
public enum WhoAmI {
    /// Cloudflare's trace, by IP then by name (Domicile's `ExitProbe` pair).
    public static let defaultTraceURLs: [URL] = [
        URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
        URL(string: "https://cloudflare.com/cdn-cgi/trace")!,
    ]

    /// - Throws: `.fetch`/`.refused` from the last tried URL — earlier failures fall
    ///   through to the next URL.
    public static func trace(
        via route: Route,
        userAgent: String,
        traceURLs: [URL] = defaultTraceURLs,
        allowPrivate: Bool = false
    ) async throws(ElsewhereError) -> Trace {
        var lastError = ElsewhereError.fetch("no trace URL configured")
        for url in traceURLs {
            do {
                let result = try await Fetcher.fetch(
                    FetchRequest(
                        url: url, userAgent: userAgent, allowPrivate: allowPrivate),
                    via: route)
                let text = String(decoding: result.body, as: UTF8.self)
                if result.status == 200, let trace = TraceParser.parse(text) {
                    return trace
                }
                lastError = .fetch(
                    "trace endpoint answered HTTP \(result.status) with an unreadable body")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
