import ArgumentParser
import ElsewhereKit
import Foundation

/// `elsewhere exits` — the named-exit group. `list` is the default subcommand.
struct ExitsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exits",
        abstract: "Manage named exits: share links, raw Xray outbounds, or a local proxy.",
        subcommands: [ExitsList.self, ExitsAdd.self, ExitsRemove.self, ExitsDefault.self],
        defaultSubcommand: ExitsList.self
    )
}

/// `elsewhere exits list` — one redacted line per exit, the default marked.
struct ExitsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the configured exits (names and redacted summaries)."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await reportingErrors { () async throws(ElsewhereError) in
            let config = try options.store.load(environment: ProcessInfo.processInfo.environment)
            for line in ExitsListing.lines(for: config) { emit(line) }
        }
    }
}

/// `elsewhere exits add NAME --link|-xray|--proxy …` — validated before it is saved, so a
/// typo fails here and not at fetch time.
struct ExitsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an exit. Pass `--link -` to read the link from stdin — it stays out of shell history.",
        discussion: """
        Exactly one source: --link 'vless://…' (or `-` for stdin), --xray FILE (a raw
        outbound object, flat or classic shape; `{"outbounds":[…]}` is unwrapped — a
        whole client config too, keeping its one proxy outbound and dropping the
        engine's `direct`/`block`/`dns` plumbing), or --proxy URL
        (http/https/socks5(h), a local proxy used as an exit, no Xray).
        """
    )

    @Argument(help: "Exit name: ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$, not `direct` or `env`.")
    var name: String

    @Option(help: "A share link; `-` reads one line from stdin (keeps the secret out of shell history).")
    var link: String?

    @Option(help: "A file with a raw Xray outbound object — or a whole client config with one proxy outbound.")
    var xray: String?

    @Option(help: "A local proxy URL used as an exit (e.g. http://127.0.0.1:10808 for INCY).")
    var proxy: String?

    @Flag(help: "Make this exit the default.")
    var `default` = false

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await reportingErrors { () async throws(ElsewhereError) in
            try ExitName.validate(name)
            let exit = try await resolvedExit()

            // `loadFile`, not `load(environment:)`: a mutation must never see — and so
            // never persist — the ELSEWHERE_LINK-synthesized `env` exit. nil is the
            // only case that starts a fresh config; unreadable/corrupt throws.
            var config = try options.store.loadFile() ?? ElsewhereConfig()
            let first = config.exits.isEmpty
            config.exits[name] = exit
            if first || self.default { config.default = name }
            try options.store.save(config)

            var line = "added \(name)  \(Redactor.summary(of: exit))"
            if config.default == name { line += "  [default]" }
            emit(line)
        }
    }

    /// Builds and validates the exit: links and xray objects go through the engine's
    /// converter *and* its `test` now — a typo fails here, not at fetch time. The
    /// stored value is what `ExitValidator` returns (an `xray` wrapper is unwrapped).
    private func resolvedExit() async throws(ElsewhereError) -> Exit {
        let sources = [link != nil, xray != nil, proxy != nil].filter { $0 }.count
        guard sources == 1 else {
            throw .usage("exits add needs exactly one of --link, --xray, --proxy")
        }
        if let link {
            let text = try await readLink(link)
            return try await ExitValidator.validate(.link(text), named: name)
        }
        if let path = xray {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw .exit("cannot read \(path): \(error.localizedDescription)")
            }
            let value: JSONValue
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw .exit("\(path) is not a JSON object: \(error.localizedDescription)")
            }
            return try await ExitValidator.validate(.xray(value), named: name)
        }
        if let raw = proxy {
            guard let url = URL(string: raw), let scheme = url.scheme,
                ["http", "https", "socks5", "socks5h"].contains(scheme),
                url.host != nil, url.port != nil
            else {
                // The raw value is not echoed — a proxy URL can carry userinfo.
                throw .usage("--proxy wants http(s):// or socks5(h)://host:port")
            }
            return .proxy(url)
        }
        throw .usage("exits add needs exactly one of --link, --xray, --proxy")
    }

    /// `--link -` reads one line from stdin, so the link never enters shell history.
    private func readLink(_ link: String) async throws(ElsewhereError) -> String {
        guard link == "-" else { return link }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw .usage("--link -: no link on stdin")
        }
        return line
    }
}

/// `elsewhere exits remove NAME` — clears `default` when it pointed at the removed exit.
struct ExitsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an exit."
    )

    @Argument(help: "Exit name.") var name: String
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await reportingErrors { () async throws(ElsewhereError) in
            guard var config = try options.store.loadFile() else {
                throw options.store.missingConfigError
            }
            guard config.exits.removeValue(forKey: name) != nil else {
                throw .exit("no exit named '\(name)'")
            }
            if config.default == name { config.default = nil }
            try options.store.save(config)
            emit("removed \(name)")
        }
    }
}

/// `elsewhere exits default NAME` — pins the exit `fetch`/`run` use without `--exit`.
struct ExitsDefault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "default",
        abstract: "Set the default exit."
    )

    @Argument(help: "Exit name.") var name: String
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await reportingErrors { () async throws(ElsewhereError) in
            guard var config = try options.store.loadFile() else {
                throw options.store.missingConfigError
            }
            guard config.exits[name] != nil else {
                throw .exit("no exit named '\(name)'")
            }
            config.default = name
            try options.store.save(config)
            emit("default exit: \(name)")
        }
    }
}
