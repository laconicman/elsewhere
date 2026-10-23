/// The exit statuses `elsewhere` documents, in one place. `elsewhere --help` prints
/// ``help``; a test holds the README's table and every ``ElsewhereError/exitStatus`` to
/// ``rows``, so a change to one can't silently miss the others — the statuses are a
/// contract for scripts and for the MCP layer (BSD `sysexits(3)` values).
public enum ExitStatus {
    /// Each status and its meaning, as the README's table states them.
    public static let rows: [(code: Int32, meaning: String)] = [
        (0, "done"),
        (1, "failed: a fetch error, or doctor found a failure"),
        (64, "usage error"),
        (69, "the engine or tunnel is unavailable"),
        (77, "the private-address guard refused the destination"),
        (78, "configuration error"),
    ]

    /// What `code` means, as ``rows`` states it; `nil` for a status elsewhere doesn't
    /// document.
    public static func meaning(of code: Int32) -> String? {
        rows.first { $0.code == code }?.meaning
    }

    /// The table for `elsewhere --help`.
    public static var help: String {
        rows.map { row in
            let code = String(row.code)
            return "  " + code + String(repeating: " ", count: 4 - code.count) + row.meaning
        }.joined(separator: "\n")
    }
}
