/// `fetch`'s `--format` (§5.6): `markdown` is the default, `text` the same pipeline
/// without the decorations, `raw` PR #2's byte-exact behaviour.
public enum OutputFormat: String, Sendable, CaseIterable {
    case markdown
    case text
    case raw
}
