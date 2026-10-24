import ElsewhereKit

/// What every call shares — the lazy tunnel, the config seam for config-only
/// calls (`elsewhere_exits` never leases), and the launch options. One per
/// server, built in `ElsewhereServer.serve`.
struct ServeContext: Sendable {
    let tunnel: ServeTunnel
    let store: ConfigStore
    let environment: [String: String]
    let options: ServeOptions
    let tsv: TSVLog?
}
