import Foundation
import Testing
@testable import ElsewhereKit

/// `DirectDNS.validate` — the entry contract (`https://<ip>/path` and nothing
/// else) and the rule that an echoed entry can never leak a credential: the
/// config file lives next to secrets, and this error lands on stderr.
@Suite("DirectDNS — validation and the scrubbed echo")
struct DirectDNSTests {
    /// A credentialed entry is refused outright — and even if it weren't, the
    /// echo goes through `redactUserinfo` + `scrubPatterns` first.
    @Test func aCredentialedEntryIsRefusedAndEchoesNothing() {
        do {
            try DirectDNS.validate(["https://user:secret@1.1.1.1/dns-query"])
            Issue.record("expected .config")
        } catch ElsewhereError.config(let message) {
            #expect(!message.contains("user"))
            #expect(!message.contains("secret"))
            #expect(message.contains("https://<ip>/path"))
        } catch { Issue.record("expected .config, got \(error)") }
    }

    /// An entry that fails the contract — or can't even parse — still echoes
    /// only scrubbed text: `redactUserinfo` drops `user:secret@`, the pattern
    /// net takes whole URLs and long key runs.
    @Test(arguments: [
        "vless://secret@example.invalid",
        "https://user:secret@[bad",
        "not a url at all, but 0123456789abcdef0123456789abcdef is here",
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
        try DirectDNS.validate(["https://1.1.1.1/dns-query", "https://[2620:fe::fe]/dns-query"])
    }
}
