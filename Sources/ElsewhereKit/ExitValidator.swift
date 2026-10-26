import Foundation
import XrayCore // internal — the engine stays behind this module's own types (§5.1)

/// `exits add`'s gate: a new exit is validated by the engine *before* it is saved, so a
/// typo fails at add and not at fetch. Returns the exit to STORE — `.link` unchanged
/// (never stored converted), `.xray` as the *unwrapped* single outbound (the stored
/// value is what `exits list` summarizes; a wrapper would list as "invalid"), `.proxy`
/// unchanged (URLSession's concern at fetch time — the engine has no say over it).
public enum ExitValidator {
    /// - Throws: `ElsewhereError.engine` when the engine rejects the outbound —
    ///   scrubbed of the exit's secrets and anything secret-shaped — or `.exit` for a
    ///   structurally wrong exit (a link converting to a wrong count, a wrapper that
    ///   isn't exactly one outbound).
    public static func validate(
        _ exit: Exit, named name: String
    ) async throws(ElsewhereError)
        -> Exit
    {
        switch exit {
        case .proxy:
            return exit
        case .link(let link):
            guard let outbound = try await ExitResolver.outbound(for: exit, named: name)
            else { return exit }
            try await assertBuildable(
                outbound, named: name,
                secrets: Redactor.secrets(inLink: link) + [link])
            return exit
        case .xray:
            guard let outbound = try await ExitResolver.outbound(for: exit, named: name)
            else { return exit }
            try await assertBuildable(
                outbound, named: name, secrets: [])
            return .xray(outbound) // stored unwrapped — what `exits list` reads
        }
    }

    /// A candidate config — this outbound plus `direct`, silent log, unbound — run
    /// through the engine's own validator (`test` binds nothing, C5 §3). `freePorts`
    /// failure is `.engine` too: no ports, no validation. Internal, not private:
    /// `TunnelSession` gates each exit through the same check so one bad outbound
    /// is isolated instead of sinking `open`. It validates the exit's outbound
    /// shape only: `directDNS` is unbound here (never read), and is validated by
    /// `doctor` and again at a bound tunnel's start.
    static func assertBuildable(
        _ outbound: JSONValue, named name: String, secrets: [String]
    ) async throws(ElsewhereError) {
        let ports: [UInt16]
        do throws(XrayError) {
            ports = try await XrayCore.shared.freePorts(2)
        } catch {
            throw .engine(scrub(error.errorDescription ?? error.message, secrets: secrets))
        }
        let built = try XrayConfigBuilder.build(
            exits: [(name, outbound)], ports: [name: ports[0]],
            directPort: ports[1], bindInterface: nil, log: .silent)
        do throws(XrayError) {
            try await XrayCore.shared.test(configJSON: built.configJSON)
        } catch {
            throw .engine(scrub(
                error.errorDescription ?? error.message,
                secrets: secrets + Redactor.secrets(in: outbound)))
        }
    }

    /// The exit's enumerable secrets first, then the pattern pass for what couldn't be.
    private static func scrub(_ text: String, secrets: [String]) -> String {
        Redactor.scrubPatterns(Redactor.scrub(text, secrets: secrets))
    }
}
