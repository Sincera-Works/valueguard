import Foundation

/// Resolves `author/slug[@version]` references against a static registry and
/// downloads the named bundle blob to a temp file, content-verifying the bytes
/// before handing them off.
///
/// The registry is a static file tree (`index.json` + content-addressed bundle
/// blobs under `bundles/`). This client:
///
/// 1. Fetches `index.json` from the base URL and decodes it
///    (``RegistryIndex/decode(from:)``).
/// 2. Resolves an `author/slug[@version]` reference to a concrete
///    ``RegistryIndex/Version`` — the requested version, or the highest
///    non-prerelease SemVer when no version is given.
/// 3. Downloads the version's `bundle_path` (resolved against the base) to a
///    fresh temp file, and **re-hashes the downloaded bytes**, refusing to
///    return any download whose SHA-256 does not equal the index's
///    `bundle_sha256`. This is the content-address check: a corrupted, truncated,
///    or substituted blob is rejected *before* it ever reaches the verify /
///    install path (which then independently re-runs the full offline pipeline,
///    so the index is never trusted for anything but locating bytes).
///
/// ## Transport
/// Both `http(s)://` and `file://` base URLs are supported. `file://` exercises
/// the entire resolve + download + content-check loop with **no network**, which
/// is what the test suite uses (a `file://` registry built by `vg reindex`).
/// `https://` is the production transport and shares the same code path.
///
/// ## Threading
/// The public API is synchronous (a CLI has no event loop to await on). The
/// `https` path bridges an async `URLSession` call across a `DispatchSemaphore`,
/// the established pattern for one-shot downloads. The `file://` path reads the
/// bytes directly (no session needed). Either way the caller blocks until the
/// bundle is on disk and content-verified, or a ``VGError`` is thrown.
public struct RegistryClient {
    /// The prototype default registry base URL.
    ///
    /// ⚠️ PROTOTYPE PLACEHOLDER — repoint at deploy time. This is the single
    /// place the default lives; the `vg` CLI's precedence is
    /// `--registry <url>` > `VALUEGUARD_REGISTRY` env var > this constant. It is
    /// the static-hosting target the marketplace prototype is wired against and
    /// is expected to change when the registry is actually deployed.
    public static let defaultRegistryBase = "https://valueguard-configs.pages.dev"

    /// The resolved registry base URL (an `index.json`-relative root). May be a
    /// directory URL with or without a trailing slash; path resolution normalizes
    /// it so `index.json` and the relative `bundle_path` resolve correctly.
    public let baseURL: URL

    /// Per-request timeout for the `https` transport (seconds). Mirrors
    /// `ModelDownloader`'s 60s request timeout.
    private let timeout: TimeInterval

