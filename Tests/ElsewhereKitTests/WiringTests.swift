import ElsewhereKit
import Foundation
import Testing

/// Version drift between surfaces is the bug the shared constant can't have
/// alone — the registration JSON can't import `Elsewhere.version`, so the
/// check lives here: the `.mcpb` manifest, the plugin manifest and the
/// plugin's `.mcp.json` must carry this build's version and the `serve` entry.
@Suite("Wiring — the surfaces carry the one version")
struct WiringTests {
    /// `…/elsewhere/Tests/ElsewhereKitTests/WiringTests.swift` → the repo root.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct DesktopManifest: Decodable {
        let version: String
        let server: Server
        let userConfig: [String: Option]
        struct Server: Decodable {
            let entryPoint: String
            let mcpConfig: MCPConfig
            struct MCPConfig: Decodable {
                let command: String
                let args: [String]
            }
            enum CodingKeys: String, CodingKey {
                case entryPoint = "entry_point"
                case mcpConfig = "mcp_config"
            }
        }
        struct Option: Decodable { let required: Bool? }
        enum CodingKeys: String, CodingKey {
            case version, server
            case userConfig = "user_config"
        }
    }

    private struct PluginManifest: Decodable { let version: String }

    private struct PluginMCP: Decodable {
        let mcpServers: [String: Entry]
        struct Entry: Decodable { let args: [String] }
    }

    private static func decoded<T: Decodable>(_ type: T.Type, at relative: String) throws -> T {
        try JSONDecoder().decode(
            T.self, from: Data(contentsOf: root.appending(path: relative)))
    }

    /// The `.mcpb` runs `serve` through the install-time binary path.
    @Test func desktopManifestCarriesTheVersionAndServe() throws {
        let manifest = try Self.decoded(
            DesktopManifest.self, at: "desktop-extension/manifest.json")
        #expect(manifest.version == Elsewhere.version)
        #expect(manifest.server.mcpConfig.args.first == "serve")
    }

    /// The `.mcpb` launches the SETUP path itself: Claude Desktop substitutes `${HOME}` in
    /// `mcp_config`, not inside a `user_config` default (modelcontextprotocol/mcpb#251), and
    /// its install form would not take an empty optional field (observed 2026-10-24) — so
    /// every option it offers is required and holds a value.
    @Test func desktopManifestLaunchesTheSetupPath() throws {
        let manifest = try Self.decoded(
            DesktopManifest.self, at: "desktop-extension/manifest.json")
        let path = "${HOME}/.local/bin/elsewhere"
        #expect(manifest.server.entryPoint == path)
        #expect(manifest.server.mcpConfig.command == path)
        #expect(manifest.userConfig.values.allSatisfy { $0.required == true })
    }

    /// The Claude Code plugin: same version, and its `.mcp.json` launches
    /// `elsewhere serve` over stdio.
    @Test func thePluginCarriesTheVersionAndServe() throws {
        let plugin = try Self.decoded(
            PluginManifest.self, at: "plugin/.claude-plugin/plugin.json")
        #expect(plugin.version == Elsewhere.version)
        let mcp = try Self.decoded(PluginMCP.self, at: "plugin/.mcp.json")
        #expect(mcp.mcpServers["elsewhere"]?.args == ["serve"])
    }
}
