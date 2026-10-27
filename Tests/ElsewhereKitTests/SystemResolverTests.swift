import Foundation
import Testing
@testable import ElsewhereKit

/// `looksTunnelOwned` is pure — the SCDynamicStore read itself is covered only
/// by the live `elsewhere doctor` run (there is no loopback for it).
@Suite("SystemResolver — the tunnel-owned verdict")
struct SystemResolverTests {
    /// INCY's shape: a fake-IP server on the tunnel interface.
    @Test func aFakeIPServerOnUtunIsTunnelOwned() {
        #expect(
            SystemResolver.looksTunnelOwned(
                .init(servers: ["198.18.0.2"], interface: "utun4")))
    }

    /// Each side alone suffices — a tunnel interface, or a fake-IP answer range
    /// on an ordinary one (RFC 2544 /15, Class E /4).
    @Test(arguments: [
        SystemResolver.Snapshot(servers: ["192.168.1.1"], interface: "utun9"),
        SystemResolver.Snapshot(servers: ["192.168.1.1"], interface: "ipsec0"),
        SystemResolver.Snapshot(servers: ["192.168.1.1"], interface: "ppp0"),
        SystemResolver.Snapshot(servers: ["198.19.255.1"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["240.0.1.39"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["192.168.1.1", "198.18.0.2"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["198.18.0.2"], interface: nil),
    ])
    func oneSignalSuffices(_ snapshot: SystemResolver.Snapshot) {
        #expect(SystemResolver.looksTunnelOwned(snapshot))
    }

    @Test(arguments: [
        SystemResolver.Snapshot(servers: ["192.168.1.1"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["8.8.8.8"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["198.17.255.255"], interface: "en0"),
        SystemResolver.Snapshot(servers: ["239.255.255.255"], interface: "en0"),
        SystemResolver.Snapshot(servers: [], interface: "en0"),
        SystemResolver.Snapshot(servers: ["fe80::1"], interface: "en0"),
    ])
    func anOrdinaryResolverIsNot(_ snapshot: SystemResolver.Snapshot) {
        #expect(!SystemResolver.looksTunnelOwned(snapshot))
    }
}
