import Foundation
import Testing
@testable import ElsewhereKit

/// End-to-end doctor: a temp config, a fake INCY on a real loopback listener, and the
/// generated config validated by the engine. Serialized — the Go runtime is one per
/// process. No check may ever print a secret: the final assertion greps the rendered
/// lines for them.
@Suite("Doctor — verdicts, ordering, no secrets", .serialized, .temporaryDirectories)
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

        let checks = await Doctor.run(store: store, environment: [:], localProxyPort: closedPort)
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

        let rendered = Doctor.lines(checks).joined(separator: "\n")
        for secret in Synthetic.secrets + [Synthetic.link] {
            #expect(!rendered.contains(secret), "leaked \(secret)")
        }
    }

    @Test func missingConfigIsAFailureButLinesAreRendered() async {
        let checks = await Doctor.run(store: store(), environment: [:], localProxyPort: 9)
        #expect(checks["config"]?.verdict == .failure)
        #expect(checks["engine"]?.verdict == .ok)
        #expect(!Doctor.lines(checks).isEmpty)
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
