import Foundation
import Network
import Synchronization

/// Answers whatever it receives with one canned response, then closes. Stands in for
/// INCY's `mixed` inbound (the `proxy` exit doctor probes) and for "something listening"
/// in the probe tests. Copied from swift-libxray's `Loopback.swift` — the same
/// loopback-only contract, `requiredLocalEndpoint` keeps it off the other interfaces.
final class EchoServer: Sendable {
    static let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

    private let listener: NWListener

    init(host: String = "127.0.0.1") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// `start` waited longer than this — the suite must fail, not hang.
    struct StartTimeout: Error {}

    /// Starts listening on loopback; returns the bound port once the listener is ready.
    /// One-shot like `LoopbackProbe`: first verdict wins (Mutex), `.cancelled` and a
    /// 5-second ceiling both throw, and a cancelled caller cancels the listener — a
    /// parked continuation would hang the suite.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(
                    content: Data(EchoServer.response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = Mutex(false)
                let finish: @Sendable (Result<UInt16, any Error>) -> Void = { result in
                    let first = resumed.withLock { seen in
                        if seen { return false }
                        seen = true
                        return true
                    }
                    guard first else { return }
                    self.listener.stateUpdateHandler = nil // one-shot; break handler↔listener
                    continuation.resume(with: result)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(self.listener.port?.rawValue ?? 0))
                    case .failed(let error):
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        return // .preparing/.waiting — a verdict or the timeout ends it
                    }
                }
                listener.start(queue: .global())
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    finish(.failure(StartTimeout()))
                }
            }
        } onCancel: {
            listener.cancel()
        }
    }

    func stop() {
        listener.cancel()
    }
}
