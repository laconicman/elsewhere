public import Foundation // URL is public API
import Darwin

/// The private-address guard (§5.9): `fetch` refuses private/local destinations unless
/// `--allow-private` is passed — the tool reaches everywhere the tunnel does, and a
/// wrong URL must never be the way something reads `169.254.169.254`.
///
/// Hostnames are deliberately NOT resolved — the exit resolves them (a hostname's
/// address depends on *where* it is resolved, and resolving locally would answer the
/// wrong question). Only what we can judge is refused: `localhost`/`*.localhost`
/// (one optional trailing dot), and IP literals in the ranges below — including
/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`), judged by its embedded v4. The reference MCP
/// fetch server has the same shape.
public enum PrivateAddressGuard {
    /// - Throws: `.usage` for a non-http(s) scheme or a missing host; `.refused` for a
    ///   private/local destination when `allowPrivate` is false.
    public static func check(_ url: URL, allowPrivate: Bool) throws(ElsewhereError) {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: false), !host.isEmpty
        else { throw .usage("only http and https URLs are fetched") }
        guard !allowPrivate else { return }
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost")
            || isPrivateIPv4(name) || isPrivateIPv6(name)
        {
            throw .refused(
                "destination \(name) is a private or local address; "
                    + "pass --allow-private if you mean it")
        }
    }

    /// A dotted-quad in a non-public range: 0/8, 10/8, 127/8, 169.254/16, 172.16/12,
    /// 192.168/16, 100.64/10, and ≥224 (multicast through broadcast, 255.255.255.255).
    private static func isPrivateIPv4(_ name: String) -> Bool {
        guard let bytes = ipv4Octets(name) else { return false }
        switch bytes[0] {
        case 0, 10, 127: return true
        case 100: return bytes[1] & 0xC0 == 0x40 // 100.64.0.0/10
        case 169: return bytes[1] == 254
        case 172: return (16...31).contains(bytes[1])
        case 192: return bytes[1] == 168
        default: return bytes[0] >= 224
        }
    }

    /// Strict `inet_pton` — partial quads like `127.1` are not judged (they are not
    /// four-octet literals; the exit's resolver decides them).
    private static func ipv4Octets(_ name: String) -> [UInt8]? {
        var address = in_addr()
        guard name.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    /// `::`, `::1`, `fc00::/7` (ULA), `fe80::/10` (link-local, includes deprecated
    /// site-local `fec0`), and `::ffff:a.b.c.d` — the embedded v4 judged by the same
    /// ranges. Brackets are stripped (URL.host already does; cheap insurance).
    private static func isPrivateIPv6(_ name: String) -> Bool {
        var text = name
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        var address = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return true } // ::
        if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }
        if bytes[0] & 0xFE == 0xFC { return true } // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true } // fe80::/10
        // ::ffff:a.b.c.d — ten zero bytes, ff ff, then the v4 octets.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let embedded = bytes[12...15].map(String.init).joined(separator: ".")
            return isPrivateIPv4(embedded)
        }
        return false
    }
}
