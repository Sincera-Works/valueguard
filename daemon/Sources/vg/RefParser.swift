import Foundation
import ValueGuardMarketplace

/// Parsing helpers for the `vg` CLI arguments.
///
/// `vg activate` / `vg uninstall` take an `author/slug` reference; `vg install`
/// takes one of three source forms — a registry `author/slug[@version]` ref, an
/// `http(s)://` / `file://` URL, or a bare filesystem path to a `.vgconfig`
/// bundle. These helpers turn the raw `String` argument into typed values the
/// `ValueGuardMarketplace` library consumes.
enum RefParser {

    /// The three forms a `vg install` source argument can take, after
    /// classification by ``classifyInstallSource(_:)``.
    enum InstallSource {
        /// A registry reference `author/slug` with an optional `@version`,
        /// resolved against the registry base by `RegistryClient`.
        case registryRef(author: String, slug: String, version: String?)
        /// A direct `http(s)://` (network) URL to a `.vgconfig` bundle.
        case url(URL)
        /// A bare filesystem path or `file://` URL to a local `.vgconfig`.
        case local(URL)
    }

    /// Classify a `vg install` source argument into one of the three forms.
    ///
    /// Decision rules (checked in order):
    ///   - Contains `"://"` → a URL. `file://` becomes ``InstallSource/local``
    ///     (the existing local install path handles it); `http://` / `https://`
    ///     becomes ``InstallSource/url`` (downloaded directly). Any other scheme
    ///     is treated as a network URL.
    ///   - Otherwise, if it looks like a registry ref — exactly one `/`, no other
    ///     path separators, and no `.vgconfig` extension — it is parsed as
    ///     ``InstallSource/registryRef`` (with an optional `@version` suffix on
    ///     the slug).
    ///   - Otherwise it is a local filesystem path (``InstallSource/local``).
    ///
    /// The `author/slug` shape is intentionally narrow so a relative path like
    /// `dir/foo.vgconfig` (a `/`, but with a file extension) or `./a/b/c` (two
    /// slashes) falls through to the local path, never the registry.
    ///
    /// - Throws: ``VGError/notFound`` if the argument has the registry `a/b@v`
    ///   shape but a malformed author/slug/version component.
    static func classifyInstallSource(_ s: String) throws -> InstallSource {
        // 1. Scheme present → a URL.
        if s.contains("://") {
            let url = resolveSource(s)
            if url.isFileURL {
                return .local(url)
            }
            return .url(url)
        }

        // 2. Registry ref shape: exactly one '/', no '.vgconfig' extension.
        //    (A bare path with a single '/' and a file extension, e.g.
        //    `bundles/foo.vgconfig`, is NOT a registry ref — fall through.)
        let slashCount = s.filter { $0 == "/" }.count
        if slashCount == 1 && !s.hasSuffix(".vgconfig") && !s.hasPrefix("/") && !s.hasPrefix(".") {
            let parsed = try parseRegistryRef(s)
            return .registryRef(author: parsed.author, slug: parsed.slug, version: parsed.version)
        }

        // 3. Everything else: a local filesystem path.
        return .local(resolveSource(s))
    }

    /// Parse a registry reference `author/slug[@version]`.
    ///
    /// The `@version` suffix is optional and attaches to the slug component
    /// (`sincera/personal-values@1.2.0`). The author and slug are validated by
    /// ``parseSlugRef(_:)``; the version, when present, must be non-empty.
    ///
    /// - Throws: ``VGError/notFound`` when malformed.
    static func parseRegistryRef(_ s: String) throws -> (author: String, slug: String, version: String?) {
        // Split an optional trailing "@version" off the whole ref. Splitting on
        // the LAST '@' keeps any (illegal but harmless) '@' in the slug with the
        // slug rather than the version; parseSlugRef then rejects a bad slug.
        var ref = s
        var version: String? = nil
        if let atIndex = s.lastIndex(of: "@") {
            ref = String(s[s.startIndex..<atIndex])
            let v = String(s[s.index(after: atIndex)...])
            guard !v.isEmpty else {
                throw VGError.notFound(
                    "malformed config reference '\(s)': empty version after '@'")
            }
            version = v
        }
        let parsed = try parseSlugRef(ref)
        return (author: parsed.author, slug: parsed.slug, version: version)
    }
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

    /// Resolve an install source argument to a URL.
    ///
    /// An argument carrying a URL scheme (`file://`, `http://`, `https://`, …) is
    /// parsed as a URL so percent-encoding is honored; anything else is treated as
    /// a plain filesystem path (relative or absolute). The returned URL is not
    /// checked for existence here — the caller (the verifier / installer /
    /// registry client) does that.
    static func resolveSource(_ s: String) -> URL {
        if s.contains("://"), let url = URL(string: s) {
            return url
        }
        return URL(fileURLWithPath: s)
    }
}
