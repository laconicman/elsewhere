import ElsewhereKit
import Foundation
import MCP

extension ToolSpec {
    /// `elsewhere_exits` takes no arguments — the schema is an empty object.
    struct ExitsInput: Decodable, Sendable {}

    /// `elsewhere_exits`: the `exits list` lines plus `direct` — a config-only
    /// call, so it reads the file itself and never leases the tunnel.
    static func exits(_ context: ServeContext) -> ToolSpec {
        ToolSpec(
            name: "elsewhere_exits",
            title: "List the configured exits",
            description: """
            List the exits configured on this machine — name, kind (link, xray, \
            proxy) and endpoint, credentials redacted — and which one is the \
            default; `direct` is always available. An exit is a named route a \
            fetch goes through; pass a name as `exit` to elsewhere_fetch or \
            elsewhere_whoami.
            """,
            schema: InputSchema.object([:]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false,
                idempotentHint: true, openWorldHint: false)
        ) { (_: ExitsInput) async throws(ElsewhereError) -> String in
            let config = try context.store.load(environment: context.environment)
            var lines = ExitsListing.lines(for: config)
            let direct: String
            switch context.options.bindInterface(for: config) {
            case .auto:
                direct = "direct  the machine's own path (bound to the first physical interface — auto)"
            case .named(let name):
                direct = "direct  the machine's own path (bound to \(name))"
            case .none:
                direct = "direct  the machine's own path (unbound — the system path)"
            }
            lines.append(direct)
            return lines.joined(separator: "\n")
        }
    }
}
