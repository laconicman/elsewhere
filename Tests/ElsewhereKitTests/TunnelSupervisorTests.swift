import Foundation
import Synchronization
import Testing
import XrayCore
@testable import ElsewhereKit

/// The engine lifecycle, driven for real: `run`/`stop` against loopback `mixed`
/// inbounds. Serialized — the Go runtime is one per process.
@Suite("TunnelSupervisor — start, retry, readiness, stop", .serialized, .engineGate)
struct TunnelSupervisorTests {
    @Test func directOnlyStartThenStop() async throws {
        let supervisor = TunnelSupervisor()
        let lanes = try await supervisor.start(
            exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
        // No exits, still the direct lane: the builder always emits it.
        #expect(lanes == [.init(
            exitName: "direct", inboundPort: lanes[0].inboundPort,
            inboundTag: "in:direct", outboundTag: "out:direct")])
        #expect(await supervisor.isUp)
        for lane in lanes {
            #expect(await LoopbackProbe.isListening(port: lane.inboundPort))
        }
        await supervisor.stop()
        #expect(!(await supervisor.isUp))
        #expect(!(await LoopbackProbe.isListening(port: lanes[0].inboundPort)))

        // And it can come straight back up — one core, sequentially.
        _ = try await supervisor.start(
            exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
        #expect(await supervisor.isUp)
        await supervisor.stop()
    }

    @Test func aTakenCandidateRetriesWithFreshPorts() async throws {
        // First draw returns a port already bound — `run` fails on the taken socket —
        // and a free one; the second draw is all free. TD-2/A3: candidates are not
        // reservations.
        let squatting = try EchoServer()
        let squatPort = try await squatting.start()
        defer { squatting.stop() }

        let calls = Mutex(0)
        let supervisor = TunnelSupervisor(portCandidates: { count, excluding in
            let call = calls.withLock { c -> Int in c += 1; return c }
            if call == 1 {
                var drawn = count > 1
                    ? try await XrayCore.shared.freePorts(
                        count - 1, excluding: Set(excluding + [squatPort]))
                    : []
                drawn.insert(squatPort, at: 0)
                return drawn
            }
            return try await XrayCore.shared.freePorts(count, excluding: Set(excluding))
        })
        let lanes = try await supervisor.start(
            exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
        #expect(calls.withLock { $0 } == 2)
        #expect(lanes[0].inboundPort != squatPort)
        await supervisor.stop()
    }

    @Test func startWhileRunningIsATunnelError() async throws {
        let supervisor = TunnelSupervisor()
        try await supervisor.start(
            exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
        do {
            _ = try await supervisor.start(
                exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
            Issue.record("expected a throw")
        } catch ElsewhereError.tunnel(let message) {
            #expect(message.contains("already running"))
        } catch {
            Issue.record("expected .tunnel, got \(error)")
        }
        await supervisor.stop()
    }

    /// Process-wide ownership: a second supervisor's start is refused — the live
    /// engine is never stopped from under the first session — and freed ownership
    /// is startable again.
    @Test func aSecondSupervisorCannotTakeTheEngine() async throws {
        let first = TunnelSupervisor()
        let lanes = try await first.start(
            exits: [], includeDirect: true, bindInterface: nil,
            log: .silent, excludingPorts: [])
        let second = TunnelSupervisor()
        do {
            _ = try await second.start(
                exits: [], includeDirect: true, bindInterface: nil,
                log: .silent, excludingPorts: [])
            Issue.record("expected a throw")
        } catch ElsewhereError.tunnel(let message) {
            #expect(message.contains("already in use"))
        }
        // The first tunnel is untouched — its inbound still accepts.
        #expect(await first.isUp)
        #expect(await LoopbackProbe.isListening(port: lanes[0].inboundPort))
        await first.stop()
        // Ownership released — the second supervisor can start now.
        _ = try await second.start(
            exits: [], includeDirect: true, bindInterface: nil,
            log: .silent, excludingPorts: [])
        #expect(await second.isUp)
        await second.stop()
    }

    /// A start cancelled before it begins still runs through `run` (cancellation is
    /// cooperative), then unwinds at the readiness poll — engine stopped, promptly,
    /// no spin to the deadline.
    @Test func aCancelledStartStopsTheEngineAndReturnsPromptly() async throws {
        let supervisor = TunnelSupervisor()
        let began = ContinuousClock.now
        let task = Task {
            try await supervisor.start(
                exits: [], includeDirect: true, bindInterface: nil,
                log: .silent, excludingPorts: [])
        }
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(!(await XrayCore.shared.isRunning))
        #expect(!(await supervisor.isUp))
    }

    /// N10: `freePorts` answering the same port twice would fail `run` as a bind
    /// fight — the draw is uniqueness-checked instead.
    @Test func duplicateCandidatesAreAnEngineError() async throws {
        let supervisor = TunnelSupervisor(portCandidates: { _, _ in [49152, 49152] })
        do {
            _ = try await supervisor.start(
                exits: [("moldova", XrayConfigBuilderTests.spikeOutbound())],
                includeDirect: true, bindInterface: nil, log: .silent,
                excludingPorts: [])
            Issue.record("expected a throw")
        } catch ElsewhereError.engine(let message) {
            #expect(message.contains("duplicate"))
        } catch {
            Issue.record("expected .engine, got \(error)")
        }
    }

    @Test func anInboundThatNeverAcceptsStopsAndThrows() async throws {
        // Zero readiness budget: the first poll must answer and can't have had time —
        // the engine's inbounds take ~350 ms to accept (swift-libxray TD-5).
        let supervisor = TunnelSupervisor(readinessTimeout: .zero)
        do {
            _ = try await supervisor.start(
                exits: [], includeDirect: true, bindInterface: nil, log: .silent, excludingPorts: [])
            Issue.record("expected a throw")
        } catch ElsewhereError.tunnel(let message) {
            #expect(message.contains("did not accept"))
        } catch {
            Issue.record("expected .tunnel, got \(error)")
        }
        #expect(!(await supervisor.isUp))
        // Nothing left bound: stop() ran inside start's timeout path.
        #expect(!(await XrayCore.shared.isRunning))
    }
}
