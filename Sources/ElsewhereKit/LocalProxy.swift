/// The local system proxy's loopback port — INCY's `mixed` inbound. One named home:
/// `doctor`'s probe, the tunnel's port exclusions and `run`'s env all agree on it.
public enum LocalProxy {
    /// INCY listens on 127.0.0.1:10808 (verified by `lsof`, plan §1).
    public static let incyPort: UInt16 = 10808
}
