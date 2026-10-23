import Foundation
import Testing
@testable import ElsewhereKit

/// TCP probe on 127.0.0.1: true for a real listener, false (fast, connection refused)
/// for a closed port.
@Suite("LoopbackProbe — listening vs refused")
struct LoopbackProbeTests {
    @Test func trueForAListener() async throws {
        let server = try EchoServer()
        let port = try await server.start()
        defer { server.stop() }
        #expect(await LoopbackProbe.isListening(port: port))
    }

    @Test func falseForAClosedPort() async throws {
        // A cancelled NWListener's socket can still accept for a beat, so borrow a port
        // and close it ourselves: after close(), loopback refuses promptly.
        #expect(!(await LoopbackProbe.isListening(port: closedPort(), timeout: .milliseconds(1500))))
    }

    @Test func anIPv6ListenerIsProbed() async throws {
        // The proxy URL's host is the probe's host — a ::1-only listener must not read
        // as absent. Machines without a working IPv6 loopback exist: skip then.
        let server: EchoServer
        do {
            server = try EchoServer(host: "::1")
        } catch {
            Issue.record("IPv6 loopback unavailable on this machine: \(error) — skipped")
            return
        }
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            Issue.record("IPv6 loopback listener failed to start: \(error) — skipped")
            return
        }
        defer { server.stop() }
        #expect(await LoopbackProbe.isListening(host: "::1", port: port))
    }

    @Test(arguments: ["127.0.0.1", "127.0.0.2", "127.255.255.254", "LOCALHOST.", "localhost", "::1", "[::1]"])
    func loopbackHosts(_ host: String) {
        #expect(LoopbackProbe.isLoopbackHost(host))
    }

    @Test(arguments: ["10.0.0.1", "example.com", "127.0.0.256", "127.0.0", "::2"])
    func nonLoopbackHosts(_ host: String) {
        #expect(!LoopbackProbe.isLoopbackHost(host))
    }

    /// A port nothing listens on: bind to 0, read the assigned port, close.
    private func closedPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0)
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: out.sin_port)
    }
}
