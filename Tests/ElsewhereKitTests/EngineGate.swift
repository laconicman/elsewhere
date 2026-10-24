import Synchronization
import Testing

/// One Go runtime per process — so one engine-touching test at a time.
///
/// `.serialized` orders a suite's own tests; it does *not* stop two serialized
/// suites from running in parallel. Without a shared gate, `ExitValidator`'s
/// `testXray` lands while a supervisor suite has an instance managed ("testXray
/// requires an isolated process"), and one session's `start` stops the other's
/// running core. Every suite that reaches `XrayCore` carries `.engineGate`.
struct EngineGateTrait: SuiteTrait, TestTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        await EngineGate.shared.acquire()
        do {
            try await function()
        } catch {
            EngineGate.shared.release()
            throw error
        }
        EngineGate.shared.release()
    }
}

extension Trait where Self == EngineGateTrait {
    static var engineGate: Self { Self() }
}

/// A suspension-friendly mutex: `acquire` suspends instead of blocking a
/// cooperative-pool thread, and `release` needs no `await` (a `defer` can run it).
final class EngineGate: Sendable {
    static let shared = EngineGate()

    private let state = Mutex<(held: Bool, waiters: [CheckedContinuation<Void, Never>])>(
        (false, []))

    func acquire() async {
        await withCheckedContinuation { continuation in
            let queued = state.withLock { state -> Bool in
                if state.held {
                    state.waiters.append(continuation)
                    return true
                }
                state.held = true
                return false
            }
            if !queued { continuation.resume() }
        }
    }

    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        waiter?.resume()
    }
}
