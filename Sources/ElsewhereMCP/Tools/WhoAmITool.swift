import ElsewhereKit
import Foundation
import MCP

extension ToolSpec {
    /// `elsewhere_whoami`'s only argument: the exit to probe — omitting it probes
    /// every configured exit and `direct`, like the CLI's `--all`.
    struct WhoAmIInput: Decodable, Sendable {
        var exit: String?
    }

    /// `elsewhere_whoami`: Cloudflare's trace through one exit (or every exit, on
    /// the one session, concurrently). A named exit's failure is the call's error;
    /// the all-exits form reports each failure as its own line, like the CLI.
    static func whoami(_ context: ServeContext) -> ToolSpec {
        ToolSpec(
            name: "elsewhere_whoami",
            title: "Probe an exit's egress identity",
            description: """
            Show the public IP and country each route exits in — a quick check of \
            what a fetch through an exit looks like to the site. With `exit`, \
            probes that exit (or `direct`); without it, probes every configured \
            exit and `direct`. An exit is a named route configured on this \
            machine — a tunnel or a local proxy; `direct` is the machine's own \
            path past any system VPN.
            """,
            schema: InputSchema.object([
                "exit": InputSchema.string(
                    "Probe this exit (or `direct`); omit to probe every configured exit and direct."),
            ]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false,
                idempotentHint: true, openWorldHint: true)
        ) { (input: WhoAmIInput) async throws(ElsewhereError) -> String in
            let lease = try await context.tunnel.lease()
            do throws(ElsewhereError) {
                let text = try await run(input, lease: lease, context: context)
                await context.tunnel.release()
                return text
            } catch {
                await context.tunnel.release()
                throw error
            }
        }
    }

    /// One probe when `input.exit` names a lane; every lane concurrently when it
    /// doesn't — the task group shares the lease's one session.
    static func run(
        _ input: WhoAmIInput, lease: ServeTunnel.Lease, context: ServeContext
    ) async throws(ElsewhereError) -> String {
        let userAgent = lease.config.userAgent.headerValue
        if let exit = input.exit {
            let name = try ExitSelection.named(exit).resolve(in: lease.config)
            do throws(ElsewhereError) {
                let trace = try await WhoAmI.trace(
                    via: lease.session.route(for: name), userAgent: userAgent,
                    traceURLs: context.traceURLs,
                    allowPrivate: context.options.allowPrivate)
                context.tsv?.log(
                    event: "whoami", exit: name, status: "200",
                    url: context.traceURLs.first?.absoluteString ?? "-")
                return line(name, trace)
            } catch {
                // `trace` falls back URL to URL — the last tried is the error's.
                context.tsv?.log(
                    event: "whoami", exit: name,
                    url: context.traceURLs.last?.absoluteString ?? "-")
                throw error
            }
        }
        let names = lease.config.exits.keys.sorted() + ["direct"]
        let results = await withTaskGroup(
            of: (String, Result<Trace, ElsewhereError>).self
        ) { group in
            for name in names {
                group.addTask {
                    do throws(ElsewhereError) {
                        let trace = try await WhoAmI.trace(
                            via: lease.session.route(for: name),
                            userAgent: userAgent,
                            traceURLs: context.traceURLs,
                            allowPrivate: context.options.allowPrivate)
                        return (name, .success(trace))
                    } catch {
                        return (name, .failure(error))
                    }
                }
            }
            var rows: [String: Result<Trace, ElsewhereError>] = [:]
            for await (name, result) in group { rows[name] = result }
            return rows
        }
        var lines: [String] = []
        for name in names {
            switch results[name] {
            case .success(let trace):
                context.tsv?.log(
                    event: "whoami", exit: name, status: "200",
                    url: context.traceURLs.first?.absoluteString ?? "-")
                lines.append(line(name, trace))
            case .failure(let error):
                context.tsv?.log(
                    event: "whoami", exit: name,
                    url: context.traceURLs.last?.absoluteString ?? "-")
                lines.append(
                    "exit \(name): "
                        + Redactor.scrubPatterns(error.localizedDescription))
            case nil:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `exit NAME: ip <ip> loc <loc>[ colo <colo>]` — the CLI's whoami line.
    static func line(_ name: String, _ trace: Trace) -> String {
        var line = "exit \(name): ip \(trace.ip) loc \(trace.loc)"
        if let colo = trace.colo { line += " colo \(colo)" }
        return line
    }
}
