import ElsewhereKit
import Foundation
import MCP

extension ToolSpec {
    /// `elsewhere_fetch`'s arguments — the reference fetch tool's (deepwiki-mcp's
    /// `fetch`) plus `exit`; `--allow-private` is a serve flag, not an argument,
    /// so a page cannot talk a model into fetching the LAN.
    struct FetchInput: Decodable, Sendable {
        var url: String
        var exit: String?
        var maxLength: Int?
        var startIndex: Int?
        var raw: Bool?
        var followRedirects: Bool?

        enum CodingKeys: String, CodingKey {
            case url, exit
            case maxLength = "max_length"
            case startIndex = "start_index"
            case raw
            case followRedirects = "follow_redirects"
        }
    }

    /// `elsewhere_fetch`: one URL through one exit — four header lines, then the
    /// body rendered as Markdown (or decoded text under `raw`), paged by
    /// `max_length`/`start_index`. An HTTP ≥ 400 is a result, not an error: the
    /// status is data, like the CLI's exit 0.
    static func fetch(_ context: ServeContext) -> ToolSpec {
        ToolSpec(
            name: "elsewhere_fetch",
            title: "Fetch a URL through an exit",
            description: """
            Fetch a URL through an elsewhere exit and return its content as Markdown \
            (HTML is converted; other text is returned as is). An exit is a named route \
            configured on this machine — a tunnel or a local proxy — or `direct`, the \
            machine's own path past any system VPN; omit `exit` for the configured \
            default. Use this when a page is unreachable or blocked from the agent's \
            own network. The result starts with four header lines (url, status, \
            content-type, exit · elapsed) and then the body; HTTP errors are returned \
            as results with their status. Long pages are paged: `max_length` (default \
            5000, at most 200000) characters from `start_index` (default 0), and a \
            `<elsewhere:truncated next_start_index=N total=T>` marker when more \
            remains — call again with start_index = N. `raw: true` returns the page's \
            text without HTML→Markdown conversion. `follow_redirects: false` \
            (default true) does not follow redirects — the 3xx response is the \
            result and its `location` header line says where it pointed.
            """,
            schema: InputSchema.object([
                "url": InputSchema.string("The URL to fetch (http/https)."),
                "exit": InputSchema.string(
                    "The exit to route through; omit for the configured default, or `direct` for the machine's own path."),
                "max_length": InputSchema.integer(
                    "Characters of the body to return (default 5000).", minimum: 1, maximum: 200_000),
                "start_index": InputSchema.integer(
                    "Character index to start the body at — a truncation marker's next_start_index (default 0).",
                    minimum: 0),
                "raw": InputSchema.boolean(
                    "Return the decoded text without HTML→Markdown conversion (default false)."),
                "follow_redirects": InputSchema.boolean(
                    "Follow redirects (default true); false returns the 3xx response itself — its location header says where it pointed."),
            ], required: ["url"]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false,
                idempotentHint: true, openWorldHint: true)
        ) { (input: FetchInput) async throws(ElsewhereError) -> String in
            guard let target = URL(string: input.url) else {
                // Not echoed — a "URL" can carry userinfo.
                throw .usage("url is not a URL")
            }
            let maxLength = input.maxLength ?? 5_000
            guard (1...200_000).contains(maxLength) else {
                throw .usage("max_length is 1 to 200000")
            }
            let startIndex = input.startIndex ?? 0
            guard startIndex >= 0 else {
                throw .usage("start_index is 0 or more")
            }
            let selection: ExitSelection =
                input.exit.map(ExitSelection.named) ?? .default
            let lease = try await context.tunnel.lease()
            var exitName = "-"
            do throws(ElsewhereError) {
                exitName = try selection.resolve(in: lease.config)
                let result = try await Fetcher.fetch(
                    FetchRequest(
                        url: target,
                        userAgent: lease.config.userAgent.headerValue,
                        maxRedirects: (input.followRedirects ?? true)
                            ? FetchLimits.maxRedirects : 0,
                        allowPrivate: context.options.allowPrivate),
                    via: lease.session.route(for: exitName))
                await context.tunnel.release()
                context.tsv?.log(
                    event: "fetch", exit: exitName, status: "\(result.status)",
                    bytes: "\(result.body.count)",
                    ms: "\(milliseconds(result.elapsed))",
                    url: Redactor.redact(url: result.finalURL))
                return render(
                    result, startIndex: startIndex, maxLength: maxLength,
                    raw: input.raw ?? false)
            } catch {
                await context.tunnel.release()
                context.tsv?.log(
                    event: "fetch", exit: exitName,
                    url: Redactor.redact(url: target))
                throw error
            }
        }
    }

    /// Header lines, the `note` the 5 MB cap earns, a blank line, then the body —
    /// the CLI's stderr metadata folded into the result, where the model reads it.
    static func render(
        _ result: FetchResult, startIndex: Int, maxLength: Int, raw: Bool
    ) -> String {
        var lines = [
            "url: \(Redactor.redact(url: result.finalURL))",
            "status: \(result.status)",
            "content-type: \(result.contentType ?? "-")",
            "exit: \(result.exit) · \(milliseconds(result.elapsed)) ms",
        ]
        // With `follow_redirects: false` the 3xx is the result — surface the
        // hop target (already userinfo-scrubbed in `headers`).
        if let location = result.headers["location"] {
            lines.append("location: \(location)")
        }
        if result.truncated {
            lines.append(
                "note: body cut at the \(FetchLimits.maxBodyBytes / 1_000_000) MB cap")
        }
        let body: String
        switch OutputBody.select(
            result, format: raw ? .raw : .markdown,
            startIndex: startIndex, maxLength: maxLength, head: false)
        {
        case .text(let text):
            body = text
        case .bytes(let data):
            // `raw` is unrendered, not unpaged: decode, then the same slice.
            if let decoded = OutputBody.json(.bytes(data), of: result) {
                body = Pager.slice(
                    decoded, startIndex: startIndex, maxLength: maxLength)
            } else {
                body = binaryLine(result)
            }
        case .undecodable:
            body = binaryLine(result)
        case .none:
            body = "" // head is never selected here
        }
        return (lines + ["", body]).joined(separator: "\n")
    }

    /// A body `TextDecoder` declined: the tool can't write files — the CLI can.
    static func binaryLine(_ result: FetchResult) -> String {
        "binary body (\(result.contentType ?? "unknown type"), \(result.body.count) bytes) — "
            + "use the CLI: elsewhere fetch \(Redactor.redact(url: result.requestURL)) --output FILE"
    }

    /// Whole milliseconds — the `elapsedMs`/`ms` convention everywhere else.
    static func milliseconds(_ elapsed: Duration) -> Int64 {
        elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
    }
}
