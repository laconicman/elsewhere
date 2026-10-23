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
    public static func isListening(port: UInt16, timeout: Duration = .seconds(1)) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
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
}
