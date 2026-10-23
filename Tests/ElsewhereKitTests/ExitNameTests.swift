import Testing
@testable import ElsewhereKit

/// DNS-label-shaped names — they become routing tags and CLI arguments; `direct` and
/// `env` are claimed by the implicit exits.
@Suite("ExitName — validation and reserved names")
struct ExitNameTests {
    @Test(arguments: ["moldova", "kz-2", "a", "0", String(repeating: "a", count: 32)])
    func acceptsValid(_ name: String) throws {
        try ExitName.validate(name)
    }

    @Test(arguments: [
        "Moldova", "my_exit", "a.b", "-x", "foo-",
        String(repeating: "a", count: 33),
        "direct", "env",
    ])
    func rejects(_ name: String) {
        #expect(throws: ElsewhereError.self) { try ExitName.validate(name) }
    }

    @Test func reservedNamesAreNamedInTheError() {
        #expect(throws: ElsewhereError.self) { try ExitName.validate("direct") }
        do {
            try ExitName.validate("env")
        } catch {
            #expect(error.errorDescription?.contains("env") == true)
        }
    }

    @Test func errorsNeverEchoTheArgument() {
        // A link pasted as the positional must not come back in the message — stderr
        // is the last surface a secret can reach.
        do {
            try ExitName.validate("vless://x@y")
            Issue.record("expected a throw")
        } catch ElsewhereError.exit(let message) {
            #expect(!message.contains("vless"))
        } catch {
            Issue.record("expected .exit, got \(error)")
        }
    }
}
