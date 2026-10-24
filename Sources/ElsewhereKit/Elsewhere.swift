/// The package's namespace: one version string shared by `--version` and, in M2, the
/// MCP server's implementation metadata — version drift between surfaces is a bug
/// a shared constant cannot have.
public enum Elsewhere {
    /// Set to the tag a milestone closes into, by the PR that completes it
    /// (docs/GitHubWorkflow.md).
    public static let version = "0.1.0"
}
