import Darwin // if_indextoname(3)
import Foundation
import Network // IPv4Address — internal to the module (rule 1)
import SystemConfiguration // SCDynamicStore — internal too, never public API

/// The system resolver as the OS reports it — `State:/Network/Global/DNS` from
/// the SCDynamicStore: the DNS server addresses and the interface they ride.
/// `doctor` reads it once per run to warn when the resolver is tunnel-owned —
/// the fake-IP style resolver `--direct` exists to work around (TD-4): such a
/// resolver returns addresses that are only routable *through* the tunnel, so
/// every tool that follows the system path quietly rides the VPN.
public enum SystemResolver {
    /// One read of the global DNS state.
    public struct Snapshot: Sendable, Equatable {
        /// `ServerAddresses` — the resolver IPs, in order.
        public var servers: [String]
        /// The interface the resolver rides, named via `if_indextoname(3)`;
        /// `nil` when the store reports no `__IF_INDEX__`.
        public var interface: String?

        public init(servers: [String], interface: String?) {
            self.servers = servers
            self.interface = interface
        }
    }

    /// The live global DNS state, or `nil` when the SCDynamicStore key is absent
    /// (no resolver configured at all).
    public static func snapshot() -> Snapshot? {
        guard let dictionary = SCDynamicStoreCopyValue(
            nil, "State:/Network/Global/DNS" as CFString
        ) as? [String: Any] else { return nil }
        let servers = dictionary["ServerAddresses"] as? [String] ?? []
        var interface: String?
        // Darwin's `if_indextoname(3)` writes into a caller buffer; nil return
        // means the index names nothing. `String(cString:)` on a [CChar] warns
        // under Swift 6.4 — the prefix/map decode is the current spelling.
        if let index = dictionary["__IF_INDEX__"] as? Int, index > 0 {
            var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(UInt32(index), &buffer) != nil {
                interface = String(
                    decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
            }
        }
        return Snapshot(servers: servers, interface: interface)
    }

    /// Interface-name prefixes that only a tunnel or dial-up owns.
    static let tunnelInterfacePrefixes = ["utun", "ipsec", "ppp"]

    /// The ranges a tunnel's fake answers come from, as (base, prefix bits):
    /// 198.18.0.0/15 — the RFC 2544 benchmarking range fake-IP resolvers answer
    /// from — and 240.0.0.0/4 — Class E space tunnels park placeholder
    /// addresses in, being unroutable by definition.
    static let fakeIPRanges: [(base: UInt32, prefixBits: Int)] = [
        (0xC612_0000, 15), // 198.18.0.0/15
        (0xF000_0000, 4), // 240.0.0.0/4
    ]

    /// True when the resolver looks like it belongs to a tunnel: the interface
    /// is a `utun*`/`ipsec*`/`ppp*` device, or a server address falls inside
    /// ``fakeIPRanges``.
    public static func looksTunnelOwned(_ snapshot: Snapshot) -> Bool {
        if let interface = snapshot.interface,
            tunnelInterfacePrefixes.contains(where: { interface.hasPrefix($0) })
        { return true }
        return snapshot.servers.contains { server in
            guard let address = IPv4Address(server) else { return false }
            var value = UInt32(0)
            for byte in address.rawValue { value = value << 8 | UInt32(byte) }
            return fakeIPRanges.contains { range in
                let shift = 32 - range.prefixBits
                return value >> shift == range.base >> shift
            }
        }
    }
}
