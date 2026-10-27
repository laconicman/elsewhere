import ElsewhereKit
import Foundation
import MCP
import Testing
@testable import ElsewhereMCP

/// `ElsewhereServer` in-process: a client initializes over `InMemoryTransport`,
/// `tools/list` returns exactly the three tools with their annotations and
/// closed schemas, and usage errors name the field. Engine-free — every call
/// here fails validation before a lease, or needs no route at all.
@Suite("ElsewhereServer — the three tools over MCP, in-process", .temporaryDirectories)
struct ServerTests {
    /// The plan's table: read-only, non-destructive, idempotent, open world.
    static let annotations: [String: [Bool]] = [
        "elsewhere_fetch": [true, false, true, true],
        "elsewhere_whoami": [true, false, true, true],
        "elsewhere_exits": [true, false, true, false],
    ]

    /// Each tool's schema argument names, sorted.
    static let argumentNames: [String: [String]] = [
        "elsewhere_fetch": [
            "exit", "follow_redirects", "max_length", "raw", "start_index", "url",
        ],
        "elsewhere_whoami": ["exit"],
        "elsewhere_exits": [],
    ]

    private func store(_ config: ElsewhereConfig) throws -> ConfigStore {
        let store = ConfigStore(
            url: temporaryDirectory().appending(path: "config.json"))
        try store.save(config)
        return store
    }

    /// The server over `context`, and a client connected to it in-process.
    private func connect(
        _ context: ServeContext
    ) async throws -> (client: Client, server: Server, initialized: Initialize.Result) {
        let (clientTransport, serverTransport) =
            await InMemoryTransport.createConnectedPair()
        let server = await ElsewhereServer.makeServer(context: context)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "0")
        let initialized = try await client.connect(transport: clientTransport)
        return (client, server, initialized)
    }

    /// A client initializes; `tools/list` is exactly the three tools, each with
    /// the table's annotations, the legend's word in its description (a host may
    /// load one and never another), and a closed schema of the expected names.
    @Test func aClientInitializesAndListsThreeTools() async throws {
        let context = ServeContext.makeNeverOpening(
            store: try store(ElsewhereConfig()))
        let (client, server, initialized) = try await connect(context)
        #expect(initialized.serverInfo.name == "elsewhere")
        #expect(initialized.serverInfo.version == Elsewhere.version)
        #expect(initialized.instructions?.contains("elsewhere_fetch") == true)
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name)
            == ["elsewhere_fetch", "elsewhere_whoami", "elsewhere_exits"])
        for tool in tools {
            let hints = [
                tool.annotations.readOnlyHint, tool.annotations.destructiveHint,
                tool.annotations.idempotentHint, tool.annotations.openWorldHint,
            ]
            #expect(hints == Self.annotations[tool.name]?.map(Optional.some), "\(tool.name)")
            #expect(tool.title?.isEmpty == false, "\(tool.name)")
            #expect(tool.description?.contains("exit") == true, "\(tool.name)")
            let schema = tool.inputSchema.objectValue
            #expect(schema?["additionalProperties"] == false, "\(tool.name)")
            #expect(
                schema?["properties"]?.objectValue?.keys.sorted()
                    == Self.argumentNames[tool.name], "\(tool.name)")
        }
        await client.disconnect()
        await server.stop()
    }

    /// An unknown tool is a protocol error listing the real names — never an
    /// `isError` result.
    @Test func anUnknownToolIsAProtocolError() async throws {
        let context = ServeContext.makeNeverOpening(
            store: try store(ElsewhereConfig()))
        let (client, server, _) = try await connect(context)
        await #expect {
            let _: (content: [Tool.Content], isError: Bool?) =
                try await client.callTool(name: "elsewhere_nope")
        } throws: { error in
            (error as? MCPError)?.code == -32602
        }
        await client.disconnect()
        await server.stop()
    }

    /// A bad call is an `isError` result that names the field — usage advice a
    /// model can act on — and never reaches the tunnel.
    @Test func badArgumentsAreUsageErrorsNamingTheField() async throws {
        let context = ServeContext.makeNeverOpening(
            store: try store(ElsewhereConfig()))
        let toolbox = Toolbox(specs: [.fetch(context), .whoami(context), .exits(context)])
        let cases: [(arguments: [String: Value], field: String)] = [
            (["url": "https://example.com", "max_length": 200_001], "max_length"),
            (["url": "https://example.com", "start_index": -1], "start_index"),
            (["url": "https://example.com", "bogus": 1], "bogus"),
            (["url": 42], "url"),
            ([:], "url"),
        ]
        for (arguments, field) in cases {
            let reply = try await toolbox.reply("elsewhere_fetch", arguments)
            #expect(reply.isError, "\(arguments)")
            #expect(reply.text.contains(field), "\(reply.text)")
            #expect(reply.text.contains("status "), "\(reply.text)")
        }
    }

    /// `elsewhere_exits` prints the redacted summary the CLI's `exits list`
    /// shares, plus `direct` — and none of the link's secrets can reach the text.
    @Test func exitsPrintsTheRedactedSummaryAndDirect() async throws {
        let store = try store(ElsewhereConfig(
            default: "spike", exits: ["spike": .link(Synthetic.link)]))
        let context = ServeContext.makeNeverOpening(store: store)
        let toolbox = Toolbox(specs: [.exits(context)])
        let reply = try await toolbox.reply("elsewhere_exits")
        #expect(!reply.isError)
        #expect(reply.text.contains("spike  "), "\(reply.text)")
        #expect(reply.text.contains("[default]"), "\(reply.text)")
        #expect(reply.text.contains("direct  the machine's own path"), "\(reply.text)")
        for secret in Synthetic.secrets + [Synthetic.link] {
            #expect(!reply.text.contains(secret))
        }
    }

    /// The `direct` line reports the path the engine will actually ride: under
    /// `--via-system` a file's `.auto` binding is moot — the reply says unbound.
    @Test func exitsReportsTheEffectiveDirectPath() async throws {
        let store = try store(ElsewhereConfig()) // bindInterface .auto
        let context = ServeContext.makeNeverOpening(
            store: store, options: ServeOptions(idleStop: nil, viaSystem: true))
        let toolbox = Toolbox(specs: [.exits(context)])
        let reply = try await toolbox.reply("elsewhere_exits")
        #expect(!reply.isError)
        #expect(
            reply.text.contains("unbound — the system path"), "\(reply.text)")
    }
}
