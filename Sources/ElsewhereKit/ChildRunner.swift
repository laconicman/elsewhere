import Foundation

/// `elsewhere run -- CMD` (§5.7): the child gets proxy env vars pointing at the route,
/// inherits stdio, and its status is ours. `Process` against `/usr/bin/env` gives the
/// PATH lookup for free.
public enum ChildRunner {
    /// The child's environment: the parent's, plus the four proxy variables (upper and
    /// lower case — tools disagree) and `NO_PROXY` so loopback stays direct.
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
        environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
        environment["no_proxy"] = "localhost,127.0.0.1,::1"
        return environment
    }

    /// Runs `command` with the route's environment; returns the child's exit status —
    /// 128 + signal when it dies to one (`terminationReason == .uncaughtSignal`).
    /// SIGINT/SIGTERM are ignored in the parent for the child's lifetime: the terminal
    /// delivers them to the whole foreground group, so the child gets its own copy —
    /// and the parent must outlive it to stop the tunnel afterwards.
    /// - Throws: `.usage` for an empty command; `.fetch` when the launch itself fails.
    public static func run(_ command: [String], via route: Route) async throws(ElsewhereError) -> Int32 {
        guard !command.isEmpty else { throw .usage("run needs a command after `--`") }
        let previousInt = signal(SIGINT, SIG_IGN)
        let previousTerm = signal(SIGTERM, SIG_IGN)
        defer {
            signal(SIGINT, previousInt)
            signal(SIGTERM, previousTerm)
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, ElsewhereError>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.environment = environment(
                for: route, base: ProcessInfo.processInfo.environment)
            // Stdio inherited — the child's output is the point.
            process.terminationHandler = { finished in
                continuation.resume(
                    returning: finished.terminationReason == .uncaughtSignal
                        ? 128 + finished.terminationStatus
                        : finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: ElsewhereError.fetch(
                        "cannot launch \(command[0]): "
                            + Redactor.scrubPatterns(error.localizedDescription)))
            }
        }
    }
}
