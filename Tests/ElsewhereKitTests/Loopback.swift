import Foundation
import Network

/// Answers whatever it receives with one canned response, then closes. Stands in for
/// INCY's `mixed` inbound (the `proxy` exit doctor probes) and for "something listening"
/// in the probe tests. Copied from swift-libxray's `Loopback.swift` — the same
/// loopback-only contract, `requiredLocalEndpoint` keeps it off the other interfaces.
final class EchoServer: Sendable {
    static let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

    private let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening on loopback; returns the bound port once the listener is ready.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(
                    content: Data(EchoServer.response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: return
                }
                self.listener.stateUpdateHandler = nil   // resumed once; a later state must not resume again
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }
}
