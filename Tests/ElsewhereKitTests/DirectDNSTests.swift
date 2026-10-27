import Foundation
import Testing
@testable import ElsewhereKit

/// `DirectDNS.validate` — the entry contract (`https://<ip>/path` and nothing
/// else), the clause that names the broken rule, and the rule that an echoed
/// entry can never leak a credential: the echo is `scheme://host[:port]` or a
/// scrubbed `…`, so path and query can carry a secret safely — the message
/// does not need them.
@Suite("DirectDNS — validation and the sanitized echo")
struct DirectDNSTests {
    /// A credentialed entry is refused and echoed sanitized — userinfo, path
    /// and query all gone — which looks valid, so the clause says why.
    /// The leading valid entry pins the `directDNS[1]` index.
    @Test func aCredentialedEntryIsRefusedNamedAndEchoedSanitized() {
        do {
            try DirectDNS.validate([
                "https://1.1.1.1/dns-query",
                "https://user:secret@1.1.1.1/dns-query",
            ])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("directDNS[1]"))
            #expect(message.contains("https://1.1.1.1"))
            #expect(message.contains("credentials are refused"))
            #expect(!message.contains("user"))
            #expect(!message.contains("secret"))
            #expect(!message.contains("dns-query"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// A secret in the tail stays out of the message — the echo is
    /// `scheme://host[:port]` and nothing more.
    @Test(arguments: [
        "https://1.1.1.1/dns-query?token=SECRET123456",
        "http://1.1.1.1/SECRET123456/dns-query",
    ])
    func aSecretInTheTailNeverEchoes(entry: String) {
        do {
            try DirectDNS.validate([entry])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(!message.contains("SECRET"))
            #expect(message.contains("https://1.1.1.1")
                || message.contains("http://1.1.1.1"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// Each broken rule names itself — the index plus the clause — so the
    /// entry's (possibly secret-bearing) tail is not needed to see why.
    @Test(arguments: [
        ("http://1.1.1.1/dns-query", "scheme must be https"),
        (
            "https://dns.google/dns-query",
            "host must be an IP literal — a hostname would need the system resolver to bootstrap"
        ),
        ("https://1.1.1.1/dns-query?dns=AA==", "query is refused"),
        ("https://1.1.1.1/dns-query#frag", "fragment is refused"),
        ("https://1.1.1.1", "path is missing"),
        ("https://1.1.1.1/", "path is missing"),
        ("https://user:secret@[bad", "is not a URL"),
    ])
    func eachRefusedRuleNamesItself(entry: String, clause: String) {
        do {
            try DirectDNS.validate([entry])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("directDNS[0]"))
            #expect(message.contains(clause))
            #expect(message.contains("must be https://<ip>/path"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// What does not parse goes through the pattern net alone — `scrubPatterns`
    /// takes whole URL-shaped tokens, credentials inside and all.
    @Test(arguments: [
        "https://user:secret@[bad",
        "vless://secret@ho{st",
    ])
    func anUnparseableEntryEchoesScrubbed(entry: String) {
        do {
            try DirectDNS.validate([entry])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(!message.contains("secret"))
            #expect(message.contains("…"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// The defaults and a hand-mixed list validate; only the contract breaks.
    @Test func theDefaultsValidate() throws {
        try DirectDNS.validate(DirectDNS.defaults)
        try DirectDNS.validate([
            "https://1.1.1.1/dns-query",
            "https://[2620:fe::fe]/dns-query",
        ])
    }
}
