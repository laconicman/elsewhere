import ElsewhereKit
import Foundation
import Synchronization

/// The session a fetch-like command holds: open with just the lanes it needs (A9),
/// hand `body` the session/routes, close in every path — errors and cancellation
/// included.
enum Session {
    /// Opens a session carrying exactly `names` (+ the direct lane when asked),
    /// runs `body`, then closes — whatever happened.
    static func withSession<R>(
        names: Set<String>, includeDirect: Bool,
        config: ElsewhereConfig, tunnel: TunnelOptions,
        body: (TunnelSession) async throws(ElsewhereError) -> R
    ) async throws(ElsewhereError) -> R {
        let session = try await TunnelSession.open(
            config: config, exits: names, includeDirect: includeDirect,
            bindInterface: tunnel.bindInterface(from: config), log: tunnel.log)
        do {
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    /// The one-route shape: resolve the selection, open just that lane, hand the
    /// `Route` to `body`.
    static func withRoute<R>(
        selection: ExitSelection, config: ElsewhereConfig, tunnel: TunnelOptions,
        body: (Route) async throws(ElsewhereError) -> R
    ) async throws(ElsewhereError) -> R {
        let name = try selection.resolve(in: config)
        return try await withSession(
            names: name == "direct" ? [] : [name],
            includeDirect: name == "direct",
            config: config, tunnel: tunnel
        ) { session throws(ElsewhereError) in
            try await body(session.route(for: name))
        }
    }
}

/// SIGINT/SIGTERM → `onSignal`, via dispatch sources. `signal(sig, SIG_IGN)` comes
/// first — the default disposition must not fire before the source runs (the
/// DispatchSourceSignal shape is Domicile's `SignalSource`, copied).
final class SignalWatcher: @unchecked Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ onSignal: @escaping @Sendable (Int32) -> Void) {
        let queue = DispatchQueue(label: "com.learnable.elsewhere.signals")
        sources = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { onSignal(sig) }
            source.resume()
            return source
        }
    }

    func stop() {
        for source in sources { source.cancel() }
    }

    deinit { stop() }
}

/// Runs `body` in a task a `SignalWatcher` cancels on SIGINT/SIGTERM. When a signal
/// was delivered the process exits 128 + signal — the shell convention — instead of
/// reporting the interruption as an error. For `run`, the terminal already signalled
/// the whole foreground group, so the child gets its own copy; the parent outlives
/// it to stop the tunnel.
func withSignalCancellation<R: Sendable>(
    _ body: @escaping @Sendable () async throws(ElsewhereError) -> R
) async throws(ElsewhereError) -> R {
    let delivered = Mutex(Int32(0))
    let task = Task { try await body() }
    let watcher = SignalWatcher { sig in
        delivered.withLock { if $0 == 0 { $0 = sig } }
        task.cancel()
    }
    defer { watcher.stop() }
    do {
        return try await task.value
    } catch let error as ElsewhereError {
        let sig = delivered.withLock { $0 }
        if sig != 0 { Foundation.exit(128 + sig) }
        throw error
    } catch {
        // `task.value` throws `any Error` — a bare CancellationError or anything
        // untyped that escaped. A delivered signal still wins the exit status.
        let sig = delivered.withLock { $0 }
        if sig != 0 { Foundation.exit(128 + sig) }
        throw ElsewhereError.fetch("interrupted")
    }
}
