import Darwin
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
        // The handler captures finish; finish captures the monitor; the monitor retains
        // its handler — a cycle that would outlive the call, so finish nils it. The box
        // keeps finish reachable from onCancel: a cancelled caller resumes at once
        // instead of riding out the timeout. The timeout Task keeps burning its sleep
        // after an early finish — bounded waste, harmless.
        let finishBox = Mutex<(@Sendable (String?) -> Void)?>(nil)
        return await withTaskCancellationHandler {
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
                    finishBox.withLock { $0 = nil }
                    monitor.cancel()
                    monitor.pathUpdateHandler = nil
                    continuation.resume(returning: name)
                }
                finishBox.withLock { $0 = finish }
                monitor.pathUpdateHandler = { path in
                    finish(path.availableInterfaces.first {
                        [.wifi, .wiredEthernet, .cellular].contains($0.type)
                    }?.name)
                }
                // Cancellation can land before the box was filled — onCancel then saw
                // nil and missed us. Check once before the monitor starts; the one-shot
                // guard makes any later onCancel/handler call a no-op.
                if Task.isCancelled { finish(nil); return }
                monitor.start(queue: .global())
                Task {
                    try? await Task.sleep(for: timeout)
                    finish(nil)
                }
            }
        } onCancel: {
            finishBox.withLock { $0 }?(nil)
        }
    }

    /// True when the kernel knows the interface name — `if_nametoindex(3)`
    /// (Darwin `net/if.h`). `doctor` checks a `.named` binding this way: a typo'd
    /// `bindInterface` is a warning now, not a bind failure at tunnel start.
    public static func exists(_ name: String) -> Bool {
        if_nametoindex(name) != 0
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
