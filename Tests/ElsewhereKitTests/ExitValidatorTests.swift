import Foundation
import Testing
@testable import ElsewhereKit

/// The `exits add` gate: engine validation before save, and the stored shape is what
/// `exits list` summarizes — an `xray` wrapper is stored unwrapped. Serialized: the Go
/// runtime is one per process; `test` binds nothing (C5 §3).
@Suite("ExitValidator — engine-checked at add, stored unwrapped", .serialized, .engineGate)
struct ExitValidatorTests {
    @Test func syntheticLinkValidatesAndStaysALink() async throws {
        let stored = try await ExitValidator.validate(.link(Synthetic.link), named: "moldova")
        #expect(stored == .link(Synthetic.link))
    }

    @Test func unknownProtocolIsAnEngineErrorAtAdd() async {
        do {
            _ = try await ExitValidator.validate(
                .xray(.object(["protocol": .string("nonexistent")])), named: "bad")
            Issue.record("expected a throw")
        } catch ElsewhereError.engine(let message) {
            // Scrubbed — an engine message can echo config text back.
            for secret in Synthetic.secrets {
                #expect(!message.contains(secret))
            }
        } catch {
            Issue.record("expected .engine, got \(error)")
        }
    }

    @Test func aCredentialUnderAnUnknownKeyStaysOutOfTheError() async {
        // `shape` is in neither secretKeys nor publicKeys — an 8-char credential would
        // have survived pattern-scrubbing alone; the inverted enumeration covers it.
        do {
            _ = try await ExitValidator.validate(
                .xray(.object([
                    "protocol": .string("nonexistent"),
                    "settings": .object(["shape": .string("abcdefgh")]),
                ])), named: "bad")
            Issue.record("expected a throw")
        } catch ElsewhereError.engine(let message) {
            #expect(!message.contains("abcdefgh"))
        } catch {
            Issue.record("expected .engine, got \(error)")
        }
    }

    @Test func wrappedOutboundIsStoredUnwrapped() async throws {
        let inner = try RedactorTests.json(RedactorTests.flatOutbound)
        let stored = try await ExitValidator.validate(
            .xray(.object(["outbounds": .array([inner])])), named: "w")
        #expect(stored == .xray(inner))
        // What `exits list` prints for the stored value — the inner protocol, read out.
        #expect(Redactor.summary(of: stored) == "xray vless → proxy.example.com:8443")
    }

    /// `exits add --xray whole-client-config.json`: the engine validates the extracted
    /// proxy and only that outbound is stored — never the inbounds, routing or dns.
    @Test func aClientConfigIsStoredAsItsProxyOutbound() async throws {
        let proxy = try RedactorTests.json(RedactorTests.flatOutbound)
        let config = JSONValue.object([
            "inbounds": .array([.object(["protocol": .string("mixed"), "port": .number(10808)])]),
            "outbounds": .array([
                proxy,
                .object(["tag": .string("direct"), "protocol": .string("freedom")]),
                .object(["tag": .string("block"), "protocol": .string("blackhole")]),
                .object(["tag": .string("dns-out"), "protocol": .string("dns")]),
            ]),
        ])
        let stored = try await ExitValidator.validate(.xray(config), named: "rugos")
        #expect(stored == .xray(proxy))
    }

    @Test func aHandEditedWrapperStillSummarizes() async throws {
        // `singleOutbound` in summary: a file edited past `exits add` lists correctly.
        let inner = try RedactorTests.json(RedactorTests.flatOutbound)
        let wrapped = Exit.xray(.object(["outbounds": .array([inner])]))
        #expect(Redactor.summary(of: wrapped) == "xray vless → proxy.example.com:8443")
    }
}
