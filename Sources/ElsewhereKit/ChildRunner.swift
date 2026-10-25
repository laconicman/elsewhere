import Foundation
import Synchronization

/// `elsewhere run -- CMD` (§5.7): the child gets proxy env vars pointing at the route,
/// inherits stdio, and its status is ours. `Process` against `/usr/bin/env` gives the
/// PATH lookup for free.
public enum ChildRunner {
    /// The child's environment: the parent's, plus the four proxy variables (upper and
    /// lower case — tools disagree) and `NO_PROXY` — the parent's bypass list with
    /// loopback added, so an internal host the parent keeps off a proxy stays off
    /// ours (the exit could not resolve it anyway).
    ///
    /// An `inbound` route advertises `http://127.0.0.1:PORT` for HTTP(S) and
    /// `socks5h://127.0.0.1:PORT` for `ALL_PROXY` — the `mixed` inbound speaks both,
    /// and `h` keeps DNS remote (the tunnel resolves, not the LAN). An `external`
    /// route passes its configured URL through — scheme and userinfo included.
    /// Pure: the same dict out for the same inputs.
    public static func environment(for route: Route, base: [String: String]) -> [String: String] {
        var environment = base
        let http: String
        let all: String
        switch route {
        case .inbound(_, let port):
            http = "http://127.0.0.1:\(port)"
            all = "socks5h://127.0.0.1:\(port)"
        case .external(_, let url):
            http = url.absoluteString
            all = url.absoluteString
        }
        environment["HTTP_PROXY"] = http
        environment["http_proxy"] = http
        environment["HTTPS_PROXY"] = http
        environment["https_proxy"] = http
        environment["ALL_PROXY"] = all
        environment["all_proxy"] = all
        let bypass = bypassList(from: base)
        environment["NO_PROXY"] = bypass
        environment["no_proxy"] = bypass
        return environment
    }

    /// What `NO_PROXY` carries whatever the parent says: loopback stays direct.
    static let loopbackBypass = ["localhost", "127.0.0.1", "::1"]

    /// The parent's bypass lists (both spellings, in order, trimmed, de-duplicated)
    /// plus loopback — one value for both spellings.
    static func bypassList(from base: [String: String]) -> String {
        let inherited = ["NO_PROXY", "no_proxy"]
            .flatMap { (base[$0] ?? "").split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var entries: [String] = []
        for entry in inherited + loopbackBypass
        where !entry.isEmpty && !entries.contains(entry) {
            entries.append(entry)
        }
        return entries.joined(separator: ",")
    }

    /// Runs `command` with the route's environment; returns the child's exit status —
    /// 128 + signal when it dies to one (`terminationReason == .uncaughtSignal`).
    /// SIGINT/SIGTERM are ignored in the parent for the child's lifetime: the terminal
    /// delivers them to the whole foreground group, so the child gets its own copy —
    /// and the parent must outlive it to stop the tunnel afterwards. Cancellation of
    /// the waiting task is forwarded too: `terminate()` (SIGTERM) first, a detached
    /// `SIGKILL` 5 s later if the child still stands — its reaped status (143/137)
    /// then flows back like any other.
    /// - Throws: `.usage` for an empty command; `.fetch` when the launch itself fails.
    public static func run(_ command: [String], via route: Route) async throws(ElsewhereError) -> Int32 {
        guard !command.isEmpty else { throw .usage("run needs a command after `--`") }
        let previousInt = signal(SIGINT, SIG_IGN)
        let previousTerm = signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT, previousInt)
            signal(SIGTERM, previousTerm)
        }
        // The launched child, shared with the cancellation handler — nil until
        // `run()` lands; a cancel racing the launch is caught by the isCancelled
        // check right after.
        let child = Mutex<Process?>(nil)
        // A Result, not a throwing continuation — `withTaskCancellationHandler`
        // erases typed throws to `any Error`.
        let outcome: Result<Int32, ElsewhereError> = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<Int32, ElsewhereError>, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = command
                process.environment = environment(
                    for: route, base: ProcessInfo.processInfo.environment)
                // stdout is the process's own channel — fd 1 is the engine's sink
                // (`OwnStdout`); stdin/stderr stay inherited.
                process.standardOutput = OwnStdout.handle
                process.terminationHandler = { finished in
                    continuation.resume(
                        returning: .success(
                            finished.terminationReason == .uncaughtSignal
                                ? 128 + finished.terminationStatus
                                : finished.terminationStatus))
                }
                do {
                    try process.run()
                    child.withLock { $0 = process }
                    if Task.isCancelled { process.terminate() }
                } catch {
                    continuation.resume(
                        returning: .failure(
                            .fetch(
                                "cannot launch \(command[0]): "
                                    + Redactor.scrubPatterns(error.localizedDescription))))
                }
            }
        } onCancel: {
            guard let process = child.withLock({ $0 }), process.isRunning else { return }
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        return try outcome.get()
    }
}
