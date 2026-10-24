import ElsewhereKit
import Foundation // URL

/// What every call shares — the lazy tunnel, the config seam for config-only
/// calls (`elsewhere_exits` never leases), and the launch options. One per
/// server, built in `ElsewhereServer.serve`.
struct ServeContext: Sendable {
    let tunnel: ServeTunnel
    let store: ConfigStore
    let environment: [String: String]
    let options: ServeOptions
    let tsv: TSVLog?
    /// WhoAmI's probe endpoints — a field so tests point at the loopback fixture.
    /// (`var`, so it stays a defaulted memberwise-init argument; a `let` with an
    /// initial value drops out of it.)
    var traceURLs: [URL] = WhoAmI.defaultTraceURLs
}
