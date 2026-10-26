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
        #expect(checks.count == 10)
        #expect(!checks.contains(where: { $0.verdict == .failure }))

        let names = checks.map(\.name)
        #expect(names.prefix(2) == ["engine", "config"])
        #expect(names.contains("exit moldova") && names.contains("exit incy"))
        #expect(
            names.suffix(5)
                == ["interface", "resolver", "ports", "xray config", "local proxy"])

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
        // The battery is fixed: with no exits the check validates the
        // direct-only config `fetch --direct` would build — it must not skip.
        #expect(checks["xray config"]?.verdict == .ok)
        #expect(checks["xray config"]?.detail == "assembles and validates (1 inbounds)")
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

    /// The direct-only path is real — `fetch --direct` with zero exits builds
    /// exactly this config — so a bad `directDNS` fails the `xray config` row
    /// here, not first at tunnel start.
    @Test func anInvalidDirectDNSFailsTheXrayConfigCheck() async throws {
        let store = store()
        try store.save(ElsewhereConfig(directDNS: []))
        let checks = await Doctor.run(
            store: store, environment: [:], localProxyPort: 9,
            interfaceResolver: { _ in "en0" })
        #expect(checks["xray config"]?.verdict == .failure)
        #expect(checks["xray config"]?.detail.contains("directDNS") == true)
    }

    /// A tunnel-owned resolver is a warning that names where `direct` differs:
    /// the injected snapshot is the INCY shape (fake-IP server on utun).
    @Test func aTunnelOwnedResolverWarns() async {
        let checks = await Doctor.run(
            store: store(), environment: [:], localProxyPort: 9,
            systemResolver: {
                .init(servers: ["198.18.0.2"], interface: "utun4")
            })
        #expect(checks["resolver"]?.verdict == .warning)
        #expect(
            checks["resolver"]?.detail.contains("198.18.0.2 on utun4") == true)
        #expect(checks["resolver"]?.detail.contains("tunnel-owned") == true)
    }

    @Test func anOrdinaryResolverIsOk() async {
        let checks = await Doctor.run(
            store: store(), environment: [:], localProxyPort: 9,
            systemResolver: { .init(servers: ["192.168.1.1"], interface: "en0") })
        #expect(checks["resolver"]?.verdict == .ok)
        #expect(checks["resolver"]?.detail == "system resolver 192.168.1.1 on en0")
    }

    @Test func noResolverIsInfo() async {
        let checks = await Doctor.run(
            store: store(), environment: [:], localProxyPort: 9,
            systemResolver: { nil })
        #expect(checks["resolver"]?.verdict == .info)
        #expect(checks["resolver"]?.detail == "no system resolver configured")
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
