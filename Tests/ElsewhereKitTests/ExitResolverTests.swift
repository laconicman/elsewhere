import Foundation
import Testing
import XrayCore
@testable import ElsewhereKit

/// Link → engine → flat outbound, and the proof that the flat shape splices into a full
/// Xray config. Serialized: the Go runtime is one per process. Engine calls here are
/// pure conversion and loopback-free validation — `test` binds nothing (consult C5 §3).
@Suite("ExitResolver — engine conversion and the splice proof", .serialized, .engineGate)
struct ExitResolverTests {
    @Test func syntheticLinkYieldsTheFlatOutbound() async throws {
        let outbound = try #require(
            try await ExitResolver.outbound(for: .link(Synthetic.link), named: "spike"))
        #expect(outbound["protocol"] == .string("vless"))
        let stream = try #require(outbound["streamSettings"]?.objectValue)
        #expect(stream["network"] == .string("xhttp"))
        #expect(stream["security"] == .string("reality"))
        let settings = try #require(outbound["settings"]?.objectValue)
        #expect(settings["address"] == .string("proxy.example.com"))
        #expect(settings["port"] == .number(8443))
    }

    @Test func malformedLinkIsAnEngineError() async {
        do {
            _ = try await ExitResolver.outbound(for: .link("vless://not-a-link"), named: "x")
            Issue.record("expected a throw")
        } catch ElsewhereError.engine(let message) {
            // The engine's message is scrubbed — the link it echoes must not appear.
            #expect(!message.contains("vless://not-a-link"))
        } catch {
            Issue.record("expected .engine, got \(error)")
        }
    }

    @Test func wrappedXrayObjectIsUnwrapped() async throws {
        let inner = JSONValue.object(["protocol": .string("vless")])
        #expect(
            try await ExitResolver.outbound(
                for: .xray(.object(["outbounds": .array([inner])])), named: "w") == inner)
        #expect(
            try await ExitResolver.outbound(
                for: .xray(.object(["protocol": .string("vless")])), named: "w")
                == .object(["protocol": .string("vless")]))
    }

    @Test func multiOutboundWrapperIsRejected() async {
        do {
            _ = try await ExitResolver.outbound(
                for: .xray(.object(["outbounds": .array([.object([:]), .object([:])])])),
                named: "w")
            Issue.record("expected a throw")
        } catch ElsewhereError.exit {
            // expected — a wrapper that is not exactly one outbound is not an outbound
        } catch {
            Issue.record("expected .exit, got \(error)")
        }
    }

    @Test func proxyNeedsNoEngine() async throws {
        #expect(
            try await ExitResolver.outbound(
                for: .proxy(URL(string: "http://127.0.0.1:10808")!), named: "incy") == nil)
    }

    /// The plan's splice proof (C5 §1–2): the flat outbound libXray emits drops into a
    /// full generated config and the engine's own validator takes it — this is also why
    /// `doctor` can claim a config "works" without starting anything.
    @Test func resolvedOutboundSplicesIntoATestableConfig() async throws {
        let outbound = try #require(
            try await ExitResolver.outbound(for: .link(Synthetic.link), named: "moldova"))
        let ports = try await XrayCore.shared.freePorts(2)
        let (configJSON, _) = try XrayConfigBuilder.build(
            exits: [("moldova", outbound)],
            ports: ["moldova": ports[0]],
            directPort: ports[1],
            bindInterface: "en0")
        try await XrayCore.shared.test(configJSON: configJSON)
    }
}
