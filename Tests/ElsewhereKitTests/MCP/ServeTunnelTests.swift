import Foundation
import Synchronization
import Testing
@testable import ElsewhereKit
@testable import ElsewhereMCP

/// `ServeTunnel`'s lifecycle, engine-free: the `open` seam returns a real
/// proxy-only `TunnelSession` (no engine starts — the Go runtime never enters)
/// and counts the opens.
@Suite("ServeTunnel — lazy open, idle stop, backoff, reopen", .serialized, .temporaryDirectories)
struct ServeTunnelTests {
    /// How many times `open` ran — a class, because `Mutex` itself is
    /// noncopyable and can't be a closure's capture or a parameter.
    private final class Opens: Sendable {
        private let count = Mutex(0)
        func bump() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func store() throws -> ConfigStore {
        let store = ConfigStore(url: temporaryDirectory().appending(path: "config.json"))
        try store.save(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:1")!),
        ]))
        return store
    }

    /// A tunnel whose `open` counts calls, fails when `fail` says so, and
    /// otherwise opens the proxy exits the config carries — no direct lane, so
    /// no engine.
    private func tunnel(
        store: ConfigStore, options: ServeOptions,
        opens: Opens, fail: @escaping @Sendable () -> Bool = { false }
    ) -> ServeTunnel {
        ServeTunnel(store: store, environment: [:], options: options) {
            config, _, _ throws(ElsewhereError) -> TunnelSession in
            opens.bump()
            if fail() { throw ElsewhereError.engine("simulated start failure") }
            return try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: false,
                bindInterface: .none, log: .silent)
        }
    }

    /// Nothing opens until the first call; a second sequential lease reuses it.
    @Test func aLeaseOpensOnFirstCallAndReuses() async throws {
        let opens = Opens()
        let tunnel = tunnel(
            store: try store(), options: ServeOptions(idleStop: nil), opens: opens)
        let first = try await tunnel.lease()
        #expect(opens.value == 1)
        await tunnel.release()
        let second = try await tunnel.lease()
        #expect(opens.value == 1)
        // The reuse is literal: both leases hold the one session actor.
        #expect(first.session === second.session)
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// After `idleStop` of no calls the engine stops; the next lease starts it
    /// again.
    @Test(.timeLimit(.minutes(1)))
    func anIdleSessionStopsAndReopens() async throws {
        let opens = Opens()
        let tunnel = tunnel(
            store: try store(), options: ServeOptions(idleStop: .milliseconds(300)),
            opens: opens)
        let lease = try await tunnel.lease()
        _ = lease
        await tunnel.release()
        try await Task.sleep(for: .milliseconds(600))
        let again = try await tunnel.lease()
        _ = again
        #expect(opens.value == 2)
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// The idle clock only runs while nothing is in flight — a held lease keeps
    /// the session through the timeout.
    @Test(.timeLimit(.minutes(1)))
    func aHeldLeaseDefersTheIdleStop() async throws {
        let opens = Opens()
        let tunnel = tunnel(
            store: try store(), options: ServeOptions(idleStop: .milliseconds(300)),
            opens: opens)
        let held = try await tunnel.lease()
        _ = held
        try await Task.sleep(for: .milliseconds(600))
        #expect(opens.value == 1) // still held — never stopped
        await tunnel.release()
        try await Task.sleep(for: .milliseconds(600))
        let again = try await tunnel.lease()
        _ = again
        #expect(opens.value == 2) // idled off after the release, reopened
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// The SDK runs every tool call in its own task: two leases arriving while
    /// `open` is still suspended must share the one attempt — a second `open`
    /// would collide on the one Go runtime ("already in use").
    @Test func concurrentLeasesShareOneOpen() async throws {
        let opens = Opens()
        let tunnel = ServeTunnel(
            store: try store(), environment: [:],
            options: ServeOptions(idleStop: nil)
        ) { config, _, _ throws(ElsewhereError) -> TunnelSession in
            opens.bump()
            try? await Task.sleep(for: .milliseconds(200))
            return try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: false,
                bindInterface: .none, log: .silent)
        }
        async let one = tunnel.lease()
        async let two = tunnel.lease()
        let (first, second) = try await (one, two)
        #expect(opens.value == 1)
        #expect(first.session === second.session)
        await tunnel.release()
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// Leases decide one at a time: four landing after the file changed must
    /// not all find the stale session and reopen over each other — the second
    /// one's `close` would kill the first one's pending start.
    @Test func concurrentLeasesAfterAChangeShareOneReopen() async throws {
        let opens = Opens()
        let store = try store()
        let tunnel = ServeTunnel(
            store: store, environment: [:],
            options: ServeOptions(idleStop: nil)
        ) { config, _, _ throws(ElsewhereError) -> TunnelSession in
            opens.bump()
            try? await Task.sleep(for: .milliseconds(200))
            return try await TunnelSession.open(
                config: config, exits: Set(config.exits.keys), includeDirect: false,
                bindInterface: .none, log: .silent)
        }
        let first = try await tunnel.lease()
        _ = first
        await tunnel.release()
        try store.save(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:1")!),
            "q": .proxy(URL(string: "http://127.0.0.1:2")!),
        ]))
        async let one = tunnel.lease()
        async let two = tunnel.lease()
        async let three = tunnel.lease()
        async let four = tunnel.lease()
        let leases = try await (one, two, three, four)
        #expect(opens.value == 2)
        #expect(leases.0.session !== first.session)
        #expect(leases.0.session === leases.1.session)
        #expect(leases.0.session === leases.2.session)
        #expect(leases.0.session === leases.3.session)
        await tunnel.release()
        await tunnel.release()
        await tunnel.release()
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// A failed start backs off: a lease inside the window is refused without a
    /// second open attempt.
    @Test func aFailedStartBacksOff() async throws {
        let opens = Opens()
        let tunnel = tunnel(
            store: try store(), options: ServeOptions(idleStop: nil),
            opens: opens, fail: { true })
        do throws(ElsewhereError) {
            _ = try await tunnel.lease()
            Issue.record("expected the start failure")
        } catch {
            #expect(error.localizedDescription.contains("simulated start failure"))
        }
        do throws(ElsewhereError) {
            _ = try await tunnel.lease()
            Issue.record("expected the backoff refusal")
        } catch {
            #expect(error.localizedDescription.contains("backing off"))
        }
        #expect(opens.value == 1) // refused before `open` ran again
    }

    /// An edited exit — same name, new endpoint — is a routing change too: the
    /// session reopens so the engine doesn't keep the old route.
    @Test func anEditedExitReopensTheSession() async throws {
        let opens = Opens()
        let store = try store()
        let tunnel = tunnel(
            store: store, options: ServeOptions(idleStop: nil), opens: opens)
        let first = try await tunnel.lease()
        _ = first
        await tunnel.release()
        try store.save(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:2")!),
        ]))
        let second = try await tunnel.lease()
        #expect(opens.value == 2)
        let route = try await second.session.route(for: "p")
        #expect(
            route == .external(
                exit: "p", url: URL(string: "http://127.0.0.1:2")!))
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }

    /// The bind interface is routing too: a file change to it reopens — unless
    /// `--via-system` already unbound the engine, which makes the file's value
    /// moot.
    @Test func aChangedBindInterfaceReopensUnlessViaSystem() async throws {
        let opens = Opens()
        let store = try store() // bindInterface .auto
        let bound = tunnel(
            store: store, options: ServeOptions(idleStop: nil), opens: opens)
        let first = try await bound.lease()
        _ = first
        await bound.release()
        try store.save(ElsewhereConfig(
            bindInterface: .none,
            exits: ["p": .proxy(URL(string: "http://127.0.0.1:1")!)]))
        let second = try await bound.lease()
        _ = second
        #expect(opens.value == 2)
        await bound.release()
        await bound.close(reason: "eof")

        // Under --via-system the engine already rides the system path: the
        // same .auto → .none edit changes nothing it binds to.
        let systemOpens = Opens()
        try store.save(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:1")!),
        ]))
        let systemTunnel = tunnel(
            store: store, options: ServeOptions(idleStop: nil, viaSystem: true),
            opens: systemOpens)
        let third = try await systemTunnel.lease()
        _ = third
        await systemTunnel.release()
        try store.save(ElsewhereConfig(
            bindInterface: .none,
            exits: ["p": .proxy(URL(string: "http://127.0.0.1:1")!)]))
        let fourth = try await systemTunnel.lease()
        _ = fourth
        #expect(systemOpens.value == 1)
        await systemTunnel.release()
        await systemTunnel.close(reason: "eof")
    }

    /// The config is re-read per call: exits added between leases reopen the
    /// session when nothing is in flight.
    @Test func aChangedExitSetReopensTheSession() async throws {
        let opens = Opens()
        let store = try store()
        let tunnel = tunnel(store: store, options: ServeOptions(idleStop: nil), opens: opens)
        let first = try await tunnel.lease()
        _ = first
        await tunnel.release()
        try store.save(ElsewhereConfig(exits: [
            "p": .proxy(URL(string: "http://127.0.0.1:1")!),
            "q": .proxy(URL(string: "http://127.0.0.1:2")!),
        ]))
        let second = try await tunnel.lease()
        _ = second
        #expect(opens.value == 2)
        await tunnel.release()
        // Unchanged again — the reopened session serves.
        let third = try await tunnel.lease()
        _ = third
        #expect(opens.value == 2)
        await tunnel.release()
        await tunnel.close(reason: "eof")
    }
}
