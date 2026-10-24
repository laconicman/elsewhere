import Foundation
internal import os
import Synchronization
import XrayCore // internal — the engine stays behind this module's own types (§5.1)

/// Owns the one `XrayCore` run a process gets (§5.4): start builds and runs the
/// generated config, waits for every inbound to accept, and stops cleanly. An actor —
/// one start at a time, and `isUp` is the caller's answer to "may I start?".
///
/// Start policy (A3, C4 §2/§4, C5 §5): `freePorts` hands back *candidates*, not
/// reservations — a port taken between the check and `run` makes `Instance.Start()`
/// fail and leaves the core in an unknown state (`core/xray.go`), so a failed `run`
/// is stopped, fresh candidates are drawn, and the whole attempt is retried once.
/// A leftover running core (`isRunning` without `isUp` — a previous lifecycle leak)
/// is stopped before the first attempt. Every `run`/`stop` is guarded by `isRunning`
/// — the edges are unpinned until swift-libxray 0.2.0 (TD-5).
///
/// One engine, one owner, *process-wide*: `owner` is the supervisor that holds the
/// core. A second supervisor's `start` is refused — never does it stop an engine it
/// doesn't own — and `stop` releases ownership only for its holder.
public actor TunnelSupervisor {
    /// Who holds the engine, across every supervisor instance in the process.
    private static let owner = Mutex<ObjectIdentifier?>(nil)
    /// The lanes the running engine serves.
    public private(set) var lanes: [XrayConfigBuilder.Lane] = []
    /// True between a ready `start` and `stop` — the guard against double-start.
    public private(set) var isUp = false
    /// True across a `start`'s awaits — the reentry guard `isUp` can't cover.
    private var starting = false
    /// The running exits' outbound secrets — `test`/`run`/`stop` messages and logs
    /// can echo config text back, so every printable form is scrubbed with these.
    private var secrets: [String] = []

    /// Test seam — defaults to the engine's `freePorts`. `nil` in the signature keeps
    /// the internal `XrayCore` out of a public default argument (same shape as Doctor).
    private let portCandidates: @Sendable (Int, [UInt16]) async throws -> [UInt16]
    private let readinessTimeout: Duration
    private let logger = Logger(subsystem: "com.learnable.elsewhere", category: "tunnel")

    public init(
        portCandidates: (@Sendable (Int, [UInt16]) async throws -> [UInt16])? = nil,
        readinessTimeout: Duration = .seconds(5)
    ) {
        self.portCandidates = portCandidates ?? {
            try await XrayCore.shared.freePorts($0, excluding: Set($1))
        }
        self.readinessTimeout = readinessTimeout
    }

    /// Brings the engine up: candidates → build → `test` → `run` → readiness poll.
    /// `includeDirect` asks for the `direct` lane — only the lanes a call needs are
    /// bound (A9). `excludingPorts` are extra loopback ports never issued (the caller
    /// passes the `proxy` exits' ports); INCY's is excluded always.
    /// - Throws: `.tunnel` when already running or when an inbound stays closed;
    ///   `.engine` on engine failures (scrubbed); `XrayConfigBuilder`'s `.exit`/`.config`.
    @discardableResult
    public func start(
        exits: [(name: String, outbound: JSONValue)],
        includeDirect: Bool,
        bindInterface: String?,
        log: XrayConfigBuilder.XrayLog,
        excludingPorts: [UInt16]
    ) async throws(ElsewhereError) -> [XrayConfigBuilder.Lane] {
        guard !isUp, !starting else { throw .tunnel("tunnel already running") }
        starting = true
        defer { starting = false }
        let me = ObjectIdentifier(self)
        guard Self.owner.withLock({ held -> Bool in
            if held == nil { held = me; return true }
            return false
        }) else {
            // Another live supervisor owns the core — its engine is not ours to stop.
            throw .tunnel(
                "the engine is already in use by another session in this process")
        }
        var keepOwnership = false
        defer {
            if !keepOwnership {
                Self.owner.withLock { if $0 == me { $0 = nil } }
            }
        }

        // Ownership is ours — a running core here is a leftover lifecycle leak.
        if await XrayCore.shared.isRunning {
            logger.notice("a leftover engine instance is running; stopping it first")
            try? await XrayCore.shared.stop()
        }

        // Everything the engine might echo back — kept for stop() too.
        secrets = exits.flatMap { Redactor.secrets(in: $0.outbound) }

        let excluded = [LocalProxy.incyPort] + excludingPorts
        var lastError: ElsewhereError?
        for attempt in 0...1 {
            if attempt > 0 { logger.notice("retrying start with fresh candidate ports") }
            let needed = exits.count + (includeDirect ? 1 : 0)
            let ports: [UInt16]
            do {
                ports = try await portCandidates(needed, excluded)
            } catch {
                throw .engine(scrub(error.localizedDescription))
            }
            guard ports.count == needed else {
                throw .engine(
                    "freePorts returned \(ports.count) candidates, "
                        + "needed \(needed)")
            }
            guard Set(ports).count == ports.count else {
                // Two lanes on one port would fail `run` — name it instead (N10).
                throw .engine("freePorts returned duplicate candidates")
            }

            var portsByName: [String: UInt16] = [:]
            for (index, lane) in exits.enumerated() {
                portsByName[lane.name] = ports[index]
            }
            // .exit/.config from here are definition errors — retrying can't help them.
            let built = try XrayConfigBuilder.build(
                exits: exits, ports: portsByName,
                directPort: includeDirect ? ports[exits.count] : nil,
                bindInterface: bindInterface, log: log)
            do {
                try await XrayCore.shared.test(configJSON: built.configJSON)
            } catch {
                throw .engine(scrub(error.localizedDescription))
            }
            do {
                try await XrayCore.shared.run(configJSON: built.configJSON)
            } catch {
                // run() failing leaves the instance in unknown state — stop it, draw
                // fresh candidates, try once more (the taken-port race, TD-2/A3).
                let message = scrub(error.localizedDescription)
                logger.warning("run failed on attempt \(attempt + 1): \(message)")
                try? await XrayCore.shared.stop()
                // A stop that didn't take leaves a running core `test`/`run` must
                // not touch again — no retry on an unclean floor (TD-5).
                guard !(await XrayCore.shared.isRunning) else {
                    throw .engine(
                        "\(message); the engine could not be stopped for a retry")
                }
                lastError = .engine(message)
                continue
            }

            // `run` returns ~350 ms before the inbounds accept (swift-libxray TD-5) —
            // poll each lane until a loopback connect succeeds. A cancelled start is
            // checked explicitly: under cancellation `isListening` fails fast and
            // `Task.sleep` throws instantly, so without the check this is a hot spin
            // to the deadline rather than a prompt unwind.
            for lane in built.lanes {
                let deadline = ContinuousClock.now + readinessTimeout
                var ready = false
                while !ready, ContinuousClock.now < deadline {
                    if Task.isCancelled {
                        await stop()
                        throw .tunnel("start cancelled")
                    }
                    ready = await LoopbackProbe.isListening(
                        port: lane.inboundPort, timeout: .milliseconds(500))
                    if !ready {
                        do {
                            try await Task.sleep(for: .milliseconds(50))
                        } catch {
                            await stop()
                            throw .tunnel("start cancelled")
                        }
                    }
                }
                guard ready else {
                    await stop()
                    throw .tunnel(
                        "inbound on 127.0.0.1:\(lane.inboundPort) did not accept within "
                            + "\(readinessTimeout.components.seconds) s")
                }
            }

            lanes = built.lanes
            isUp = true
            keepOwnership = true // ownership stays until stop()
            logger.notice("tunnel up: \(built.lanes.count) inbound lane(s)")
            return built.lanes
        }
        // Both attempts drew and failed at run — surface the engine's last message.
        throw lastError ?? .engine("the engine failed to start")
    }

    /// Stops the engine if it is running *and owned by this supervisor*; never
    /// throws — the caller is tearing down and a stuck core is logged, not fatal.
    /// Another session's core is neither stopped nor released here. Ownership is
    /// released even when the engine refuses to stop: the next `start` in this
    /// process treats the still-running core as a leftover and stops it before
    /// its own run (and refuses to run on a floor it could not clear). A dead
    /// holder keeping the engine would refuse every later session for the life
    /// of the process — the long-lived `serve` of M2 most of all.
    public func stop() async {
        let me = ObjectIdentifier(self)
        let mine = Self.owner.withLock { $0 == me }
        if mine, await XrayCore.shared.isRunning {
            do {
                try await XrayCore.shared.stop()
            } catch {
                logger.warning("stop failed: \(self.scrub(error.localizedDescription))")
            }
        }
        lanes = []
        isUp = false
        secrets = []
        if mine {
            Self.owner.withLock { if $0 == me { $0 = nil } }
        }
        logger.notice("tunnel stopped")
    }

    /// The known secrets first, then the pattern net for what couldn't be enumerated.
    private func scrub(_ text: String) -> String {
        Redactor.scrubPatterns(Redactor.scrub(text, secrets: secrets))
    }
}
