import ElsewhereKit
import Foundation
import MCP
@testable import ElsewhereMCP

/// devin-kick's `ToolboxReplies`, adapted: the result's text as a model reads it,
/// and a one-call shape for tool tests.
extension CallTool.Result {
    /// The result's text, as a model reads it.
    var text: String {
        content.map { content in
            if case .text(let text, _, _) = content { text } else { "" }
        }.joined()
    }
}

extension Toolbox {
    /// The text of calling `name` with `arguments`, and whether it is an error.
    func reply(
        _ name: String, _ arguments: [String: Value] = [:]
    ) async throws -> (text: String, isError: Bool) {
        let result = try await call(.init(name: name, arguments: arguments))
        return (result.text, result.isError == true)
    }
}

extension ServeContext {
    /// A context built on `open` — the tunnel's test seam — so a test decides
    /// what a lease hands out: a real session, a counting fake, or a thrower.
    static func make(
        store: ConfigStore,
        options: ServeOptions = ServeOptions(idleStop: nil),
        tsv: TSVLog? = nil,
        traceURLs: [URL] = WhoAmI.defaultTraceURLs,
        open: @escaping @Sendable (
            ElsewhereConfig, BindInterface, XrayConfigBuilder.XrayLog
        ) async throws(ElsewhereError) -> TunnelSession
    ) -> ServeContext {
        ServeContext(
            tunnel: ServeTunnel(
                store: store, environment: [:], options: options, tsv: tsv,
                open: open),
            store: store, environment: [:], options: options, tsv: tsv,
            traceURLs: traceURLs)
    }

    /// For specs that must never reach the engine: the seam throws instead.
    static func makeNeverOpening(
        store: ConfigStore, options: ServeOptions = ServeOptions(idleStop: nil)
    ) -> ServeContext {
        make(store: store, options: options) {
            _, _, _ throws(ElsewhereError) -> TunnelSession in
            throw .tunnel("the test seam never opens")
        }
    }
}