    /// Build a client for a base registry URL.
    ///
    /// - Parameters:
    ///   - baseURL: the registry root the `index.json` and bundle blobs live
    ///     under (an `http(s)://` or `file://` URL).
    ///   - timeout: per-request timeout for the `https` transport.
    public init(baseURL: URL, timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    // MARK: - Resolution result

    /// A resolved registry reference: the matched catalog config, the concrete
    /// version selected, and the absolute URL of its bundle blob.
    public struct Resolved: Sendable {
        /// The matched catalog config (carries author/slug/name/fingerprint).
        public let config: RegistryIndex.Config
        /// The concrete selected version.
        public let version: RegistryIndex.Version
        /// The absolute bundle blob URL (the version's `bundle_path` resolved
        /// against the registry base).
        public let bundleURL: URL

        public init(config: RegistryIndex.Config, version: RegistryIndex.Version, bundleURL: URL) {
            self.config = config
            self.version = version
            self.bundleURL = bundleURL
        }
    }

    // MARK: - Index

    /// Fetch and decode the registry's `index.json`.
    ///
    /// Resolves `index.json` against ``baseURL`` and fetches it over the matching
    /// transport (`https` or `file://`), then decodes it.
    ///
    /// - Throws: ``VGError/notFound`` if the index cannot be fetched or decoded,
    ///   ``VGError/io`` on an unexpected transport failure.
    public func fetchIndex() throws -> RegistryIndex {
        let indexURL = resolve("index.json")
        let data = try fetch(indexURL, what: "index.json")
        return try RegistryIndex.decode(from: data)
    }

    // MARK: - Resolve

    /// Resolve an `author/slug[@version]` reference against the registry index.
    ///
    /// When no `@version` is given, the config's highest non-prerelease SemVer is
    /// selected (the index's `latest_version`, cross-checked against the
    /// `versions` list). When a `@version` is given, that exact version must be
    /// present.
    ///
    /// - Parameters:
    ///   - author: the author handle.
    ///   - slug: the config slug.
    ///   - version: the requested exact version, or `nil` for the latest.
    /// - Throws: ``VGError/notFound`` if the index has no such config / version.
    public func resolve(author: String, slug: String, version: String?) throws -> Resolved {
        let index = try fetchIndex()
        return try resolve(in: index, author: author, slug: slug, version: version)
    }

    /// Resolve against an already-fetched index (no network). Factored out so
    /// callers that already hold an index (e.g. `vg search`) can reuse it, and so
    /// the resolution logic is unit-testable without a transport.
    public func resolve(
        in index: RegistryIndex,
        author: String,
        slug: String,
        version: String?
    ) throws -> Resolved {
        guard let config = index.configs.first(where: { $0.author == author && $0.slug == slug }) else {
            throw VGError.notFound("registry has no config '\(author)/\(slug)'")
        }

        let selected: RegistryIndex.Version
        if let version, !version.isEmpty {
            guard let match = config.versions.first(where: { $0.version == version }) else {
                let available = config.versions.map { $0.version }.joined(separator: ", ")
                throw VGError.notFound(
                    "registry has no version '\(version)' of '\(author)/\(slug)' "
                    + "(available: \(available.isEmpty ? "none" : available))")
            }
            selected = match
        } else {
            // No version requested: prefer the index's stated latest_version, but
            // fall back to the newest-first ordering of `versions` if the index's
            // latest_version is somehow absent from the list (defensive).
            if let latest = config.versions.first(where: { $0.version == config.latestVersion }) {
                selected = latest
            } else if let newest = config.versions.first {
                selected = newest
            } else {
                throw VGError.notFound("registry config '\(author)/\(slug)' has no versions")
            }
        }

        let bundleURL = resolve(selected.bundlePath)
        return Resolved(config: config, version: selected, bundleURL: bundleURL)
    }

    // MARK: - Download

    /// Download a resolved version's bundle blob to a fresh temp `.vgconfig` and
    /// verify the downloaded bytes' SHA-256 matches the index's `bundle_sha256`
    /// **before** returning.
    ///
    /// The returned file is owned by the caller (it is created under
    /// `temporaryDirectory`); the caller should hand it to
    /// ``BundleVerifier/verify(bundleAt:)`` / ``Installer/install(bundleAt:)`` and
    /// remove it when done. On any failure — transport error or sha mismatch —
    /// the partial temp file is removed and a ``VGError`` is thrown, so a failed
    /// download never leaves a file behind.
    ///
    /// - Throws: ``VGError/notFound`` / ``VGError/io`` on a transport failure,
    ///   ``VGError/hashMismatch`` if the downloaded bytes do not match the
    ///   content address.
    public func download(_ resolved: Resolved) throws -> URL {
        let data = try fetch(resolved.bundleURL, what: resolved.version.bundlePath)

        // Content-address check: the index names the expected whole-file SHA-256;
        // a corrupted / truncated / substituted blob is rejected here, before the
        // bytes ever reach the verify+install pipeline.
        let got = Hashing.sha256Hex(data)
        let expected = resolved.version.bundleSha256
        guard got == expected else {
            throw VGError.hashMismatch(field: "bundle_sha256", expected: expected, got: got)
        }

        // Land the verified bytes in a fresh temp file the caller can verify and
        // install. Naming after the sha keeps it recognizable in temp listings.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-download-\(expected.prefix(16))-\(UUID().uuidString).vgconfig")
        do {
            try data.write(to: dest, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw VGError.io("could not write downloaded bundle to \(dest.path): \(error.localizedDescription)")
        }
        return dest
    }

    /// Convenience: resolve `author/slug[@version]` and download in one call,
    /// returning the verified temp bundle plus the resolution (so the CLI can
    /// print which concrete version it fetched).
    public func resolveAndDownload(
        author: String,
        slug: String,
        version: String?
    ) throws -> (bundle: URL, resolved: Resolved) {
        let resolved = try resolve(author: author, slug: slug, version: version)
        let bundle = try download(resolved)
        return (bundle, resolved)
    }

    /// Download a bundle directly from an arbitrary URL to a fresh temp file,
    /// **without** an index sha pre-check.
    ///
    /// Used for `vg install https://…/foo.vgconfig`, where there is no `index.json`
    /// entry to content-check against. There is no integrity shortcut lost here:
    /// the bytes flow straight into the **same** offline verify+install pipeline,
    /// whose per-bundle SHA-256 manifest digest and Ed25519 signature are the real
    /// gate — a corrupted direct download simply fails verification. The temp file
    /// is owned by the caller; on a transport failure nothing is left behind.
    ///
    /// - Throws: ``VGError/notFound`` / ``VGError/io`` on a transport failure.
    public func downloadDirect(_ url: URL) throws -> URL {
        let data = try fetch(url, what: url.lastPathComponent)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-download-\(UUID().uuidString).vgconfig")
        do {
            try data.write(to: dest, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw VGError.io("could not write downloaded bundle to \(dest.path): \(error.localizedDescription)")
        }
        return dest
    }

    // MARK: - Path resolution

    /// Resolve a registry-relative path (e.g. `"index.json"` or
    /// `"bundles/<sha>.vgconfig"`) against ``baseURL``.
    ///
    /// `URL(string:relativeTo:)` treats the base as a *file* unless it ends in a
    /// slash, dropping the last path component when resolving. To make the base
    /// behave as a directory regardless of how the caller spelled it, a trailing
    /// slash is ensured before resolving. Falls back to plain path appending if
    /// the relative string is not a valid URL component.
    private func resolve(_ relativePath: String) -> URL {
        let baseDir = baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : baseURL.appendingPathComponent("", isDirectory: true)
        if let url = URL(string: relativePath, relativeTo: baseDir) {
            return url.absoluteURL
        }
        return baseDir.appendingPathComponent(relativePath)
    }

    // MARK: - Transport

    /// Fetch the bytes at `url` over the matching transport.
    ///
    /// `file://` URLs are read directly off disk (no session) so the whole flow
    /// runs offline; `http(s)://` URLs go through `URLSession`, bridging the async
    /// call across a semaphore for the synchronous CLI API (the `ModelDownloader`
    /// idiom). `what` names the resource for error messages.
    private func fetch(_ url: URL, what: String) throws -> Data {
        if url.isFileURL {
            return try fetchFile(url, what: what)
        }
        return try fetchHTTP(url, what: what)
    }

    /// Read a `file://` resource directly. A missing file is surfaced as
    /// ``VGError/notFound`` (the registry doesn't carry it) rather than a generic
    /// I/O error, matching how a 404 is reported over HTTP.
    private func fetchFile(_ url: URL, what: String) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                throw VGError.notFound("registry resource '\(what)' not found at \(url.path)")
            }
            throw VGError.io("could not read registry resource '\(what)' at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Fetch an `http(s)://` resource via `URLSession`, bridging the async call
    /// across a `DispatchSemaphore` for the synchronous CLI API.
    ///
    /// Mirrors `ModelDownloader`'s transport: a `URLRequest` with a finite
    /// timeout, an HTTP-status check (only `2xx` is accepted), and `URLError`
    /// mapping to a short, human-readable network clause. A `404` is reported as
    /// ``VGError/notFound`` so a missing config/bundle reads naturally; other
    /// non-2xx statuses are ``VGError/io``.
    private func fetchHTTP(_ url: URL, what: String) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, VGError> = .failure(.io("registry fetch did not complete"))

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let urlError = error as? URLError {
                result = .failure(.io("could not fetch '\(what)': \(Self.networkDetail(for: urlError))"))
                return
            }
            if let error {
                result = .failure(.io("could not fetch '\(what)': \(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(.io("could not fetch '\(what)': no HTTP response"))
                return
            }
            if http.statusCode == 404 {
                result = .failure(.notFound("registry resource '\(what)' not found (HTTP 404) at \(url.absoluteString)"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(.io("could not fetch '\(what)': unexpected HTTP \(http.statusCode)"))
                return
            }
            guard let data else {
                result = .failure(.io("could not fetch '\(what)': empty response body"))
                return
            }
            result = .success(data)
        }
        task.resume()
        semaphore.wait()

        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    /// Map a `URLError` to a short, plain-language clause for an error message.
    /// Mirrors `ModelDownloader.networkDetail(for:)`.
    private static func networkDetail(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "this Mac isn't connected to the internet"
        case .timedOut:
            return "the connection timed out"
        case .networkConnectionLost:
            return "the network connection was lost"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "the registry server couldn't be reached"
        default:
            return "the connection failed (\(error.code.rawValue))"
        }
    }
}
