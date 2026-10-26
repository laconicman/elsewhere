import Foundation
import Testing
@testable import ElsewhereKit

/// `DirectDNS.validate` — the entry contract (`https://<ip>/path` and nothing
/// else) and the rule that an echoed entry can never leak a credential while
/// staying locatable: the config file lives next to secrets, and this error
/// lands on stderr.
@Suite("DirectDNS — validation and the sanitized echo")
struct DirectDNSTests {
    /// A credentialed entry is refused and echoed sanitized — userinfo gone,
    /// scheme/host/path kept — which looks valid, so the message says why.
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
            #expect(message.contains("https://1.1.1.1/dns-query"))
            #expect(message.contains("credentials are refused"))
            #expect(!message.contains("user"))
            #expect(!message.contains("secret"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// A typo'd scheme echoes the entry itself — `http://` is not secret-shaped.
    @Test func aTypoEchoesTheEntryAndItsIndex() {
        do {
            try DirectDNS.validate([
                "https://1.1.1.1/dns-query",
                "http://1.1.1.1/dns-query",
            ])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("directDNS[1]"))
            #expect(message.contains("http://1.1.1.1/dns-query"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// What does not parse goes through the pattern net alone — `scrubPatterns`
    /// takes whole URL-shaped tokens, credentials inside and all. (Note:
    /// `URL(string:)` percent-encodes spaces, so "not a url" still parses.)
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
