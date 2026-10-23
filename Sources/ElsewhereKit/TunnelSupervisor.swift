import Foundation
internal import os
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
public actor TunnelSupervisor {
    /// The lanes the running engine serves — `direct` among them (the builder adds it).
    public private(set) var lanes: [XrayConfigBuilder.Lane] = []
    /// True between a ready `start` and `stop` — the guard against double-start.
    public private(set) var isUp = false

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
    /// `excludingPorts` are extra loopback ports never issued (the caller passes the
    /// `proxy` exits' ports); INCY's is excluded always.
    /// - Throws: `.tunnel` when already running or when an inbound stays closed;
    ///   `.engine` on engine failures (scrubbed); `XrayConfigBuilder`'s `.exit`/`.config`.
    @discardableResult
    public func start(
        exits: [(name: String, outbound: JSONValue)],
        bindInterface: String?,
        log: XrayConfigBuilder.XrayLog,
        excludingPorts: [UInt16]
    ) async throws(ElsewhereError) -> [XrayConfigBuilder.Lane] {
        guard !isUp else { throw .tunnel("tunnel already running") }
        if await XrayCore.shared.isRunning {
            logger.notice("a leftover engine instance is running; stopping it first")
            try? await XrayCore.shared.stop()
        }

        let excluded = [LocalProxy.incyPort] + excludingPorts
        var lastError: ElsewhereError?
        for attempt in 0...1 {
            if attempt > 0 { logger.notice("retrying start with fresh candidate ports") }
            let ports: [UInt16]
            do {
                ports = try await portCandidates(exits.count + 1, excluded)
            } catch {
                throw .engine(Redactor.scrubPatterns(error.localizedDescription))
            }
            guard ports.count == exits.count + 1 else {
                throw .engine(
                    "freePorts returned \(ports.count) candidates, "
                        + "needed \(exits.count + 1)")
            }

            var portsByName: [String: UInt16] = [:]
            for (index, lane) in exits.enumerated() {
                portsByName[lane.name] = ports[index]
            }
            // .exit/.config from here are definition errors — retrying can't help them.
            let built = try XrayConfigBuilder.build(
                exits: exits, ports: portsByName,
                directPort: ports[exits.count], bindInterface: bindInterface, log: log)
            do {
                try await XrayCore.shared.test(configJSON: built.configJSON)
            } catch {
                throw .engine(Redactor.scrubPatterns(error.localizedDescription))
            }
            do {
                try await XrayCore.shared.run(configJSON: built.configJSON)
            } catch {
                // run() failing leaves the instance in unknown state — stop it, draw
                // fresh candidates, try once more (the taken-port race, TD-2/A3).
                let message = Redactor.scrubPatterns(error.localizedDescription)
                logger.warning("run failed on attempt \(attempt + 1): \(message)")
                try? await XrayCore.shared.stop()
                lastError = .engine(message)
                continue
            }

            // `run` returns ~350 ms before the inbounds accept (swift-libxray TD-5) —
            // poll each lane until a loopback connect succeeds.
            for lane in built.lanes {
                let deadline = ContinuousClock.now + readinessTimeout
                var ready = false
                while !ready, ContinuousClock.now < deadline {
                    ready = await LoopbackProbe.isListening(
                        port: lane.inboundPort, timeout: .milliseconds(500))
                    if !ready { try? await Task.sleep(for: .milliseconds(50)) }
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
            logger.notice("tunnel up: \(built.lanes.count) inbound lane(s)")
            return built.lanes
        }
        // Both attempts drew and failed at run — surface the engine's last message.
        throw lastError ?? .engine("the engine failed to start")
    }

    /// Stops the engine if it is running; never throws — the caller is tearing down
    /// and a stuck core is logged, not fatal.
    public func stop() async {
        if await XrayCore.shared.isRunning {
            do {
                try await XrayCore.shared.stop()
            } catch {
                logger.warning(
                    "stop failed: \(Redactor.scrubPatterns(error.localizedDescription))")
            }
        }
        lanes = []
        isUp = false
        logger.notice("tunnel stopped")
    }
}
