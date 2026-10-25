public import ArgumentParser // ExpressibleByArgument conformance below
import ElsewhereKit
import Foundation

extension OutputFormat: ExpressibleByArgument {} // String raw value — free init

/// `elsewhere fetch URL` — one URL through one exit (§5.5). The body is stdout's
/// payload; everything about the fetch is stderr or `--json`. HTTP ≥ 400 is a result
/// the agent reads, not a failure — exit stays 0. HTML renders as Markdown by
/// default (`--format`), `--max-length`/`--start-index` page long bodies.
struct FetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch one URL through an exit; the body goes to stdout, metadata to stderr or --json.",
        discussion: """
        Defaults: GET, up to \(FetchLimits.maxRedirects) redirects,
        \(FetchLimits.timeout.components.seconds) s timeout,
        a \(FetchLimits.maxBodyBytes / 1_000_000) MB body cap (truncated bodies are
        flagged), a Chrome User-Agent unless --user-agent says otherwise.
        --timeout bounds the whole fetch, not a single read. Private/local
        destinations are refused unless --allow-private. Exit status is 0 even on
        HTTP >= 400 — the status is data. --format markdown turns HTML
        into Markdown with a Source: footer (text strips the markers, raw prints
        the response bytes verbatim); --max-length N stops at N characters and
        ends the page with a <elsewhere:truncated next_start_index=M total=T>
        marker — pass M to --start-index to read on. Paging applies to rendered
        text; raw is the bytes. --json's body is always the decoded text (JSON
        cannot carry bytes). --head and --output ignore --format.
        """
    )

    @Argument(help: "The URL to fetch (http/https).")
    var url: String

    @OptionGroup var exits: ExitOptions
    @OptionGroup var tunnel: TunnelOptions
    @OptionGroup var options: GlobalOptions

    @Flag(help: "Send HEAD and print status and headers, not the body.")
    var head = false

    @Option(name: .customShort("H"), help: "An extra request header, 'Key: Value'. Repeatable.")
    var headers: [String] = []

    @Option(help: "User-Agent override (default: the config's — Chrome unless changed).")
    var userAgent: String?

    @Option(help: "Timeout in seconds — bounds the whole fetch, not a single read (default \(FetchLimits.timeout.components.seconds)).")
    var timeout = Int(FetchLimits.timeout.components.seconds)

    @Option(help: "Save the body to this file instead of printing it.")
    var output: String?

    @Flag(help: "Allow private/local destinations (off by default — see elsewhere(1)).")
    var allowPrivate = false

    @Flag(help: "Print a JSON result object on stdout instead of the body.")
    var json = false

    @Option(help: "Body format: markdown (default), text or raw. raw is the response bytes verbatim; --json still carries decoded text.")
    var format: OutputFormat = .markdown

    @Option(help: "Characters of rendered text to print (markdown/text only); 0 = unlimited (default 0).")
    var maxLength = 0

    @Option(help: "Character index to start rendered text at — a truncation marker's next_start_index.")
    var startIndex = 0

    func validate() throws {
        if output != nil, head {
            throw ValidationError("--head has no body to save; drop --output")
        }
        if output != nil, json {
            throw ValidationError("--json prints the result object; drop --output")
        }
        if timeout <= 0 {
            throw ValidationError("--timeout wants a positive number of seconds")
        }
        if startIndex < 0 {
            throw ValidationError("--start-index wants a non-negative index")
        }
        if maxLength < 0 {
            throw ValidationError("--max-length wants a non-negative count")
        }
    }

    func run() async throws {
        try await exitingWithStatus { () async throws(ElsewhereError) -> Int32 in
            guard let target = URL(string: url) else {
                // Not echoed — a "URL" can carry userinfo.
                throw .usage("cannot parse the URL argument")
            }
            var parsed: [String: String] = [:]
            for raw in headers {
                guard let colon = raw.firstIndex(of: ":") else {
                    throw .usage("-H wants 'Key: Value'")
                }
                let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
                let value = raw[raw.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { throw .usage("-H wants 'Key: Value'") }
                parsed[key] = value
            }
            let requestHeaders = parsed // let — a Sendable-safe capture
            let config = try options.store.load(
                environment: ProcessInfo.processInfo.environment)
            let ua = userAgent ?? config.userAgent.headerValue

            let result = try await withSignalCancellation { () async throws(ElsewhereError) in
                try await Session.withRoute(
                    selection: exits.selection, config: config, tunnel: tunnel
                ) { route throws(ElsewhereError) in
                    try await Fetcher.fetch(
                        FetchRequest(
                            url: target,
                            method: head ? .head : .get,
                            headers: requestHeaders,
                            userAgent: ua,
                            timeout: .seconds(timeout),
                            allowPrivate: allowPrivate),
                        via: route)
                }
            }
            try report(result)
            return 0
        }
    }

    /// Renders the result: `--json` the object, `--head` the status line + headers,
    /// `--output` the file, else the body's `OutputBody` selection on stdout.
    /// `--head`/`--output` ignore `--format`; a body TextDecoder declines is
    /// untouched by the renderer either way.
    private func report(_ result: FetchResult) throws(ElsewhereError) {
        let selection = OutputBody.select(
            result, format: format,
            startIndex: startIndex, maxLength: maxLength, head: head)
        if json {
            struct Payload: Encodable {
                let url, finalURL: String
                let status: Int
                let contentType: String?
                let exit: String
                let format: String
                let elapsedMs: Int64
                let bytes: Int
                let truncated: Bool
                let redirects: [String]
                let headers: [String: String]
                let body: String?
            }
            let elapsed = result.elapsed.components
            let payload = Payload(
                // Printed URLs keep everything but userinfo — a credential is not data.
                url: Redactor.redact(url: result.requestURL),
                finalURL: Redactor.redact(url: result.finalURL),
                status: result.status,
                contentType: result.contentType,
                exit: result.exit,
                format: format.rawValue,
                elapsedMs: elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000,
                bytes: result.body.count,
                truncated: result.truncated,
                redirects: result.redirects.map(Redactor.redact(url:)),
                headers: result.headers,
                body: OutputBody.json(selection, of: result))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                emit(String(decoding: try encoder.encode(payload), as: UTF8.self))
            } catch {
                throw .fetch("cannot encode the result: \(error.localizedDescription)")
            }
        } else if head {
            emit("HTTP \(result.status)")
            for key in result.headers.keys.sorted() {
                emit("\(key): \(result.headers[key] ?? "")")
            }
        } else if let output {
            do {
                try result.body.write(to: URL(fileURLWithPath: output))
            } catch {
                throw .fetch("cannot write \(output): \(error.localizedDescription)")
            }
            printError("saved \(result.body.count) bytes to \(output)")
        } else {
            switch selection {
            case .bytes(let data):
                // raw — the wire bytes, untouched.
                OwnStdout.handle.write(data)
            case .text(let body):
                OwnStdout.handle.write(Data(body.utf8))
            case .undecodable:
                printError(
                    "\(result.contentType ?? "unknown type"), \(result.body.count) bytes — "
                        + "pass --output FILE to save it")
            case .none:
                break // --head takes its own branch above; .none can't reach here
            }
        }
        if result.truncated {
            printError("body truncated at \(FetchLimits.maxBodyBytes / 1_000_000) MB")
        }
        if result.status >= 400 {
            // host + path, no scheme — the pattern scrub strips `scheme://` tokens.
            let host = result.finalURL.host(percentEncoded: false) ?? "-"
            printError("HTTP \(result.status) from \(host)\(result.finalURL.path())")
        }
    }
}
