import Testing
@testable import ElsewhereKit

private let promptNil: Duration = .milliseconds(500)

/// Environment-dependent by definition: the machine may be on Wi-Fi, Ethernet, or VPN-only.
/// Assert shape and promptness only.
@Suite("InterfaceResolver — first path update, no hang")
struct InterfaceResolverTests {
    @Test func physicalInterfaceNameIsNilOrIfaceShaped() async throws {
        let name = await InterfaceResolver.physicalInterfaceName()
        if let name {
            #expect(name.wholeMatch(of: /[a-z]+[0-9]+/) != nil)
        }
    }

    @Test func resolveHonoursExplicitAndNone() async {
        #expect(await InterfaceResolver.resolve(.none) == nil)
        #expect(await InterfaceResolver.resolve(.named("en42")) == "en42")
    }

    @Test func existsMatchesTheKernel() {
        #expect(!InterfaceResolver.exists("nonexistent0"))
        #expect(InterfaceResolver.exists("lo0"))
    }

    @Test func cancelledBeforeStartResumesNilPromptly() async {
        // The race Devin flagged: cancellation before finishBox registration must
        // still answer nil — measured, not just reasoned about.
        let clock = ContinuousClock()
        let task = Task { await InterfaceResolver.physicalInterfaceName() }
        task.cancel()
        let start = clock.now
        let name = await task.value
        #expect(name == nil)
        #expect(start.duration(to: clock.now) < promptNil)
    }

    @Test func cancelledMidLookupResumesPromptly() async throws {
        let clock = ContinuousClock()
        let task = Task { await InterfaceResolver.physicalInterfaceName() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = clock.now
        let name = await task.value
        // The first path update usually lands inside 50 ms, so `name` may already be
        // the interface — legitimate, the verdict won the race. What must never happen
        // is a cancelled caller parked until the 2 s timeout.
        if name == nil {
            #expect(start.duration(to: clock.now) < promptNil)
        }
    }
}
