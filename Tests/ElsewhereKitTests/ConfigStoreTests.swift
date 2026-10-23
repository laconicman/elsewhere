import Foundation
import Testing
@testable import ElsewhereKit

/// ConfigStore: round-trip in a temp dir, mode 0700/0600, env precedence, and the
/// load-time validation a hand-edited file could break.
@Suite("ConfigStore — round trip, permissions, precedence", .temporaryDirectories)
struct ConfigStoreTests {
    private func store() -> ConfigStore {
        ConfigStore(url: temporaryDirectory().appending(path: "elsewhere/config.json"))
    }

    private func config() -> ElsewhereConfig {
        ElsewhereConfig(
            default: "moldova",
            exits: [
                "moldova": .link(Synthetic.link),
                "kz": .xray(.object(["protocol": .string("vless")])),
                "incy": .proxy(URL(string: "http://127.0.0.1:10808")!),
            ])
    }

    @Test func roundTripsAllThreeExitKinds() throws {
        let store = store()
        try store.save(config())
        #expect(try store.load(environment: [:]) == config())
    }

    @Test func writes0700DirectoryAnd0600File() throws {
        let store = store()
        try store.save(config())
        let fm = FileManager.default
        let dirMode = try fm.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[
            .posixPermissions] as? Int
        let fileMode = try fm.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700 && fileMode == 0o600)
        #expect(ConfigStore.permissionsAreStrict(store.url))

        // Loosen it, then re-save: the write restores 0600.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        #expect(!ConfigStore.permissionsAreStrict(store.url))
        try store.save(config())
        #expect(ConfigStore.permissionsAreStrict(store.url))
    }

    @Test func aPreexistingLooseDirectoryIsTightened() throws {
        let store = store()
        let fm = FileManager.default
        try fm.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try store.save(config())
        let dirMode = try fm.attributesOfItem(
            atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    @Test func missingFileIsAConfigError() {
        do {
            _ = try store().load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("no config at") && message.contains("exits add"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test func loadFileIsNilOnlyWhenAbsent() throws {
        let store = store()
        #expect(try store.loadFile() == nil)
        try store.save(config())
        #expect(try store.loadFile() == config())
    }

    @Test func unreadableFileThrowsConfigNotNil() throws {
        guard getuid() != 0 else {
            Issue.record("running as root — a 000 file is still readable; skipped")
            return
        }
        let store = store()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.url)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        }
        do {
            _ = try store.loadFile()
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            // "Cannot read" — never nil: `exits add` must not overwrite existing exits.
            #expect(message.contains("cannot read"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test func loadFileNeverSeesTheEnvironment() throws {
        let store = store()
        // The env link synthesizes a config for load(environment:) only — loadFile is
        // what mutations use, and it must stay blind to ELSEWHERE_LINK so a secret is
        // never persisted under the reserved name `env`.
        let env = ["ELSEWHERE_LINK": Synthetic.link]
        #expect(try store.loadFile() == nil)
        #expect(
            try store.load(environment: env).exits == ["env": .link(Synthetic.link)])
        try store.save(config())
        #expect(try store.loadFile() == config())
    }

    @Test func envLinkSynthesizesAnEnvExitAndIgnoresTheFile() throws {
        let store = store() // never saved — the file does not exist
        let config = try store.load(environment: ["ELSEWHERE_LINK": Synthetic.link])
        #expect(config.exits == ["env": .link(Synthetic.link)])
        #expect(config.default == "env")
    }

    @Test func resolveURLPrecedence() {
        let url = temporaryDirectory()
        let explicit = url.appending(path: "explicit.json").path
        let fromEnv = url.appending(path: "env.json").path
        #expect(
            ConfigStore.resolveURL(explicit: explicit, environment: ["ELSEWHERE_CONFIG": fromEnv])
                .path == explicit)
        #expect(
            ConfigStore.resolveURL(explicit: nil, environment: ["ELSEWHERE_CONFIG": fromEnv])
                .path == fromEnv)
        #expect(ConfigStore.resolveURL(explicit: nil, environment: [:]) == ConfigStore.defaultURL)
    }

    @Test func newerVersionIsRejected() throws {
        let store = store()
        try store.save(config())
        var text = try String(contentsOf: store.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        try Data(text.utf8).write(to: store.url)
        do {
            _ = try store.load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("version 2 is not supported"))
            #expect(message.contains("understands version 1"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test(arguments: [
        #"{"exits":{"bad":{}}}"#,
        #"{"exits":{"bad":{"link":"vless://x@h:1","proxy":"http://127.0.0.1:1"}}}"#,
    ])
    func exitObjectsNeedExactlyOneKey(_ json: String) throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
        #expect(throws: ElsewhereError.self) { _ = try store.load(environment: [:]) }
    }

    @Test func decodeErrorIsRenderedByCaseAndPath() throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `link` must be a string — a number is a typeMismatch at exits.bad.link.
        try Data(#"{"exits":{"bad":{"link":42}}}"#.utf8).write(to: store.url)
        do {
            _ = try store.load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("typeMismatch"))
            #expect(message.contains("exits.bad.link"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test func ourOwnDecodeMessageStaysReadable() throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"exits":{"bad":{}}}"#.utf8).write(to: store.url)
        do {
            _ = try store.load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            // Exit.init's dataCorrupted text must survive the render verbatim.
            #expect(message.contains("exit needs exactly one of"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test func invalidExitNameInTheFileIsRejected() throws {
        let store = store()
        var bad = config()
        bad.exits["Bad_Name"] = .link(Synthetic.link)
        // Written by hand — save() would refuse it; load() must too.
        let data = try JSONEncoder.with(bad)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: store.url)
        do {
            _ = try store.load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            // Names are never echoed — "invalid exit name" is the whole diagnostic.
            #expect(message.contains("invalid exit name"))
        } catch {
            Issue.record("expected .config, got \(error)")
        }
    }

    @Test func defaultMustNameAnExistingExit() throws {
        let store = store()
        var bad = config()
        bad.default = "missing"
        let data = try JSONEncoder.with(bad)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: store.url)
        #expect(throws: ElsewhereError.self) { _ = try store.load(environment: [:]) }
    }

    @Test func saveValidatesBeforeWriting() throws {
        let store = store()
        // `env` is a reserved name — a save reaching for it must fail as .config
        // before anything touches the file.
        var bad = ElsewhereConfig(exits: ["env": .link(Synthetic.link)])
        #expect(throws: ElsewhereError.self) { try store.save(bad) }
        #expect(try store.loadFile() == nil)

        bad = config()
        bad.default = "missing"
        #expect(throws: ElsewhereError.self) { try store.save(bad) }
        #expect(try store.loadFile() == nil)
    }

    @Test func nilDefaultOmitsTheKey() throws {
        let store = store()
        var config = config()
        config.default = nil
        try store.save(config)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("\"default\""))
        #expect(try store.load(environment: [:]) == config)
    }

    @Test func saveLeavesNoTemporaryFileBehind() throws {
        let store = store()
        try store.save(config())
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: store.url.deletingLastPathComponent().path)
        #expect(leftovers == ["config.json"])
    }
}
