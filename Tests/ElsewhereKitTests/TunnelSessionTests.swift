import Foundation
import Testing
import XrayCore
@testable import ElsewhereKit

/// Which exits resolve to engine lanes and which need no engine at all (A9); the `.auto`
/// unbound refusal (A8); `ExitSelection`'s name resolution. Engine-touching cases are
/// serialized — the Go runtime is one per process.
@Suite(
    "TunnelSession — routes, no-engine proxy exits, auto refusal",
    .serialized, .engineGate, .temporaryDirectories)
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
        // `includeDirect: true` — the direct lane is here because it was asked for.
        guard case .inbound = try await session.route(for: "direct") else {
            Issue.record("no direct lane alongside the exit")
            return
        }
        await session.close()
        #expect(!(await LoopbackProbe.isListening(port: port)))
    }

    /// A9 in the lanes themselves: a session opened for `moldova` alone carries no
    /// `direct` route — and a `--direct` session carries only `direct`.
    @Test func lanesAreOnlyWhatTheCallNeeds() async throws {
        let exitOnly = try await TunnelSession.open(
            config: config(), exits: ["moldova"], includeDirect: false,
            bindInterface: .none, log: .silent)
        do {
            _ = try await exitOnly.route(for: "direct")
            Issue.record("a moldova-only session routed 'direct'")
        } catch is ElsewhereError {
        }
        await exitOnly.close()

        let directOnly = try await TunnelSession.open(
            config: config(), exits: [], includeDirect: true,
            bindInterface: .none, log: .silent)
        guard case .inbound = try await directOnly.route(for: "direct") else {
            Issue.record("no direct lane in a direct-only session")
            return
        }
        do {
            _ = try await directOnly.route(for: "moldova")
            Issue.record("a direct-only session routed 'moldova'")
        } catch is ElsewhereError {
        }
        await directOnly.close()
    }

    /// Devin #2: a broken exit is isolated — `open` succeeds, the healthy route
    /// works, the broken one rethrows its recorded error, and with nothing valid
    /// for the engine, none was started.
    @Test func aBrokenExitIsIsolatedToItsRoute() async throws {
        let supervisor = TunnelSupervisor()
        let config = ElsewhereConfig(exits: [
            "broken": .link("vless://not-a-real-link"),
            "via": .proxy(URL(string: "http://127.0.0.1:18080")!),
        ])
        let session = try await TunnelSession.open(
            config: config, exits: ["broken", "via"], includeDirect: false,
            bindInterface: .none, log: .silent, supervisor: supervisor)
        guard case .external = try await session.route(for: "via") else {
            Issue.record("the proxy exit lost its route to a broken sibling")
            return
        }
        do {
            _ = try await session.route(for: "broken")
            Issue.record("the broken exit routed")
        } catch {
            switch error {
            case .engine, .exit: break
            default: Issue.record("expected .engine/.exit, got \(error)")
            }
        }
        #expect(!(await supervisor.isUp))
        #expect(!(await XrayCore.shared.isRunning))
        await session.close()
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
        // `--exit direct` names the lane — never a stored exit.
        #expect(try ExitSelection.named("direct").resolve(in: config) == "direct")
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
