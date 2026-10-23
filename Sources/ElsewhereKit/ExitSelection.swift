/// Which exit a fetch-like command targets — the `--exit`/`--direct`/default triad,
/// resolved against the config once, in one place.
public enum ExitSelection: Sendable, Equatable {
    case named(String)
    case direct
    case `default`

    /// The exit name to route through: `"direct"` for the direct lane, the stored
    /// name otherwise.
    /// - Throws: `.exit` when `.default` is asked for and the config has none, or a
    ///   `.named` exit isn't configured.
    public func resolve(in config: ElsewhereConfig) throws(ElsewhereError) -> String {
        switch self {
        case .direct:
            return "direct"
        case .named(let name):
            // `--exit direct` names the lane — it is never a stored exit.
            if name == "direct" { return "direct" }
            guard config.exits[name] != nil else {
                throw .exit("no exit named '\(name)'")
            }
            return name
        case .default:
            guard let `default` = config.default else {
                throw .exit(
                    "no default exit; pass --exit NAME or --direct, "
                        + "or set one with `exits default NAME`")
            }
            return `default`
        }
    }
}
