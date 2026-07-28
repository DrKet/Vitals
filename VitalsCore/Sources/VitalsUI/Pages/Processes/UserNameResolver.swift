import Darwin
import Foundation

/// Resolves a numeric uid to its login name, caching the answer.
///
/// `getpwuid` reads the directory service, which is far too slow to call once
/// per row per tick across ~600 processes. The mapping does not change while a
/// page is open, so a plain dictionary cache is sufficient.
@MainActor
public final class UserNameResolver {

    private var cache: [uid_t: String] = [:]

    public init() {}

    /// Cached entries. Exposed for tests.
    var cachedCount: Int { cache.count }

    /// The login name for `uid`, or the uid rendered as a string when the
    /// system has no passwd entry for it.
    ///
    /// The numeric fallback is deliberate: an unknown *name* is not an unknown
    /// *owner*. Rendering an em dash here would claim we do not know who owns
    /// the process, when in fact we know exactly — we just cannot name them.
    public func name(for uid: uid_t) -> String {
        if let cached = cache[uid] { return cached }

        let resolved: String
        if let entry = getpwuid(uid), let namePointer = entry.pointee.pw_name {
            resolved = String(cString: namePointer)
        } else {
            resolved = "\(uid)"
        }

        cache[uid] = resolved
        return resolved
    }
}
