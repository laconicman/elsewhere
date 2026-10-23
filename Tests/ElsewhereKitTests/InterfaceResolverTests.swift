import Testing
@testable import ElsewhereKit

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
}
