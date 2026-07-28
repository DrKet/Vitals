import Darwin
import Testing
@testable import VitalsUI

@MainActor
@Suite("User name resolution")
struct UserNameResolverTests {

    @Test("uid 0 resolves to root on every macOS system")
    func rootResolves() {
        #expect(UserNameResolver().name(for: 0) == "root")
    }

    @Test("the current user's uid resolves to a non-empty name")
    func currentUserResolves() {
        let name = UserNameResolver().name(for: getuid())
        #expect(!name.isEmpty)
        // Must be a real name, not the numeric fallback.
        #expect(name != "\(getuid())")
    }

    @Test("a uid with no passwd entry falls back to the number, not an em dash")
    func unknownUidFallsBackToNumber() {
        // The value is known; only its name is missing. Rendering it absent
        // would claim we do not know which user owns the process.
        #expect(UserNameResolver().name(for: 999_999) == "999999")
    }

    @Test("repeated lookups of one uid are served from cache")
    func repeatedLookupsAreCached() {
        let resolver = UserNameResolver()
        let first = resolver.name(for: 0)
        let second = resolver.name(for: 0)
        #expect(first == second)
        #expect(resolver.cachedCount == 1)
    }
}
