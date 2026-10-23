import ArgumentParser
import ElsewhereKit
import Foundation

/// `elsewhere run -- CMD` (§5.7): the child inherits stdio and gets the proxy env
/// vars for the selected route; its exit status is ours. The terminal delivers
/// SIGINT/SIGTERM to the whole foreground group — the child gets its own copy, the
/// parent ignores them while it lives so the tunnel outlives the child.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with the exit's proxy in its environment (HTTP(S)_/ALL_PROXY).",
        discussion: """
        The child sees HTTP_PROXY/HTTPS_PROXY at http://127.0.0.1:PORT and ALL_PROXY
        at socks5h://127.0.0.1:PORT for a tunnel lane (the `h` keeps DNS remote), or
        the exit's own URL for a proxy exit; NO_PROXY covers loopback.
        """
    )

    @OptionGroup var exits: ExitOptions
    @OptionGroup var tunnel: TunnelOptions
    @OptionGroup var options: GlobalOptions

    @Argument(parsing: .postTerminator, help: "The command; everything after `--` passes through verbatim.")
    var command: [String] = []

    func run() async throws {
        try await exitingWithStatus { () async throws(ElsewhereError) -> Int32 in
            let config = try options.store.load(
                environment: ProcessInfo.processInfo.environment)
            return try await withSignalCancellation { () async throws(ElsewhereError) in
                try await Session.withRoute(
                    selection: exits.selection, config: config, tunnel: tunnel
                ) { route throws(ElsewhereError) in
                    try await ChildRunner.run(command, via: route)
                }
            }
        }
    }
}
