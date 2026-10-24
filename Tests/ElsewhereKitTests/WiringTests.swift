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
        struct Server: Decodable {
            let mcpConfig: MCPConfig
            struct MCPConfig: Decodable { let args: [String] }
            enum CodingKeys: String, CodingKey { case mcpConfig = "mcp_config" }
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
