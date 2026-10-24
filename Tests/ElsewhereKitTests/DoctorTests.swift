import Foundation
import Synchronization
import Testing
import XrayCore
@testable import ElsewhereKit

/// End-to-end doctor: a temp config, a fake INCY on a real loopback listener, and the
/// generated config validated by the engine. Serialized — the Go runtime is one per
/// process. No check may ever print a secret: the final assertion greps the rendered
/// lines for them.
@Suite(
    "Doctor — verdicts, ordering, no secrets",
    .serialized, .engineGate, .temporaryDirectories)
struct DoctorTests {
    private func store() -> ConfigStore {
        ConfigStore(url: temporaryDirectory().appending(path: "elsewhere/config.json"))
    }

    @Test func healthySetupReportsOk() async throws {
        let incy = try EchoServer()
        let incyPort = try await incy.start()
        defer { incy.stop() }
        let closed = try EchoServer() // started, stopped: its port stays closed
        let closedPort = try await closed.start()
        closed.stop()

        let store = store()
        try store.save(ElsewhereConfig(exits: [
            "moldova": .link(Synthetic.link),
            "incy": .proxy(URL(string: "http://127.0.0.1:\(incyPort)")!),
        ]))

        let exclusions = Mutex<[UInt16]>([])
        let checks = await Doctor.run(
            store: store, environment: [:], localProxyPort: closedPort,
            portCandidates: { count, excluding in
                exclusions.withLock { $0 = excluding }
                return try await XrayCore.shared.freePorts(count, excluding: Set(excluding))
            })
        #expect(checks.count == 9)
        #expect(!checks.contains(where: { $0.verdict == .failure }))

        let names = checks.map(\.name)
        #expect(names.prefix(2) == ["engine", "config"])
        #expect(names.contains("exit moldova") && names.contains("exit incy"))
        #expect(names.suffix(4) == ["interface", "ports", "xray config", "local proxy"])

        #expect(checks["exit moldova"]?.verdict == .ok)
        #expect(checks["exit moldova"]?.detail.contains("proxy.example.com") == true)
        #expect(checks["exit incy"]?.verdict == .ok)
        #expect(checks["exit incy"]?.detail.contains("listening") == true)
        #expect(checks["xray config"]?.verdict == .ok)
        #expect(checks["local proxy"]?.detail.contains("nothing") == true)

        // A loopback proxy exit's own port must be out of the candidate pool —
        // an inbound re-issued on it would collide at run time.
        #expect(exclusions.withLock { $0 }.contains(incyPort))
        #expect(exclusions.withLock { $0 }.contains(closedPort))

        let rendered = Doctor.lines(checks).joined(separator: "\n")
        for secret in Synthetic.secrets + [Synthetic.link] {
            #expect(!rendered.contains(secret), "leaked \(secret)")
        }
    }

    @Test func missingConfigIsAFailureButLinesAreRendered() async {
        let checks = await Doctor.run(store: store(), environment: [:], localProxyPort: 9)
        #expect(checks["config"]?.verdict == .failure)
        #expect(checks["engine"]?.verdict == .ok)
        // The battery is fixed: the row reports the skip rather than vanishing.
        #expect(checks["xray config"]?.verdict == .info)
        #expect(checks["xray config"]?.detail == "skipped — no resolvable exits")
        #expect(!Doctor.lines(checks).isEmpty)
    }

    @Test func anOutboundWithoutAProtocolIsAFailure() async throws {
        let store = store()
        try store.save(ElsewhereConfig(exits: [
            "shapeless": .xray(.object(["settings": .object([:])]))
        ]))
        let checks = await Doctor.run(store: store, environment: [:], localProxyPort: 9)
        #expect(checks["exit shapeless"]?.verdict == .failure)
        #expect(checks["exit shapeless"]?.detail == "invalid outbound (no protocol)")
    }

    @Test func aMissingNamedInterfaceIsAWarning() async throws {
        let store = store()
        var config = ElsewhereConfig(exits: ["moldova": .link(Synthetic.link)])
        config.bindInterface = .named("nonexistent0")
        try store.save(config)
        let checks = await Doctor.run(store: store, environment: [:], localProxyPort: 9)
        #expect(checks["interface"]?.verdict == .warning)
        #expect(
            checks["interface"]?.detail == "interface 'nonexistent0' not found on this Mac")
    }

    @Test func aListenerOnTheLocalProxyPortIsNamedIncy() async throws {
        let incy = try EchoServer()
        let port = try await incy.start()
        defer { incy.stop() }
        let checks = await Doctor.run(store: store(), environment: [:], localProxyPort: port)
        #expect(checks["local proxy"]?.verdict == .info)
        #expect(checks["local proxy"]?.detail.contains("INCY?") == true)
    }

    @Test func envLinkConfigReportsInfo() async throws {
        let checks = await Doctor.run(
            store: store(), environment: ["ELSEWHERE_LINK": Synthetic.link], localProxyPort: 9)
        #expect(checks["config"]?.verdict == .info)
        // The synthesized `env` exit is both present and the default.
        #expect(checks["exit env"]?.verdict == .ok)
        #expect(checks["default"]?.verdict == .ok)
    }

    @Test func anUnresolvedAutoInterfaceIsAFailure() async throws {
        let store = store()
        try store.save(ElsewhereConfig(exits: ["moldova": .link(Synthetic.link)]))
        let checks = await Doctor.run(
            store: store, environment: [:], localProxyPort: 9,
            interfaceResolver: { _ in nil })
        #expect(checks["interface"]?.verdict == .failure)
        #expect(checks["interface"]?.detail.contains("refuses to start unbound") == true)
        // The config test still runs — unbound, and it says so.
        #expect(checks["xray config"]?.verdict == .ok)
        #expect(
            checks["xray config"]?.detail.contains("validated unbound — interface unresolved")
                == true)
    }

    @Test func linesPadTheColumns() {
        let line = Doctor.lines([.init(name: "engine", verdict: .ok, detail: "X")])
        #expect(line == ["[ok]   engine  X"])
        let failures = Doctor.lines([.init(name: "x", verdict: .failure, detail: "y")])
        #expect(failures == ["[FAIL] x  y"])
    }
}

private extension [Doctor.Check] {
    subscript(name: String) -> Doctor.Check? { first { $0.name == name } }
}
