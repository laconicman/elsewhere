import ElsewhereKit
import Foundation

/// The one engine `serve` holds (Design: "`serve` keeps one engine with every
/// lane, lazily"): opened on the first call that needs a route — with every
/// exit lane *and* `direct`, so switching exits never restarts the core — and
/// stopped after `options.idleStop` of no calls. A call `lease()`s the session
/// and `release()`s it when done; the idle clock runs from the last release.
///
/// The config is re-read on every lease, so `exits add` lands without a
/// restart: when the exit set changed and nothing is in flight the session is
/// reopened; when a call is in flight the current session serves and an exit
/// the file gained gets the Kit's `.exit` from `route(for:)`. A dead engine
/// (`isAlive` false) reopens the same way. A failed start backs off 1 s
/// doubling to 30 s — a call inside the window is refused without a new
/// attempt.
actor ServeTunnel {
    /// A held session: the open lanes plus the config the session was opened
    /// against — the call resolves `exit` against this read.
    struct Lease: Sendable {
        let session: TunnelSession
        let config: ElsewhereConfig
    }

    private let store: ConfigStore
    private let environment: [String: String]
    private let options: ServeOptions
    private let tsv: TSVLog?
    /// The test seam — the real opener asks `TunnelSession` for every lane and
    /// `direct`.
    private let open: @Sendable (
        ElsewhereConfig, BindInterface, XrayConfigBuilder.XrayLog
    ) async throws(ElsewhereError) -> TunnelSession

    private var session: TunnelSession?
    private var sessionExits: Set<String> = []
    /// The in-flight `open`, if any — actors reenter across an `await`, so a
    /// second `lease` during a start must share the attempt, not start its own
    /// (the engine is one Go runtime: two opens collide — "already in use").
    private var startTask: Task<Result<TunnelSession, ElsewhereError>, Never>?
    /// Bumped by every `close`: a `start` that resolves against a stale
    /// generation closes its fresh session unborn rather than resurrecting one
    /// after the teardown.
    private var generation = 0
    private var inFlight = 0
    private var lastUsed = ContinuousClock.now
    private var idleTask: Task<Void, Never>?
    private var backoff: Duration = .seconds(1)
    private var backoffUntil: ContinuousClock.Instant?

    init(
        store: ConfigStore, environment: [String: String], options: ServeOptions,
        tsv: TSVLog? = nil,
        open: @escaping @Sendable (
            ElsewhereConfig, BindInterface, XrayConfigBuilder.XrayLog
        ) async throws(ElsewhereError) -> TunnelSession = {
            try await TunnelSession.open(
                config: $0, exits: Set($0.exits.keys), includeDirect: true,
                bindInterface: $1, log: $2)
        }
    ) {
        self.store = store
        self.environment = environment
        self.options = options
        self.tsv = tsv
        self.open = open
    }

    /// The session for one call — opened, reused or reopened per the rules on
    /// the type; the caller must `release()` on every path.
    /// - Throws: `.config` when the file can't be read, `.tunnel` while the
    ///   backoff window stands, and whatever `open` throws on a fresh start.
    func lease() async throws(ElsewhereError) -> Lease {
        let config = try store.load(environment: environment)
        if let until = backoffUntil, ContinuousClock.now < until {
            throw .tunnel(
                "the tunnel is backing off after a failed start; try again shortly")
        }
        let names = Set(config.exits.keys)
        let held: TunnelSession
        if let current = session {
            // (`||`'s right side can't hold an await — the liveness ask is staged.)
            let dead = !(await current.isAlive)
            let stale = names != sessionExits || dead
            if stale, inFlight == 0 {
                // A changed exit set or a dead engine: reopen — lanes follow the file.
                await close(reason: "reopen")
                held = try await start(config, names: names)
            } else {
                // In flight (or unchanged), the current session serves as is.
                held = current
            }
        } else {
            held = try await start(config, names: names)
        }
        inFlight += 1
        idleTask?.cancel()
        return Lease(session: held, config: config)
    }

    /// Returns a lease; the idle clock arms when the last in-flight call ends.
    func release() {
        inFlight = Swift.max(0, inFlight - 1)
        lastUsed = ContinuousClock.now
        if inFlight == 0 { armIdleTimer() }
    }

    /// Stops the held session; idempotent, and only a session that was up earns
    /// the `down` row. An open still in flight is awaited and closed too — the
    /// generation bump stops its `start` from resurrecting the session after.
    func close(reason: String) async {
        idleTask?.cancel()
        idleTask = nil
        generation += 1
        var held = session
        session = nil
        sessionExits = []
        if let pending = startTask {
            if case .success(let opened) = await pending.value { held = opened }
            startTask = nil
        }
        guard let held else { return }
        await held.close()
        tsv?.log(event: "down", exit: reason)
    }

    /// One start attempt and its TSV edges — `up` carries the lane count the
    /// session was asked for (every exit + direct); a failure arms the backoff
    /// window before the error propagates. A second `lease` while the attempt
    /// runs awaits the same `startTask` and shares its outcome — success or
    /// failure — without a second `open` or a second arm.
    private func start(
        _ config: ElsewhereConfig, names: Set<String>
    ) async throws(ElsewhereError) -> TunnelSession {
        if let pending = startTask {
            let gen = generation
            switch await pending.value {
            case .success(let opened):
                guard generation == gen else {
                    throw .tunnel("the tunnel closed while it was starting")
                }
                return opened
            case .failure(let error):
                throw error
            }
        }
        let gen = generation
        let attempt = Task<Result<TunnelSession, ElsewhereError>, Never> {
            do throws(ElsewhereError) {
                return .success(try await open(
                    config, options.viaSystem ? .none : config.bindInterface,
                    options.log))
            } catch {
                return .failure(error)
            }
        }
        startTask = attempt
        switch await attempt.value {
        case .success(let opened):
            startTask = nil
            guard generation == gen else {
                // Closed underneath the open — the session dies unborn rather
                // than resurrecting after the teardown (close is idempotent).
                await opened.close()
                throw .tunnel("the tunnel closed while it was starting")
            }
            session = opened
            sessionExits = names
            backoff = .seconds(1)
            backoffUntil = nil
            tsv?.log(event: "up", exit: "\(names.count + 1)")
            return opened
        case .failure(let error):
            startTask = nil
            backoffUntil = .now + backoff
            backoff = Swift.min(backoff + backoff, .seconds(30))
            tsv?.log(
                event: "start-failed",
                url: Redactor.scrubPatterns(error.localizedDescription))
            throw error
        }
    }

    /// One task sleeping `idleStop` from the last release; on expiry it closes
    /// only if nothing is in flight and the idle stretch truly elapsed, else
    /// re-arms for the remainder.
    private func armIdleTimer() {
        idleTask?.cancel()
        guard let idle = options.idleStop else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idle)
            await self?.idleExpired()
        }
    }

    private func idleExpired() async {
        guard inFlight == 0, let idle = options.idleStop else { return }
        guard ContinuousClock.now - lastUsed >= idle else {
            armIdleTimer()
            return
        }
        await close(reason: "idle")
    }

    deinit { idleTask?.cancel() }
}
