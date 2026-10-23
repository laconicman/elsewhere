/// `fetch --max-length/--start-index` (§5.6): the same paging contract as the
/// reference MCP fetch tool — slice the rendered text by **characters**
/// (`Character`s — an emoji or a combining sequence is never split) and, when the
/// cut leaves a remainder, end with a marker the agent can continue from:
///
///     … <elsewhere:truncated next_start_index=5000 total=12345>
///
/// `maxLength <= 0` means unlimited. `startIndex` past the end returns the marker
/// alone — `next_start_index` = total, so "there is nothing more" is readable,
/// not an error.
public enum Pager {
    /// - Returns: the slice, plus a `\n<elsewhere:truncated …>` marker when a
    ///   remainder was cut off.
    public static func slice(_ text: String, startIndex: Int, maxLength: Int) -> String {
        let total = text.count // Characters — the unit the contract is in
        let start = Swift.max(0, startIndex)
        guard start < total else {
            return "<elsewhere:truncated next_start_index=\(total) total=\(total)>\n"
        }
        let remaining = total - start
        guard maxLength > 0 else {
            return String(text.dropFirst(start)) // unlimited — the whole remainder
        }
        let take = Swift.min(maxLength, remaining)
        var out = String(text.dropFirst(start).prefix(take))
        if take < remaining {
            let next = start + take
            out += "\n<elsewhere:truncated next_start_index=\(next) total=\(total)>\n"
        }
        return out
    }
}
