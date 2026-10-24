import ElsewhereKit
import Foundation
import MCP

/// One tool: its definition, and a handler from the call's arguments to the
/// result text — devin-kick's `ToolSpec`, over `ElsewhereError`.
struct ToolSpec: Sendable {
    let tool: Tool
    /// Decodes the arguments into the tool's own input, then runs it. It runs
    /// `@concurrent`: the SDK starts each handler from its `Server` actor, so under
    /// `NonisolatedNonsendingByDefault` a handler's synchronous stretches would
    /// otherwise stall the dispatch of every other call.
    let run: @concurrent @Sendable (
        _ arguments: [String: Value]
    ) async throws(ElsewhereError) -> String

    init<Input: Decodable & Sendable>(
        name: String, title: String, description: String, schema: Value,
        annotations: Tool.Annotations,
        body: @escaping @concurrent @Sendable (Input) async throws(ElsewhereError) -> String
    ) {
        tool = Tool(
            name: name, title: title, description: description,
            inputSchema: schema, annotations: annotations)
        run = { arguments throws(ElsewhereError) in
            try await body(try ToolInput.decode(Input.self, from: arguments, schema: schema))
        }
    }
}

/// The server's tools, and the one boundary every call crosses: look the tool up,
/// decode its arguments, run it, render — devin-kick's `Toolbox`.
struct Toolbox: Sendable {
    let specs: [ToolSpec]

    var tools: [Tool] { specs.map(\.tool) }

    /// The result of the call `params` names. An ``ElsewhereError`` becomes an
    /// `isError` result — it is advice for the model, which a thrown error would
    /// turn into a protocol error — rendered as the CLI's contract: the message,
    /// then the status the CLI would exit with and what it means. Two things are
    /// thrown: an unknown tool, a protocol error by the MCP spec (2025-11-25,
    /// "Error Handling"), and cancellation, so the SDK sends no response at all.
    ///
    /// `@concurrent`, so the lookup, the decode and the render run off the SDK's
    /// `Server` actor too (DeepWiki on swift-sdk, 2026-10-19).
    @concurrent func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let spec = specs.first(where: { $0.tool.name == params.name }) else {
            throw MCPError.invalidParams(
                "Unknown tool: \(params.name). This server's tools: "
                    + specs.map(\.tool.name).joined(separator: ", ") + ".")
        }
        let text: String
        var isError = false
        do throws(ElsewhereError) {
            text = try await spec.run(params.arguments ?? [:])
        } catch {
            text = "\(error.localizedDescription)\nstatus \(error.exitStatus): "
                + (ExitStatus.meaning(of: error.exitStatus) ?? "failed")
            isError = true
        }
        try Task.checkCancellation()
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: isError)
    }
}
