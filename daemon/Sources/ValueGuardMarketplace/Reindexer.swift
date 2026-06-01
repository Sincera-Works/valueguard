import Foundation

/// Builds a static registry tree from a directory of `.vgconfig` bundles.
///
/// This is the producer side of the §6 static registry: it scans a directory for
/// `*.vgconfig`, runs each through the **same** offline verifier the client uses,
/// and emits the content-addressed file tree a static host (object storage + CDN,
/// or a local `file://` root for tests) serves verbatim:
///
/// ```
/// <out>/index.json
/// <out>/bundles/<sha256>.vgconfig                              # content-addressed
/// <out>/configs/<author>/<slug>/<version>/manifest.json       # extracted
/// <out>/configs/<author>/<slug>/<version>/calibration.json
/// ```
///
/// A bundle that fails verification is **skipped with a warning**, never aborts
/// the run — a single bad bundle in a directory of good ones must not stop the
/// registry from being generated. The operation is idempotent: re-running over
/// the same inputs reproduces the same tree (bundle blobs are addressed by their
/// own SHA-256, so re-copying is a no-op overwrite, and the per-version
/// manifest/calibration files are overwritten in place).
///
/// All metadata in `index.json` comes from the `Manifest` the verifier already
/// decoded (name, description, license, tags, `created_at`, author fingerprint,
/// per-category actions) — never re-parsed independently. Versions are grouped by
/// `author/slug`, ordered newest-first, and `latest_version` is the highest
/// **non-prerelease** SemVer (falling back to the newest overall only if every
/// version is a prerelease).
public enum Reindexer {

    /// A bundle that could not be indexed, with the reason it was skipped.
    public struct Skipped: Sendable {
        /// The bundle file that was skipped.
        public let bundle: URL
        /// Human-readable reason (a failed verify check list, or an I/O error).
        public let reason: String

        public init(bundle: URL, reason: String) {
            self.bundle = bundle
            self.reason = reason
        }
    }

    /// The outcome of a reindex run: the written index plus a per-bundle tally.
    public struct Result: Sendable {
        /// The `index.json` that was written.
        public let index: RegistryIndex
        /// Count of bundles successfully indexed (sum of all versions).
        public let indexedCount: Int
        /// Bundles that were skipped, with reasons.
        public let skipped: [Skipped]

        public init(index: RegistryIndex, indexedCount: Int, skipped: [Skipped]) {
            self.index = index
            self.indexedCount = indexedCount
            self.skipped = skipped
        }
    }

