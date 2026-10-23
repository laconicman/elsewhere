import Foundation
import Testing
@testable import ElsewhereKit

/// Which exits resolve to engine lanes and which need no engine at all (A9); the `.auto`
/// unbound refusal (A8); `ExitSelection`'s name resolution. Engine-touching cases are
/// serialized — the Go runtime is one per process.
@Suite("TunnelSession — routes, no-engine proxy exits, auto refusal", .serialized, .temporaryDirectories)
struct TunnelSessionTests {
    private func config() -> ElsewhereConfig {
        ElsewhereConfig(exits: [
            "incy": .proxy(URL(string: "http://127.0.0.1:18080")!),
            "moldova": .link(Synthetic.link),
        ])
    }

    @Test func aProxyOnlySessionNeverStartsTheEngine() async throws {
        let supervisor = TunnelSupervisor()
        let session = try await TunnelSession.open(
            config: config(), exits: ["incy"], includeDirect: false,
            bindInterface: .auto, log: .silent, supervisor: supervisor)
        #expect(!(await supervisor.isUp))
        #expect(
            try await session.route(for: "incy")
                == .external(exit: "incy", url: URL(string: "http://127.0.0.1:18080")!))
    }

    @Test func autoWithNoInterfaceIsATunnelErrorNotAQuietUnbind() async {
        do {
            _ = try await TunnelSession.open(
                config: config(), exits: ["moldova"], includeDirect: false,
                bindInterface: .auto, log: .silent,
                interfaceResolver: { _ in nil })
            Issue.record("expected a throw")
        } catch ElsewhereError.tunnel(let message) {
            #expect(message.contains("refuses to start unbound"))
        } catch {
            Issue.record("expected .tunnel, got \(error)")
        }
    }

    @Test func anXrayExitStartsTheEngineAndRoutesInbound() async throws {
        let session = try await TunnelSession.open(
            config: config(), exits: ["moldova"], includeDirect: true,
            bindInterface: .none, log: .silent)
        guard case .inbound(let exit, let port) = try await session.route(for: "moldova")
        else {
            Issue.record("moldova did not route through an inbound")
            return
        }
        #expect(exit == "moldova")
        #expect(await LoopbackProbe.isListening(port: port))
        // The direct lane is built alongside — the builder always emits it.
        guard case .inbound = try await session.route(for: "direct") else {
            Issue.record("no direct lane alongside the exit")
            return
        }
        await session.close()
        #expect(!(await LoopbackProbe.isListening(port: port)))
    }

    @Test func unknownExitNamesAreExitErrors() async {
        do {
            _ = try await TunnelSession.open(
                config: config(), exits: ["ghost"], includeDirect: false,
                bindInterface: .none, log: .silent)
            Issue.record("expected a throw")
        } catch ElsewhereError.exit(let message) {
            #expect(message.contains("no exit named 'ghost'"))
        } catch {
            Issue.record("expected .exit, got \(error)")
        }
    }
}

@Suite("ExitSelection — the --exit/--direct/default triad")
struct ExitSelectionTests {
    private let config = ElsewhereConfig(
        default: "moldova",
        exits: [
            "moldova": .link(Synthetic.link),
            "incy": .proxy(URL(string: "http://127.0.0.1:10808")!),
        ])

    @Test func resolvesEachCase() throws {
        #expect(try ExitSelection.direct.resolve(in: config) == "direct")
        #expect(try ExitSelection.named("incy").resolve(in: config) == "incy")
        #expect(try ExitSelection.default.resolve(in: config) == "moldova")
    }

    @Test func missingNamesAndMissingDefaultsThrow() {
        #expect(throws: ElsewhereError.self) {
            try ExitSelection.named("ghost").resolve(in: config)
        }
        #expect(throws: ElsewhereError.self) {
            try ExitSelection.default.resolve(in: ElsewhereConfig())
        }
    }
}
