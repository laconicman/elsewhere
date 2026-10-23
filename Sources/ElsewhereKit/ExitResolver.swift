import Foundation
import XrayCore // internal — the engine stays behind this module's own types (§5.1)

/// Turns one stored exit into the outbound object the generated config splices in (§5.3).
/// Links convert through the engine at tunnel start and are never stored converted; a
/// `proxy` exit yields `nil` — URLSession talks to it directly, Xray is not involved.
public enum ExitResolver {
    /// - Throws: `ElsewhereError.engine` (the engine's message, scrubbed of the link's
    ///   secrets) or `.exit` when a link resolves to a wrong number of outbounds.
    public static func outbound(for exit: Exit, named name: String) async throws(ElsewhereError)
        -> JSONValue?
    {
        switch exit {
        case .proxy:
            return nil
        case .xray(let value):
            // C5 §1–2: the loader accepts the flat shape and the classic `vnext`/`servers`
            // one, so pasted JSON (INCY's export carries `{"outbounds":[<one>]}`) works —
            // unwrap exactly one outbound, pass everything else through to `test`.
            guard case .object(let object) = value,
                case .array(let outbounds) = object["outbounds"]
            else { return value }
            guard outbounds.count == 1, case .object = outbounds[0] else {
                throw .exit("xray exit '\(name)' wraps \(outbounds.count) outbounds, expected 1")
            }
            return outbounds[0]
        case .link(let link):
            let data: Data
            do throws(XrayError) {
                data = try await XrayCore.shared.convertShareLinks(link)
            } catch {
                let secrets = Redactor.secrets(inLink: link) + [link]
                throw .engine(Redactor.scrub(error.errorDescription ?? error.message, secrets: secrets))
            }
            struct Envelope: Decodable { let outbounds: [JSONValue] }
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: data)
            } catch {
                throw .exit("link for '\(name)': cannot read converted outbounds")
            }
            // One link per call — but the converter drops unparseable text silently, so
            // the count is checked rather than assumed (C4 §1).
            guard envelope.outbounds.count == 1 else {
                throw .exit(
                    "link for '\(name)' yielded \(envelope.outbounds.count) outbounds, expected 1")
            }
            return envelope.outbounds[0]
        }
    }
}
