import Network
import Synchronization

/// Resolves `BindInterface` to an interface name (§3.3). Binding every outbound's sockets
/// to the physical interface is what makes `--direct` direct while a system tunnel owns
/// the default route — spike S3 proved it against the live INCY tunnel (`en0` egress
/// differed from the tunnel's).
///
/// The programmatic equivalent of the spike's hand-checked `en0`. The owner's
/// `NetworkPathMonitor` package exposes interface *types* only, not names, so this uses
/// `NWPathMonitor` directly (a one-line upstream enhancement later, not a dependency now).
public enum InterfaceResolver {
    /// The first physical interface (wifi/wired/cellular) on the current path, or nil.
    ///
    /// `prohibitedInterfaceTypes` keeps `.other` (utun* — a system VPN's interface) and
    /// `.loopback` out of the path, so the answer stays physical while a tunnel owns the
    /// default route. One-shot: the monitor is cancelled on the first path update, or on
    /// `timeout` with nil.
    public static func physicalInterfaceName(timeout: Duration = .seconds(2)) async -> String? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
            let resumed = Mutex(false)
            let finish: @Sendable (String?) -> Void = { name in
                let first = resumed.withLock { seen in
                    if seen { return false }
                    seen = true
                    return true
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: name)
            }
            monitor.pathUpdateHandler = { path in
                finish(path.availableInterfaces.first {
                    [.wifi, .wiredEthernet, .cellular].contains($0.type)
                }?.name)
            }
            monitor.start(queue: .global())
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    /// `.none` → nil (outbounds ride the system path); `.named` → the pinned name;
    /// `.auto` → the physical interface. Whether nil is an error is the caller's call —
    /// `doctor` warns, the tunnel may proceed unbound.
    public static func resolve(_ bind: BindInterface) async -> String? {
        switch bind {
        case .none: nil
        case .named(let name): name
        case .auto: await physicalInterfaceName()
        }
    }
}
