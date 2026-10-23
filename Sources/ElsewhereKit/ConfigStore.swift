public import Foundation

/// Reads and writes `config.json` — the one secret-bearing file (§5.2). A struct, not a
/// singleton: tests hand it a temporary URL and the CLI hands it the resolved one.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/elsewhere/config.json` — derived through
    /// FileManager, never `$HOME` string-building: Claude Desktop launches MCP servers
    /// with a sparse environment (risk S7).
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elsewhere/config.json")
    }

    /// Precedence (§5.2): `--config` > `ELSEWHERE_CONFIG` > the default path.
    public static func resolveURL(explicit: String?, environment: [String: String]) -> URL {
        if let explicit {
            URL(fileURLWithPath: explicit)
        } else if let envPath = environment["ELSEWHERE_CONFIG"], !envPath.isEmpty {
            URL(fileURLWithPath: envPath)
        } else {
            defaultURL
        }
    }

    /// Loads the config. `ELSEWHERE_LINK` wins outright: a single link synthesizes an
    /// in-memory config with one exit named `env` (§5.2) and the file is never touched.
    /// - Throws: `ElsewhereError.config` — missing file gets the actionable message.
    public func load(environment: [String: String]) throws(ElsewhereError) -> ElsewhereConfig {
        if let link = environment["ELSEWHERE_LINK"], !link.isEmpty {
            return ElsewhereConfig(default: "env", exits: ["env": .link(link)])
        }
        guard let config = try loadFile() else {
            throw .config("no config at \(url.path); run `elsewhere exits add`")
        }
        return config
    }

    /// The file's config, or `nil` only when it is genuinely absent — a present-but-
    /// unreadable or corrupt file throws `.config`, so a mutating command can never
    /// mistake "cannot read" for "empty" and overwrite the exits already there.
    ///
    /// The environment is never consulted: mutations (`exits add`/`remove`/`default`)
    /// call this so `ELSEWHERE_LINK`'s synthesized `env` exit can never be persisted.
    public func loadFile() throws(ElsewhereError) -> ElsewhereConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The file may have vanished between the exists check and the read. (Cast
            // inside, not `catch let … as NSError` — that pattern crashes SILGen in a
            // typed-throws function.)
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                nsError.code == NSFileReadNoSuchFileError
            else { throw .config("cannot read \(url.path): \(error.localizedDescription)") }
            return nil
        }
        let config: ElsewhereConfig
        do {
            config = try JSONDecoder().decode(ElsewhereConfig.self, from: data)
        } catch {
            throw .config("unreadable config at \(url.path): \(error.localizedDescription)")
        }
        return try Self.validated(config)
    }

    /// Writes atomically into a 0700 directory and leaves the file 0600 — set on create
    /// and after every write, so a looser umask or a rewritten file can't widen it.
    public func save(_ config: ElsewhereConfig) throws(ElsewhereError) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.with(config)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .config("cannot write \(url.path): \(error.localizedDescription)")
        }
        // Directory created above may have existed already with looser permissions.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// The file decoded; now the invariants a hand-edited file could break: the schema
    /// version this build understands, every exit name, and `default` pointing at a real
    /// exit.
    static func validated(_ config: ElsewhereConfig) throws(ElsewhereError) -> ElsewhereConfig {
        guard config.version == 1 else {
            throw .config(
                "config version \(config.version) is newer than this build understands")
        }
        for name in config.exits.keys.sorted() {
            do throws(ElsewhereError) {
                try ExitName.validate(name)
            } catch {
                throw .config(error.errorDescription ?? "invalid exit name '\(name)'")
            }
        }
        if let `default` = config.default, config.exits[`default`] == nil {
            throw .config("default exit '\(`default`)' is not among the exits")
        }
        return config
    }

    /// 0600 or tighter (0400 is fine): any group/other bit set is a `doctor` warning.
    public static func permissionsAreStrict(_ url: URL) -> Bool {
        guard let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? Int
        else { return false }
        return mode & 0o077 == 0
    }
}

extension JSONEncoder {
    /// The config's canonical encoding — pretty for hand-editing, sorted for diffs,
    /// `/` unescaped so links stay readable in the file.
    static func with(_ config: ElsewhereConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }
}
