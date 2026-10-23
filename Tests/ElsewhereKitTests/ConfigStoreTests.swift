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
            #expect(message.contains("version 2"))
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

    @Test func invalidExitNameInTheFileIsRejected() throws {
        let store = store()
        var bad = config()
        bad.exits["Bad_Name"] = .link(Synthetic.link)
        // Saved by hand — save() cannot refuse an in-memory model, load() must.
        let data = try JSONEncoder.with(bad)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: store.url)
        do {
            _ = try store.load(environment: [:])
            Issue.record("expected a throw")
        } catch ElsewhereError.config(let message) {
            #expect(message.contains("Bad_Name"))
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
}
