public import Foundation // `LocalizedError` conformance is public API
import XrayCore // internal — XrayError stays out of the public API (plan §5.1)

/// One error type for everything the Kit throws, so the CLI (and later the MCP layer)
/// maps every failure to a stable exit status and a redaction-safe description.
///
/// The `exitStatus` table is part of the contract — `elsewhere`'s callers script it:
/// BSD `sysexits(3)` values, matching the README's table.
public enum ElsewhereError: Error, Sendable {
    /// Bad arguments or combinations — EX_USAGE.
    case usage(String)
    /// Config file absent, unreadable, or ill-formed — EX_CONFIG.
    case config(String)
    /// A bad exit definition or name — EX_CONFIG.
    case exit(String)
    /// The engine (`XrayCore`) reported an error — EX_UNAVAILABLE. The message is
    /// `XrayError.errorDescription` verbatim ("method: message"), scrubbed of secrets.
    case engine(String)
    /// The tunnel could not come up — EX_UNAVAILABLE.
    case tunnel(String)
    /// A fetch failed — plain 1, not a sysexits value: HTTP problems carry status already.
    case fetch(String)
    /// The private-address guard refused a destination — EX_NOPERM.
    case refused(String)
}

extension ElsewhereError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .usage(let message), .config(let message), .exit(let message),
            .engine(let message), .tunnel(let message), .fetch(let message),
            .refused(let message):
            message
        }
    }
}

extension ElsewhereError {
    /// Wraps an engine error, keeping its verbatim "method: message". Callers handling a
    /// raw link should scrub first (`Redactor.scrub`) — the engine echoes
    /// input text back in some failure messages.
    static func engine(_ error: XrayError) -> ElsewhereError {
        .engine(error.errorDescription ?? error.message)
    }
}

extension ElsewhereError {
    /// BSD `sysexits(3)` statuses; the table is a contract — `ExitStatus.rows`, the
    /// README's table and `--help` change with it, in one PR.
    public var exitStatus: Int32 {
        switch self {
        case .usage: 64 // EX_USAGE
        case .config, .exit: 78 // EX_CONFIG
        case .engine, .tunnel: 69 // EX_UNAVAILABLE
        case .fetch: 1 // transport failure only — HTTP ≥ 400 is data, not this
        case .refused: 77 // EX_NOPERM — the private-address guard refused
        }
    }
}
