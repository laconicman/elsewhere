public import Foundation // URL is public API

/// How URLSession reaches one exit (§5.5): an `inbound` route is a `mixed` listener the
/// engine binds on 127.0.0.1 (HTTP CONNECT); an `external` route is a `proxy` exit —
/// URLSession talks to that proxy directly and Xray is not involved (A9).
public enum Route: Sendable, Equatable {
    /// A tunnel lane: `httpCONNECTProxy` at 127.0.0.1:`port`.
    case inbound(exit: String, port: UInt16)
    /// A configured external proxy (INCY), used with its own URL's scheme/userinfo.
    case external(exit: String, url: URL)

    /// The exit this route serves — `"direct"` is an exit name like any other here.
    public var exitName: String {
        switch self {
        case .inbound(let exit, _), .external(let exit, _): exit
        }
    }
}
