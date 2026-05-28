import Foundation
import ValueGuardMarketplace

/// Parsing helpers for the `vg` CLI arguments.
///
/// `vg activate` / `vg uninstall` take an `author/slug` reference; `vg install`
/// takes either a `file://` URL or a bare filesystem path to a `.vgconfig`
/// bundle. These helpers turn the raw `String` argument into typed values the
/// `ValueGuardMarketplace` library consumes.
enum RefParser {
    /// Split an `author/slug` reference into its two components.
    ///
    /// The reference must contain exactly one `/` separating a non-empty
    /// author handle from a non-empty slug (`config_id`). Anything else —
    /// missing slash, more than one slash, or an empty component on either
    /// side — is malformed.
    ///
    /// - Throws: `VGError.notFound` when the reference is malformed.
    static func parseSlugRef(_ s: String) throws -> (author: String, slug: String) {
        // Split on "/" without dropping empty subsequences so that a leading,
        // trailing, or doubled slash yields an empty component we can reject.
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw VGError.notFound(
                "malformed config reference '\(s)': expected exactly one '/' as in 'author/slug'"
            )
        }
        let author = String(parts[0])
        let slug = String(parts[1])
        guard !author.isEmpty, !slug.isEmpty else {
            throw VGError.notFound(
                "malformed config reference '\(s)': author and slug must both be non-empty"
            )
        }
        return (author: author, slug: slug)
    }

    /// Resolve an install source argument to a file URL.
    ///
    /// A `file://` argument is parsed as a URL so percent-encoding is honored;
    /// anything else is treated as a plain filesystem path (relative or
    /// absolute). The returned URL is not checked for existence here — the
    /// caller (the verifier / installer) does that.
    static func resolveSource(_ s: String) -> URL {
        if s.hasPrefix("file://"), let url = URL(string: s) {
            return url
        }
        return URL(fileURLWithPath: s)
    }
}
