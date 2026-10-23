import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server on loopback for the fetch/whoami fixtures: reads one
/// request head, routes on method + path, writes a correct response
/// (`Content-Length`, `Connection: close`), then closes. One request per connection.
/// Loopback only — never a real network.
final class TestHTTPServer: Sendable {
    /// `cp1251` bytes for the string `"Привет"` — the windows-1251 fixture.
    static let cp1251Body: Data = "Привет".data(using: .windowsCP1251)!
    static let okBody = "<html><body>ok</body></html>"
    /// Deliberately larger than `FetchLimits.maxBodyBytes`.
    static let bigBody = Data(repeating: 0x61, count: 5_600_000)
    static let traceBody = "fl=352f90\nh=127.0.0.1\nip=203.0.113.9\nts=1760000000.0\ncolo=AAA\nloc=ZZ\n"

    private let listener: NWListener

    init(host: String = "127.0.0.1") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// `start` waited longer than this — the suite must fail, not hang.
    struct StartTimeout: Error {}

    /// The ready/timed-out shape is `EchoServer.start`'s; the handler is what differs.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.readHead(into: Data(), on: connection)
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
                    self.listener.stateUpdateHandler = nil
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
                        return
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

    /// Accumulates until the head terminator arrives, then answers. The buffer is a
    /// value type passed by value each hop — nothing is captured mutably.
    private static func readHead(into buffer: Data, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, _ in
            var buffer = buffer
            if let content { buffer.append(content) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                respond(to: buffer, on: connection)
            } else {
                readHead(into: buffer, on: connection)
            }
        }
    }

    private static func respond(to head: Data, on connection: NWConnection) {
        guard let request = String(data: head, encoding: .utf8),
            let requestLine = request.split(separator: "\r\n").first
        else { return connection.cancel() }
        let fields = requestLine.split(separator: " ")
        let method = fields.count > 0 ? String(fields[0]) : "GET"
        let path = fields.count > 1 ? String(fields[1]) : "/"

        switch (method, path) {
        case (_, "/ok"):
            send("200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(okBody.utf8), headOnly: false, on: connection)
        case (_, "/big"):
            send("200 OK", contentType: "text/plain",
                 body: bigBody, headOnly: false, on: connection)
        case (_, "/cp1251"):
            send("200 OK", contentType: "text/plain; charset=windows-1251",
                 body: cp1251Body, headOnly: false, on: connection)
        case (_, "/bin"):
            send("200 OK", contentType: "application/octet-stream",
                 body: Data([0x00, 0x9F, 0x10, 0x42]), headOnly: false, on: connection)
        case (_, "/redir"):
            send("302 Found", headers: ["Location: /ok"], body: Data(), on: connection)
        case (_, "/loop"):
            send("302 Found", headers: ["Location: /loop"], body: Data(), on: connection)
        case ("HEAD", "/head"):
            send("200 OK", contentType: "text/html",
                 body: Data(okBody.utf8), headOnly: true, on: connection)
        case (_, "/head"):
            send("200 OK", contentType: "text/html",
                 body: Data(okBody.utf8), headOnly: false, on: connection)
        case (_, "/cdn-cgi/trace"):
            send("200 OK", contentType: "text/plain",
                 body: Data(traceBody.utf8), headOnly: false, on: connection)
        case (_, "/trickle"):
            // A byte every 300 ms — every read makes it in time, so only the
            // *resource* timeout can stop this fetch.
            trickle(on: connection)
        default:
            send("404 Not Found", contentType: "text/plain",
                 body: Data("not found".utf8), headOnly: method == "HEAD", on: connection)
        }
    }

    /// `Content-Length` promises a megabyte; the body arrives one byte every 300 ms
    /// and stops when the client hangs up.
    private static func trickle(on connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
            + "Content-Length: 1000000\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            guard error == nil else { return }
            sendTrickleByte(on: connection)
        })
    }

    private static func sendTrickleByte(on connection: NWConnection) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            connection.send(content: Data([0x61]), completion: .contentProcessed { error in
                guard error == nil else { return }
                sendTrickleByte(on: connection)
            })
        }
    }

    /// `headOnly` writes `Content-Length` for a body that is not sent — the HEAD shape.
    private static func send(
        _ status: String, headers: [String] = [], contentType: String? = nil,
        body: Data, headOnly: Bool = false, on connection: NWConnection
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        for header in headers { head += "\(header)\r\n" }
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(head.utf8)
        if !headOnly { packet.append(body) }
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
