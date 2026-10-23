/// Exit-name rules, enforced at `exits add` and on config load: the name becomes a
/// routing tag (`in:<name>`) and a CLI argument, so it stays lowercase-shell-safe.
public enum ExitName {
    /// `direct` is implicit and always present; `env` is reserved for `ELSEWHERE_LINK`'s
    /// synthesized exit (§5.2). Neither may be claimed by a stored exit.
    static let reserved: Set<String> = ["direct", "env"]

    /// - Throws: `ElsewhereError.exit` on a malformed or reserved name.
    public static func validate(_ name: String) throws(ElsewhereError) {
        // The same alphabet as DNS labels, minus the dots — a Regex literal, like
        // swift-libxray's tag check (stored on a static it would be non-Sendable).
        guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,31}/) != nil else {
            throw .exit("invalid exit name '\(name)'; must match ^[a-z0-9][a-z0-9-]{0,31}$")
        }
        guard !reserved.contains(name) else {
            throw .exit("'\(name)' is reserved for the built-in exit of that name")
        }
    }
}
