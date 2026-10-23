import Network
import Synchronization

/// One-shot "is anything listening on this loopback port" — `doctor` uses it to notice a
/// local proxy (INCY's `mixed` inbound on 10808) and to sanity-check `proxy` exits; the
/// tunnel's readiness poll (PR #2) uses it because `runXray` returns ~350 ms before the
/// inbound accepts (swift-libxray TD-5, no engine-side readiness signal).
public enum LoopbackProbe {
    /// True once the TCP connect reports `.ready`; false on failure, refusal, or timeout.
    /// Cancellation-safe and one-shot (the same shape as swift-libxray's `connect`):
    /// whichever of the verdict and the timeout lands first wins, the connection is
    /// cancelled either way, and a cancelled caller cancels the connect instead of
    /// waiting out the timeout.
    /// - Parameters:
    ///   - host: the loopback literal to probe — `doctor` passes a proxy exit's
    ///     configured host (`::1` works through `NWEndpoint.Host`); the INCY check
    ///     keeps the IPv4 default.
    ///   - port: the TCP port.
    ///   - timeout: how long to wait for a verdict before answering false.
    public static func isListening(
        host: String = "127.0.0.1",
        port: UInt16,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumed = Mutex(false)
                let finish: @Sendable (Bool) -> Void = { answer in
                    let first = resumed.withLock { seen in
                        if seen { return false }
                        seen = true
                        return true
                    }
                    guard first else { return }
                    connection.cancel()
                    // The handler captures finish; finish captures the connection; the
                    // connection retains its handler — nil it to break the cycle.
                    connection.stateUpdateHandler = nil
                    continuation.resume(returning: answer)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    default: break // .preparing/.waiting — wait for a verdict or the timeout
                    }
                }
                connection.start(queue: .global())
                Task {
                    try? await Task.sleep(for: timeout)
                    finish(false)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// The hosts a `proxy` exit gets probed on: `localhost` (any case, one optional
    /// trailing dot), `::1`/`[::1]`, and every IPv4 literal in 127.0.0.0/8 — `127.0.0.2`
    /// is loopback too, not just `.1`. Everything else reads as external.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name == "::1" || name == "[::1]" { return true }
        // Four decimal octets, no regex: any UInt8-parseable quad headed by 127.
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let bytes = octets.compactMap { UInt8($0) }
        return bytes.count == 4 && bytes[0] == 127
    }
}
