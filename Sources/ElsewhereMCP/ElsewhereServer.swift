public import ElsewhereKit // the façade is the public signature
import Foundation
import MCP

/// The MCP face of `elsewhere`: `elsewhere serve` runs this server over stdio, on
/// the same Kit the CLI drives. Three tools — `elsewhere_fetch`,
/// `elsewhere_whoami`, `elsewhere_exits` — and the one lazy tunnel behind them
/// (Design: "`serve` keeps one engine with every lane, lazily"). stdout is the
/// protocol: nothing here prints.
public enum ElsewhereServer {
    /// The `serverInfo.name` the server announces.
    public static let name = "elsewhere"

    /// How the tools fit together, for the client to show the model beside their
    /// descriptions.
    static let instructions = """
    elsewhere reads web pages through named exits — your own tunnels or local \
    proxies — or `direct`, the machine's own path past any system VPN, so a URL \
    that is unreachable from the agent's network is read, not guessed. When a \
    fetch fails or a site is blocked, call elsewhere_fetch before giving up: it \
    returns Markdown by default, paged by max_length/start_index with a marker \
    to continue from. elsewhere_whoami shows the public IP and country each \
    route exits in; elsewhere_exits lists the configured exits and the default.
    """

    /// Serves on stdio until stdin closes (the host quit) or the task is
    /// cancelled (SIGINT/SIGTERM via the CLI's `withSignalCancellation`). stdin
    /// EOF returns `waitUntilCompleted` without `stop()` (swift-sdk 0.12.1), so
    /// teardown lives after it — `close(reason:)` the tunnel, then `stop()`.
    /// A cancelled wait unblocks the same way: `onCancel` stops the server, the
    /// wait returns, and the tunnel closes with reason `signal`.
    ///
    /// - Throws: `.config` from `--log-tsv`, and `.engine` on a transport
    ///   failure — the "something under us failed" case the Kit already has.
    public static func serve(
        store: ConfigStore, environment: [String: String], options: ServeOptions
    ) async throws(ElsewhereError) {
        // `Optional.map` would rethrow as `any Error` — the typed throw is spelt out.
        let tsv: TSVLog? = if let tsvPath = options.tsvLog {
            try TSVLog(path: tsvPath)
        } else {
            nil
        }
        let context = ServeContext(
            tunnel: ServeTunnel(
                store: store, environment: environment, options: options,
                tsv: tsv),
            store: store, environment: environment, options: options, tsv: tsv)
        let server = await makeServer(context: context)
        var failure: (any Error)?
        do {
            try await server.start(transport: StdioTransport())
            await withTaskCancellationHandler {
                await server.waitUntilCompleted()
            } onCancel: {
                // SIGINT/SIGTERM: stop the server so the wait returns and the
                // teardown below can close the tunnel before the process exits.
                Task { await server.stop() }
            }
        } catch {
            failure = error
        }
        await context.tunnel.close(reason: Task.isCancelled ? "signal" : "eof")
        await server.stop()
        if let failure, !(failure is CancellationError) {
            throw .engine(
                "mcp transport: \(Redactor.scrubPatterns(failure.localizedDescription))")
        }
    }

    /// A server answering `tools/list` and `tools/call` from the toolbox. The
    /// SDK runs each request's handler in a task of its own (no FIFO ordering),
    /// so a slow fetch holds up no other call.
    static func makeServer(context: ServeContext) async -> Server {
        let toolbox = Toolbox(specs: [
            .fetch(context), .whoami(context), .exits(context),
        ])
        let server = Server(
            name: name, version: Elsewhere.version, instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolbox.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await toolbox.call(params)
        }
        return server
    }
}
