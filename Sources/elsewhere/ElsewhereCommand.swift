import ArgumentParser
import ElsewhereKit
import Foundation

/// `elsewhere` — the thin CLI face over ``ElsewhereKit``: argument parsing here, every
/// decision in the Kit so the MCP server (M2) shares it.
@main
struct ElsewhereCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elsewhere",
        abstract: "Fetch it from elsewhere: read URLs through your own VLESS/Xray tunnel, with named exits and a direct path.",
        discussion: """
        Config: --config PATH > ELSEWHERE_CONFIG > \
        ~/Library/Application Support/elsewhere/config.json.
        ELSEWHERE_LINK alone synthesizes one in-memory exit named `env` for ad-hoc use.

        Signals: SIGINT/SIGTERM cancel the in-flight work and exit 128 + the signal
        number — the shell convention. `serve` is the MCP stdio server: on a
        signal it closes the tunnel, then exits the same way.

        Exit status (stable; scripts may rely on it):
        \(ExitStatus.help)
        """,
        version: Elsewhere.version,
        subcommands: [
            FetchCommand.self, WhoAmICommand.self, RunCommand.self,
            ExitsCommand.self, DoctorCommand.self, ServeCommand.self,
        ]
    )

    /// `parseAsRoot` + run, hand-rolled for one reason: ArgumentParser's own parse
    /// errors (`Unexpected argument 'vless://…'`) print verbatim to stderr, never
    /// touching `Redactor` — and a link pasted as a stray positional is exactly that
    /// shape. Everything AP would print to stderr goes through `scrubPatterns` first.
    /// Our own `ExitCode`s were already reported by `printError` — they exit silently;
    /// `CleanExit` (--help/--version, which AP wraps in `CommandError`) keeps AP's
    /// stdout behaviour.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let code as ExitCode {
            Foundation.exit(code.rawValue)
        } catch let error as ElsewhereError {
            // An ElsewhereError that escaped its command's own reporter still exits
            // by the sysexits table, not AP's generic failure.
            printError(error.localizedDescription)
            Foundation.exit(error.exitStatus)
        } catch {
            // AP wraps parser outcomes in (internal) CommandError, so the public
            // discriminator is the exit code: .success means help/version/completions
            // — hand those back to AP's renderer (stdout). Everything else is scrubbed
            // to stderr; a stray `vless://…` positional ends up here.
            if Self.exitCode(for: error) == .success {
                Self.exit(withError: error)
            }
            let line = "elsewhere: \(Redactor.scrubPatterns(Self.fullMessage(for: error)))\n"
            FileHandle.standardError.write(Data(line.utf8))
            Foundation.exit(Self.exitCode(for: error).rawValue)
        }
    }
}

/// Every subcommand's `--config PATH`, resolved once the same way (§5.2 precedence).
struct GlobalOptions: ParsableArguments {
    @Option(help: "Config file; default ~/Library/Application Support/elsewhere/config.json, or $ELSEWHERE_CONFIG. A leading ~ is expanded.")
    var config: String?

    /// The resolved store — the flag beats the env var, which beats the default path.
    var store: ConfigStore {
        ConfigStore(url: ConfigStore.resolveURL(
            explicit: config, environment: ProcessInfo.processInfo.environment))
    }
}

/// Writes `line` to stdout at once — the process's own descriptor after `claim()`,
/// since fd 1 is the engine's sink. `print` is block-buffered when stdout is a pipe or a
/// file, so a reader waiting on a line would wait for the process to end.
func emit(_ line: String) {
    OwnStdout.handle.write(Data((line + "\n").utf8))
}

/// Writes `elsewhere: <message>` to stderr, through the pattern scrub — belt and
/// braces: callers target-scrub already, but a message is free text and stderr is the
/// last surface a URL/UUID/long key must never reach raw.
func printError(_ message: String) {
    let line = "elsewhere: \(Redactor.scrubPatterns(message))\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// Runs `body`, printing an ``ElsewhereError`` to stderr and exiting with its documented
/// status (the `sysexits` table — a contract, per CLAUDE.md).
func reportingErrors(_ body: () async throws(ElsewhereError) -> Void) async throws {
    try await exitingWithStatus { () async throws(ElsewhereError) -> Int32 in
        try await body()
        return 0
    }
}

/// Runs `body` and exits with the status it returns, or with an ``ElsewhereError``'s.
func exitingWithStatus(_ body: () async throws(ElsewhereError) -> Int32) async throws {
    let code: Int32
    do {
        // fd 1 is the engine's sink from here on. This helper wraps every
        // subcommand's run(), so the claim happens once a *real* command starts —
        // AP's own post-parse writers keep fd 1: `--help` parses into a HelpCommand
        // whose run() prints through the generic catch below, and `--version` and
        // `--generate-completion-script` print during parse.
        try OwnStdout.claim()
        code = try await body()
    } catch {
        printError(error.localizedDescription)
        throw ExitCode(error.exitStatus)
    }
    if code != 0 { throw ExitCode(code) }
}
