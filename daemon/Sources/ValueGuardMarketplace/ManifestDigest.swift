import Foundation

/// Builds the content of `signatures/MANIFEST.SHA256` — the artifact that the
/// Ed25519 signature actually covers.
///
/// `MANIFEST.SHA256` is a coreutils `sha256sum`-style listing: one line per
/// bundle file (every member *except* everything under `signatures/`), each
/// line being `"<bare lowercase hex>  <bundle-relative POSIX path>\n"` — note
/// the **two** spaces between the digest and the path, an LF line terminator,
/// and a trailing newline after the final line.
///
/// Lines are sorted by the UTF-8 byte sequence of the relative path
/// (`Array(path.utf8)` lexicographic) so the output is deterministic and
/// byte-identical to whatever the signer produced. For the ASCII filenames the
/// §2 layout permits, this is equivalent to a plain `String` `<` comparison,
/// but we sort on the UTF-8 bytes explicitly to match the signer's contract.
///
/// The verify path recomputes this from the *raw on-disk bytes* of each file
/// (via `Hashing.sha256Hex(ofFileAt:)`) and compares the result byte-for-byte
/// against the bundled `signatures/MANIFEST.SHA256`. It never re-canonicalizes
/// any file before hashing.
///
/// ## Why the covered set comes from the validated member list
///
/// The digest is built over the EXACT set of validated regular-file members
/// (from `Archive.listTyped` + `assertSafeLayout`), never an independent
/// filesystem walk. Walking the extracted directory and emitting lines only for
/// `isRegularFile` would *silently omit* a member that the archive smuggled in
/// as a symlink — while the per-file hash step and the VGP1 parse step both
/// *follow* that symlink. That representation split is exactly the exploit this
/// type now refuses to allow: ``build(forExtractedDir:coveredMembers:)`` also
/// asserts that the regular files actually on disk equal the covered set, so the
/// digest can never disagree with what the other checks read.
public enum ManifestDigest {

    /// Recompute the expected `signatures/MANIFEST.SHA256` bytes for an extracted
    /// bundle, hashing exactly the supplied `coveredMembers` from their raw
    /// on-disk bytes.
    ///
    /// `coveredMembers` MUST be the validated regular-file member list (from
    /// `Archive.listTyped` + `assertSafeLayout`); everything under `signatures/`
    /// is excluded here because the signature is computed *over* the digest and
    /// cannot cover itself. The method additionally requires that the regular
    /// files actually present under `dir` (outside `signatures/`) equal the
    /// covered set exactly — any extra, missing, or non-regular (symlink, …)
    /// entry is a `VGError`, eliminating any digest-vs-hash/parse split.
    ///
    /// Defense in depth: before reading any member for hashing, its resolved
    /// (standardized) path is confirmed to still be inside `dir`, so a member
    /// can never redirect a read outside the extraction temp root.
    ///
    /// - Parameters:
    ///   - dir: The root of an extracted `.vgconfig` bundle.
    ///   - coveredMembers: The validated regular-file member paths the archive
    ///     declared (bundle-relative POSIX paths). Members under `signatures/`
    ///     are filtered out automatically.
    /// - Returns: The exact bytes the signed `MANIFEST.SHA256` should contain.
    /// - Throws: `VGError.io` if a covered file cannot be read or hashed, or
    ///   `VGError.bundleLayout` if the on-disk regular-file set disagrees with
    ///   `coveredMembers` or a member escapes the extraction root.
    public static func build(forExtractedDir dir: URL, coveredMembers: [String]) throws -> Data {
        let root = dir.standardizedFileURL
        let rootPath = root.path

        // The covered set: validated members minus the signatures/ subtree.
        let covered = coveredMembers.filter { !isUnderSignatures($0) }
        let coveredSet = Set(covered)

        // Defense in depth + no representation split: the regular files actually
        // on disk (outside signatures/) MUST equal the covered set exactly.
        let onDisk = try regularFilesOnDisk(underRoot: root, rootPath: rootPath)

        if onDisk != coveredSet {
            let extra = onDisk.subtracting(coveredSet).sorted()
            let missing = coveredSet.subtracting(onDisk).sorted()
            var detail = "extracted regular-file set does not match the validated "
                + "archive member list"
            if !extra.isEmpty {
                detail += "; unexpected on disk: \(extra.joined(separator: ", "))"
            }
            if !missing.isEmpty {
                detail += "; declared but absent/non-regular: \(missing.joined(separator: ", "))"
            }
            throw VGError.bundleLayout(detail)
        }

        // Sort the covered members by the UTF-8 byte sequence of the relative
        // path, matching the signer's ordering contract.
        let ordered = covered.sorted { a, b in
            Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
        }

        var out = Data()
        for rel in ordered {
            let fileURL = try safeMemberURL(rel, underRoot: root, rootPath: rootPath)
            let hex = try Hashing.sha256Hex(ofFileAt: fileURL)
            // coreutils sha256sum format: "<hex>  <path>\n" (two spaces).
            var line = hex
            line += "  "
            line += rel
            line += "\n"
            guard let lineData = line.data(using: .utf8) else {
                throw VGError.io("could not encode MANIFEST.SHA256 line for: \(rel)")
            }
            out.append(lineData)
        }
        return out
    }

    // MARK: - Private

    /// Whether a bundle-relative path is under the `signatures/` subtree.
    private static func isUnderSignatures(_ rel: String) -> Bool {
        rel == "signatures" || rel.hasPrefix("signatures/")
    }

    /// Enumerate every regular file actually present under `root`, **excluding**
    /// anything under `signatures/`, returning the set of bundle-relative POSIX
    /// paths. Symlinks and other non-regular entries are deliberately NOT counted
    /// as files (so they show up as a mismatch against the validated set).
    private static func regularFilesOnDisk(underRoot root: URL, rootPath: String) throws -> Set<String> {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw VGError.io("could not enumerate extracted dir: \(rootPath)")
        }

        var files = Set<String>()
        for case let fileURL as URL in enumerator {
            let relative = relativePath(of: fileURL.standardizedFileURL, underRoot: rootPath)

            // Prune the entire signatures/ subtree.
            if isUnderSignatures(relative) {
                if relative == "signatures" {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Resolve resource type WITHOUT following the link (the enumerator
            // does not follow symlinks; resourceValues reports the link's own
            // type). Only true regular files count.
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                files.insert(relative)
            }
        }
        return files
    }

    /// Resolve a bundle-relative member to an absolute URL and confirm its
    /// standardized path is still inside `root`. Refuses any member whose
    /// resolved path escapes the extraction temp root (defense in depth).
    private static func safeMemberURL(_ rel: String, underRoot root: URL, rootPath: String) throws -> URL {
        let candidate = root.appendingPathComponent(rel).standardizedFileURL
        let candidatePath = candidate.path
        var prefix = rootPath
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
            throw VGError.bundleLayout(
                "member '\(rel)' resolves outside the extraction root")
        }
        return candidate
    }

    /// Compute the bundle-relative POSIX path of `fileURL` given the absolute
    /// `rootPath` of the extracted bundle. Paths use forward slashes (the only
    /// separator on the supported platforms) and carry no leading slash.
    private static func relativePath(of fileURL: URL, underRoot rootPath: String) -> String {
        let full = fileURL.path
        if full == rootPath {
            return ""
        }
        var prefix = rootPath
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        // Fallback: the URL is not under the root (should not happen for a
        // well-formed enumeration) — return its last component so callers still
        // get a stable, non-absolute string.
        return fileURL.lastPathComponent
    }
}
