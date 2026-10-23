/// `exits list`'s output — one redacted line per exit, name-sorted. Lives in the Kit so
/// the MCP layer's `elsewhere_exits` (M2) prints the same redacted text.
public enum ExitsListing {
    /// `NAME  <redacted summary>  [default]`, sorted by name; a config with no exits gets
    /// the one pointer that fixes it.
    public static func lines(for config: ElsewhereConfig) -> [String] {
        guard !config.exits.isEmpty else {
            return ["no exits; add one with `elsewhere exits add NAME --link …`"]
        }
        return config.exits.sorted { $0.key < $1.key }.map { name, exit in
            var line = "\(name)  \(Redactor.summary(of: exit))"
            if name == config.default { line += "  [default]" }
            return line
        }
    }
}