    /// Scan `bundlesDir` for `*.vgconfig`, verify each, and write the static
    /// registry tree under `outDir`.
    ///
    /// - Parameters:
    ///   - bundlesDir: directory to scan for `*.vgconfig` files (non-recursive).
    ///   - outDir: registry root to write `index.json` + `bundles/` + `configs/`.
    ///   - registryName: the `registry.name` recorded in `index.json`.
    /// - Returns: the written ``RegistryIndex`` plus indexed / skipped tallies.
    /// - Throws: ``VGError/io`` if `bundlesDir` cannot be listed or `outDir` /
    ///   `index.json` cannot be written. Per-bundle verify failures do **not**
    ///   throw — they are collected in ``Result/skipped``.
    @discardableResult
    public static func reindex(
        bundlesDir: URL,
        outDir: URL,
        registryName: String = "ValueGuard Configs"
    ) throws -> Result {
        let fm = FileManager.default

        // Enumerate *.vgconfig in the bundles dir (sorted for deterministic order).
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: bundlesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VGError.io("could not list bundles directory \(bundlesDir.path): \(error.localizedDescription)")
        }
        let bundleURLs = entries
            .filter { $0.pathExtension == "vgconfig" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Prepare the output tree.
        let bundlesOut = outDir.appendingPathComponent("bundles", isDirectory: true)
        let configsOut = outDir.appendingPathComponent("configs", isDirectory: true)
        for dir in [outDir, bundlesOut, configsOut] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw VGError.io("could not create registry directory \(dir.path): \(error.localizedDescription)")
            }
        }

        // Group accumulated versions by author/slug while indexing.
        var grouped: [String: GroupAccumulator] = [:]
        var groupOrder: [String] = []   // preserve first-seen order of author/slug
        var skipped: [Skipped] = []
        var indexedCount = 0

        for bundleURL in bundleURLs {
            do {
                let processed = try processBundle(
                    bundleURL: bundleURL,
                    bundlesOut: bundlesOut,
                    configsOut: configsOut
                )
                let key = "\(processed.author)/\(processed.slug)"
                if grouped[key] == nil {
                    grouped[key] = GroupAccumulator(
                        author: processed.author,
                        slug: processed.slug,
                        authorFingerprint: processed.authorFingerprint
                    )
                    groupOrder.append(key)
                }
                grouped[key]?.add(processed)
                indexedCount += 1
            } catch {
                skipped.append(Skipped(bundle: bundleURL, reason: detail(error)))
            }
        }

        // Build the catalog: each group's versions newest-first, latest_version =
        // highest non-prerelease, top-level metadata copied from that version.
        let configs: [RegistryIndex.Config] = groupOrder.compactMap { key in
            grouped[key]?.makeConfig()
        }

        let index = RegistryIndex(
            schemaVersion: 1,
            generatedAt: rfc3339UTCNow(),
            registry: RegistryIndex.RegistryInfo(name: registryName),
            configs: configs
        )

        // Write index.json (pretty + sorted keys for a stable, diffable file).
        let indexData = try encodeIndex(index)
        let indexURL = outDir.appendingPathComponent("index.json")
        do {
            try indexData.write(to: indexURL, options: [.atomic])
        } catch {
            throw VGError.io("could not write index.json to \(indexURL.path): \(error.localizedDescription)")
        }

        return Result(index: index, indexedCount: indexedCount, skipped: skipped)
    }

    // MARK: - Per-bundle processing

    /// The per-version facts a single bundle contributes to the index.
    private struct Processed {
        let author: String
        let slug: String
        let authorFingerprint: String
        let manifest: Manifest
        let version: RegistryIndex.Version
    }

    /// Verify one bundle, copy it content-addressed into `bundles/`, extract its
    /// `manifest.json` + `calibration.json` into `configs/...`, and build the
    /// per-version index entry. Throws (→ skip) if verification fails.
    private static func processBundle(
        bundleURL: URL,
        bundlesOut: URL,
        configsOut: URL
    ) throws -> Processed {
        let fm = FileManager.default

        // Verify with the SAME pipeline the client runs on install. The verifier
        // hands us ownership of the temp extraction; clean it up either way.
        let (report, extractedDir) = try BundleVerifier.verify(bundleAt: bundleURL)
        defer { try? fm.removeItem(at: extractedDir) }

        guard report.allPassed else {
            let failed = report.checks.filter { !$0.ok }.map { check -> String in
                check.detail.map { "\(check.label): \($0)" } ?? check.label
            }
            throw VGError.signatureInvalid("verification failed: " + failed.joined(separator: "; "))
        }

        let manifest = report.manifest
        let author = manifest.author.handle
        let slug = manifest.configId
        let version = manifest.version
        let sha = report.bundleSha256

        // Defense-in-depth: these become directory names under the output tree.
        // ManifestValidator (run inside verify) already blocks path-traversal via
        // regex, but the reindexer is a producer-side tool that may run over
        // less-trusted bundle directories — guard here too, mirroring the same
        // call in Installer.install, so a validator regression can't let a
        // crafted handle escape the output root.
        try InstallLayout.assertSafeComponents(author: author, slug: slug, version: version)

        // 1. Content-addressed bundle blob: bundles/<sha256>.vgconfig (immutable).
        let blobURL = bundlesOut.appendingPathComponent("\(sha).vgconfig")
        do {
            if fm.fileExists(atPath: blobURL.path) {
                try fm.removeItem(at: blobURL)   // idempotent overwrite
            }
            try fm.copyItem(at: bundleURL, to: blobURL)
        } catch {
            throw VGError.io("could not copy bundle blob to \(blobURL.path): \(error.localizedDescription)")
        }

        // 2. Extracted manifest.json + calibration.json under configs/<a>/<s>/<v>/.
        let versionDir = configsOut
            .appendingPathComponent(author, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        do {
            try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
            try copyOverwriting(
                from: extractedDir.appendingPathComponent("manifest.json"),
                to: versionDir.appendingPathComponent("manifest.json")
            )
            try copyOverwriting(
                from: extractedDir.appendingPathComponent("calibration.json"),
                to: versionDir.appendingPathComponent("calibration.json")
            )
        } catch let error as VGError {
            throw error
        } catch {
            throw VGError.io("could not extract config files for \(author)/\(slug)@\(version): \(error.localizedDescription)")
        }

        // 3. Per-version index entry. Paths are RELATIVE to the registry base.
        let sizeBytes = ((try? fm.attributesOfItem(atPath: blobURL.path)[.size]) as? Int) ?? 0
        let categories = manifest.categories.map {
            RegistryIndex.CategorySummary(id: $0.id, action: $0.action)
        }
        let entry = RegistryIndex.Version(
            version: version,
            createdAt: manifest.createdAt,
            bundleSha256: sha,
            bundlePath: "bundles/\(sha).vgconfig",
            manifestPath: "configs/\(author)/\(slug)/\(version)/manifest.json",
            sizeBytes: sizeBytes,
            categories: categories
        )

        return Processed(
            author: author,
            slug: slug,
            authorFingerprint: report.authorFingerprint,
            manifest: manifest,
            version: entry
        )
    }

    // MARK: - Grouping

    /// Accumulates all versions of one `author/slug` during a reindex run, then
    /// emits the ordered ``RegistryIndex/Config``.
    private struct GroupAccumulator {
        let author: String
        let slug: String
        let authorFingerprint: String
        /// (parsed version for ordering, manifest for metadata, wire entry).
        private var items: [(semver: SemVer?, manifest: Manifest, entry: RegistryIndex.Version)] = []

        init(author: String, slug: String, authorFingerprint: String) {
            self.author = author
            self.slug = slug
            self.authorFingerprint = authorFingerprint
        }

        mutating func add(_ processed: Processed) {
            items.append((SemVer(processed.version.version), processed.manifest, processed.version))
        }

        /// Build the catalog entry: versions newest-first, top-level metadata from
        /// the latest non-prerelease (or the newest version if all are prerelease).
        func makeConfig() -> RegistryIndex.Config? {
            guard !items.isEmpty else { return nil }

            // Newest-first ordering. Unparseable versions sort last (stable on raw
            // string) so a malformed version never claims `latest`.
            let sorted = items.sorted { a, b in
                switch (a.semver, b.semver) {
                case let (x?, y?):
                    if x == y { return a.entry.version > b.entry.version }
                    return x > y
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return a.entry.version > b.entry.version
                }
            }

            // latest_version: highest NON-prerelease; fall back to the newest of
            // all if every version is a prerelease (or unparseable).
            let latest = sorted.first { ($0.semver?.isPrerelease == false) } ?? sorted.first!
            let latestManifest = latest.manifest

            return RegistryIndex.Config(
                author: author,
                slug: slug,
                name: latestManifest.name,
                description: latestManifest.description,
                latestVersion: latest.entry.version,
                license: latestManifest.license,
                tags: latestManifest.tags ?? [],
                verified: false,
                authorFingerprint: authorFingerprint,
                versions: sorted.map { $0.entry }
            )
        }
    }

    // MARK: - Helpers

    /// Copy `src` → `dst`, removing an existing `dst` first (idempotent).
    private static func copyOverwriting(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    /// Encode the index as pretty-printed, sorted-key JSON for a stable, diffable
    /// `index.json`. snake_case wire keys come from the `CodingKeys` on the model.
    private static func encodeIndex(_ index: RegistryIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(index)
        } catch {
            throw VGError.io("could not encode index.json: \(error.localizedDescription)")
        }
    }

    /// Current time as an RFC3339 UTC timestamp with a `Z` terminator (matches
    /// the `created_at` / `installed_at` form used elsewhere; no fractional secs).
    private static func rfc3339UTCNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// Best-effort human detail for a thrown error (a `VGError`'s description, or
    /// the localized description), for the skip-reason tally.
    private static func detail(_ error: Error) -> String {
        if let vg = error as? VGError, let message = vg.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
