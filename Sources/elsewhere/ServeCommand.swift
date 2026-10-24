import ArgumentParser
import ElsewhereKit
import ElsewhereMCP
import Foundation

/// `elsewhere serve` — the MCP stdio server an agent registers and calls
/// (issue #9). stdout is the protocol; nothing a human reads goes there.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the MCP server on stdio — elsewhere_fetch, elsewhere_whoami and elsewhere_exits for an agent.",
        discussion: """
        The tunnel opens lazily on the first call that needs a route — one engine \
        with every exit lane plus `direct`, so switching exits never restarts it — \
        and stops after --idle-stop minutes of no calls (0 = never). A changed exit \
        set reopens on the next call. stdout is the protocol; the engine log \
        defaults to ~/Library/Logs/elsewhere/xray.log (--xray-log or \
        ELSEWHERE_XRAY_LOG overrides), and --log-tsv keeps an audit row per call \
        and per lifecycle edge.
        """
    )

    @Option(help: "Minutes of no calls before the engine stops; 0 = never (default 10).")
    var idleStop = 10

    @Flag(help: "Allow private/local destinations on every fetch and whoami call.")
    var allowPrivate = false

    @Option(name: .customLong("log-tsv"), help: "Append one audit row per call and per tunnel lifecycle edge to this TSV file.")
    var logTSV: String?

    @OptionGroup var tunnel: TunnelOptions
    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard idleStop >= 0 else {
            throw ValidationError("--idle-stop wants a non-negative number of minutes")
        }
    }

    func run() async throws {
        try await reportingErrors { () throws(ElsewhereError) in
            let environment = ProcessInfo.processInfo.environment
            let serveOptions = ServeOptions(
                idleStop: idleStop == 0 ? nil : .seconds(Int64(idleStop) * 60),
                allowPrivate: allowPrivate,
                viaSystem: tunnel.viaSystem,
                log: try engineLog(),
                tsvLog: logTSV.map { URL(fileURLWithPath: $0) })
            try await withSignalCancellation { () async throws(ElsewhereError) in
                try await ElsewhereServer.serve(
                    store: options.store, environment: environment,
                    options: serveOptions)
            }
        }
    }

    /// The engine log for serve: `--xray-log`/`ELSEWHERE_XRAY_LOG` when given,
    /// else the file `~/Library/Logs/elsewhere/xray.log` (A1 — silent can't be
    /// the default where a human debugs a server that never touches stdout).
    /// The file (0600) and its directory (0700) are created first — the engine
    /// only opens the path.
    private func engineLog() throws(ElsewhereError) -> XrayConfigBuilder.XrayLog {
        if case .file(let path) = tunnel.log { return .file(path) }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/elsewhere/xray.log")
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(
                    atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
                else { throw ElsewhereError.config("cannot create \(url.path)") }
            }
        } catch let error as ElsewhereError {
            throw error
        } catch {
            throw .config("cannot prepare \(url.path): \(error.localizedDescription)")
        }
        return .file(url.path)
    }
}
