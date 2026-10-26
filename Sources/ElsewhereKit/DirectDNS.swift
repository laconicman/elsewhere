import Foundation
import Network // IPv4Address/IPv6Address — internal to the module (rule 1)

/// The DoH servers the `direct` lane resolves through — the generated config's
/// `dns.servers`, in order. The lookups they answer are the freedom outbound's:
/// Xray's dns module dials each `https://` server *through the router* (a
/// `https+local://` DOHL URL would bypass routing and use the system dialer —
/// `app/dns/nameserver.go` L53–63 at v26.10.21), the routing table steers those
/// sessions onto `out:direct`, and `ForceIPv4v6` on that outbound's sockopt makes
/// a failed lookup a failed fetch rather than a silent fall-through to the
/// system resolver (rule 5; `transport/internet/dialer.go` L250–281 — `UseIP*`
/// falls through, `ForceIP*` does not).
///
/// Order: Cloudflare, Google, Quad9 — an IPv4 each, then one IPv6 each — and
/// Yandex (77.88.8.8) LAST: the owner's last resort for .ru zones that refuse
/// foreign resolvers. Checked live 2026-10-26 over `en0`: every URL answered a
/// DoH query with HTTP 200 on a certificate that verifies for the IP literal.
public enum DirectDNS {
    /// The servers used when the config's `directDNS` is unset.
    public static let defaults: [String] = [
        "https://1.1.1.1/dns-query",
        "https://8.8.8.8/dns-query",
        "https://9.9.9.9/dns-query",
        "https://[2606:4700:4700::1111]/dns-query",
        "https://[2001:4860:4860::8888]/dns-query",
        "https://[2620:fe::fe]/dns-query",
        "https://77.88.8.8/dns-query",
    ]

    /// Every entry must be `https://<ip>/path` and nothing else — a *hostname*
    /// DoH server would need the system resolver to bootstrap, the very resolver
    /// `direct` exists to avoid; an IP literal needs none
    /// (`app/dns/nameserver_doh.go` L133–148 at v26.10.21). The scheme is exactly
    /// `https` — `https+local://` dials the system resolver directly — and
    /// userinfo is refused: this file holds secrets, so an entry is echoed only
    /// sanitized — `Redactor.redact(url:)` when it parses (userinfo gone,
    /// scheme/host/path kept — what the user needs to see), `scrubPatterns`
    /// when it does not. Query and fragment are refused too, and the path must
    /// be more than `/` — the contract is `https://<ip>/path`, nothing else. An
    /// empty list fails too — and must: an empty `dns.servers` would make Xray
    /// add a `localhost` system-resolver client (`app/dns/dns.go` L168–170),
    /// the very resolver `direct` exists to avoid.
    /// - Throws: `.config` naming the entry's index and its sanitized form.
    public static func validate(_ servers: [String]) throws(ElsewhereError) {
        guard !servers.isEmpty else {
            throw .config(
                "directDNS is empty — the direct lane needs at least one DoH server")
        }
        for (index, entry) in servers.enumerated() {
            let url = URL(string: entry)
            let shown = url.map(Redactor.redact(url:)) ?? Redactor.scrubPatterns(entry)
            let credentialed = url?.user != nil || url?.password != nil
            guard let url,
                url.scheme == "https",
                !credentialed,
                let host = url.host(percentEncoded: false),
                IPv4Address(host) != nil || IPv6Address(host) != nil,
                url.path().count > 1,
                url.query == nil, url.fragment == nil
            else {
                throw .config(
                    "directDNS[\(index)] '\(shown)' must be https://<ip>/path — "
                        + "a hostname would need the system resolver to bootstrap"
                        + (credentialed ? " (credentials are refused)" : ""))
            }
        }
    }
}
