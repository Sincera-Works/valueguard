import Foundation

/// Thin wrapper around `/usr/bin/tar` (bsdtar) for the gzipped-tar `.vgconfig`
/// bundle format. Foundation has no tar API, so we shell out via `Process` —
/// mirroring the established pattern in `ModelDownloader.swift`.
///
/// Because `vg` processes *untrusted* bundles, the path-traversal guard lives
/// here: callers MUST `list` a bundle and run `assertSafeLayout` on the member
/// names *before* `extract`, so a malicious archive can never write outside the
/// target temp dir (absolute paths, `..` components, leading `/`).
///
/// `assertSafeLayout` also rejects on member *type*, not name alone: a member
/// named e.g. `policy.bin` that is actually a symlink (or hardlink / device /
/// fifo) is rejected before extraction, because the downstream hash, VGP1-parse
/// and digest steps would otherwise dereference it. The single exception is the
/// `signatures/` directory entry, which is a legitimate directory.
public enum Archive {

    /// Absolute path to the system tar binary.
    private static let tarPath = "/usr/bin/tar"

    // MARK: - §2 allowed member set

    /// The four required regular-file members, in §2 canonical order.
    static let requiredTopLevel = [
        "manifest.json",
        "policy.bin",
        "policy.json",
        "calibration.json",
    ]

    /// Optional top-level regular-file members permitted by §2.
    static let optionalTopLevel: Set<String> = [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "icon.png",
    ]

    /// Required members under `signatures/`.
    static let requiredSignatureMembers = [
        "signatures/author.sig",
        "signatures/author.pub",
        "signatures/MANIFEST.SHA256",
    ]

    /// Optional members under `signatures/`.
    static let optionalSignatureMembers: Set<String> = [
        "signatures/registry.sig",
    ]

    // MARK: - list

    /// Run `tar -tzf <bundle>` and return the member paths.
    ///
    /// Output is normalized: pure-directory entries (members ending in `/`,
    /// e.g. `signatures/`) are dropped so callers see only the regular-file
    /// members. Trailing whitespace/CR is trimmed and any leading `./` prefix
    /// that bsdtar may emit is stripped. Empty lines are skipped.
    public static func list(bundleAt url: URL) throws -> [String] {
        let stdout = try run(arguments: ["-tzf", url.path])
        var members: [String] = []
        stdout.enumerateLines { line, _ in
            var name = line
            // Strip a trailing carriage return / whitespace.
            while let last = name.last, last == "\r" || last == "\n" {
                name.removeLast()
            }
            // Strip a leading "./" that some tar implementations prepend.
            if name.hasPrefix("./") {
                name.removeFirst(2)
            }
            guard !name.isEmpty else { return }
            // Drop pure-directory entries (trailing slash).
            guard !name.hasSuffix("/") else { return }
            members.append(name)
        }
        return members
    }

    // MARK: - typed list

    /// A listed archive member together with its tar entry type, as parsed from
    /// the `tar -tvzf` long listing's leading mode character.
    struct TypedMember {
        /// The normalized member path (same normalization as ``list``).
        let name: String
        /// `true` iff this entry is a plain directory (long-listing type `d`).
        let isDirectory: Bool
        /// `true` iff this entry is a regular file (long-listing type `-`).
        let isRegularFile: Bool
        /// The raw leading type character from the long listing (`-`, `d`, `l`,
        /// `h`, `b`, `c`, `p`, `s`, …) — surfaced for error messages.
        let typeChar: Character
    }

    /// Run `tar -tvzf <bundle>` and return each member's path together with its
    /// entry type, parsed from the long listing's leading mode character.
    ///
    /// Names are taken from the parallel `tar -tzf` listing (which preserves the
    /// exact bytes of each name and is normalized identically to ``list``); the
    /// type character is read from the corresponding `-tvzf` line. bsdtar emits
    /// both listings in the same archive order, so the two are correlated by
    /// index. If the two listings disagree in length the bundle is rejected
    /// (`VGError.archive`) rather than risk a name/type mismatch.
    ///
    /// Unlike ``list``, the result *includes* pure-directory entries (e.g. the
    /// `signatures/` directory) so the layout guard can distinguish a legitimate
    /// directory from a file-shaped member.
    ///
    /// The two `tar` invocations are a theoretical TOCTOU — the bundle file
    /// could be replaced between them — but it is not exploitable: extraction
    /// re-reads the bundle, the extracted bytes are re-hashed, and the
    /// `MANIFEST.SHA256` + Ed25519 signature are verified over *those* bytes, so
    /// a swap between the two listings cannot yield a bundle that both verifies
    /// and installs altered content (the length-mismatch guard below also trips
    /// on most divergences).
    static func listTyped(bundleAt url: URL) throws -> [TypedMember] {
        // Clean names (normalized exactly like `list`, but keep directory
        // entries so we can pair them with their type rows).
        let nameRows = parseNameListing(try run(arguments: ["-tzf", url.path]))
        // Type characters, in the same archive order.
        let typeChars = try parseTypeChars(try run(arguments: ["-tvzf", url.path]))

        guard nameRows.count == typeChars.count else {
            throw VGError.archive(
                "tar listing length mismatch (\(nameRows.count) names vs "
                + "\(typeChars.count) typed rows); refusing to classify members")
        }

        var members: [TypedMember] = []
        members.reserveCapacity(nameRows.count)
        for (name, typeChar) in zip(nameRows, typeChars) {
            members.append(TypedMember(
                name: name,
                isDirectory: typeChar == "d",
                isRegularFile: typeChar == "-",
                typeChar: typeChar
            ))
        }
        return members
    }

    /// Parse a `tar -tzf` style listing into normalized member names, preserving
    /// directory entries (trailing slash kept as-is) and archive order. Empty
    /// lines are skipped; a leading `./` is stripped; trailing CR/LF is trimmed.
    private static func parseNameListing(_ stdout: String) -> [String] {
        var names: [String] = []
        stdout.enumerateLines { line, _ in
            var name = line
            while let last = name.last, last == "\r" || last == "\n" {
                name.removeLast()
            }
            if name.hasPrefix("./") {
                name.removeFirst(2)
            }
            guard !name.isEmpty else { return }
            names.append(name)
        }
        return names
    }

    /// Extract the leading type character from each non-empty line of a
    /// `tar -tvzf` long listing, in order. The first character of every entry
    /// row is the mode's type bit (`-`, `d`, `l`, `h`, `b`, `c`, `p`, `s`, …).
    private static func parseTypeChars(_ stdout: String) throws -> [Character] {
        var chars: [Character] = []
        var malformed = false
        stdout.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard !trimmed.isEmpty else { return }
            guard let first = trimmed.first else { return }
            // The mode field is always at least 10 chars (type + 9 permission
            // bits, possibly with an ACL/xattr suffix). A line that doesn't look
            // like a mode field means the listing format changed under us.
            if trimmed.count < 10 {
                malformed = true
                stop = true
                return
            }
            chars.append(first)
        }
        if malformed {
            throw VGError.archive("unparseable `tar -tvzf` long-listing row")
        }
        return chars
    }

    // MARK: - extract

    /// Extract a `.vgconfig` into `dir` via `tar -xzf <bundle> -C <dir>`.
    ///
    /// The caller MUST pass a fresh temp directory and MUST have already run
    /// `list` + `assertSafeLayout` on the bundle's members. `--no-same-owner`
    /// is passed so extracted files are owned by the running user regardless of
    /// what the archive recorded.
    public static func extract(bundleAt url: URL, into dir: URL) throws {
        _ = try run(arguments: ["-xzf", url.path, "--no-same-owner", "-C", dir.path])
    }

    // MARK: - create (test / pack only)

    /// Build a `.vgconfig` from a staging directory.
    ///
    /// Members are listed *explicitly* in caller-supplied order (never `.`), so
    /// stray files such as `.DS_Store` never sweep in and the layout is
    /// deterministic. `--no-mac-metadata` drops AppleDouble/xattr companions.
    ///
    /// This is the internal pack/round-trip path used by tests and the hidden
    /// `vg pack` helper — it is *not* the network publish path and does no
    /// signing-key management.
    public static func create(members: [String], inStagingDir staging: URL, outputBundle url: URL) throws {
        guard !members.isEmpty else {
            throw VGError.archive("no members specified for archive creation")
        }
        // Ensure the output directory exists.
        let outDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var args = ["-czf", url.path, "--no-mac-metadata", "-C", staging.path]
        args.append(contentsOf: members)
        _ = try run(arguments: args)
    }

    // MARK: - layout guard

    /// Enforce the §2 fixed top-level layout over a list of member paths
    /// (as returned by `list`).
    ///
    /// Rejects:
    ///   - absolute paths and any member with a leading `/`,
    ///   - any member containing a `..` path component,
    ///   - any member outside the §2 allowed set (unknown top-level files,
    ///     unknown `signatures/` members, or files nested below the single
    ///     permitted `signatures/` subdirectory),
    /// and requires the four required top-level members plus
    /// `signatures/{author.sig,author.pub,MANIFEST.SHA256}` all be present.
    ///
    /// Intentionally `internal`, not `public`: this name-only guard is the
    /// *weaker* of the two overloads (it does not reject symlinks/hardlinks),
    /// and the verify pipeline always uses the `[TypedMember]` overload. Kept
    /// internal so an external caller can't accidentally pick the weaker check.
    static func assertSafeLayout(_ members: [String]) throws {
        var present = Set<String>()
        for raw in members {
            try assertSafeName(raw)
            present.insert(raw)
        }
        try assertRequiredPresent(present)
    }

    /// Type-aware layout guard: enforce the §2 layout *and* reject any member
    /// whose tar entry type is not a regular file, with the single exception of
    /// the `signatures/` directory entry.
    ///
    /// This closes the symlink/representation split: a member named e.g.
    /// `policy.bin` that is actually a symlink (or hardlink, device, fifo, …)
    /// would pass the name-only guard but be dereferenced by the downstream
    /// hash / VGP1-parse / digest steps. Rejecting on type *before* extraction
    /// means such a member can never be written to disk at all.
    ///
    /// Rejects (in addition to all name-based rejections in the `[String]`
    /// overload of `assertSafeLayout`):
    ///   - any non-regular-file member (symlink `l`, hardlink `h`, block `b` /
    ///     char `c` device, fifo `p`, socket `s`, …), and
    ///   - any directory other than the lone permitted `signatures/` entry.
    static func assertSafeLayout(_ members: [TypedMember]) throws {
        var present = Set<String>()

        for member in members {
            let raw = member.name

            // A pure-directory entry: the only one §2 permits is `signatures/`.
            if raw.hasSuffix("/") {
                guard member.isDirectory else {
                    // A name ending in "/" that is NOT a directory entry is
                    // pathological; reject it on type.
                    throw VGError.bundleLayout(
                        "member '\(raw)' has a trailing slash but is not a directory "
                        + "(tar type '\(member.typeChar)')")
                }
                let bare = String(raw.dropLast())
                // Still subject to the path-safety rules (no .., absolute, …).
                try assertSafeName(bare)
                guard bare == "signatures" else {
                    throw VGError.bundleLayout("unexpected directory member: \(raw)")
                }
                // Do not record the directory itself in `present`: completeness
                // is tracked over the required regular-file members only.
                continue
            }

            // Every non-directory member MUST be a regular file. Reject symlinks,
            // hardlinks, devices, fifos, sockets, and anything else outright,
            // before extraction and before any name classification.
            guard member.isRegularFile else {
                throw VGError.bundleLayout(
                    "member '\(raw)' is not a regular file (tar type "
                    + "'\(member.typeChar)'); only regular files and the "
                    + "signatures/ directory are permitted")
            }

            // Regular file: apply the §2 name rules.
            try assertSafeName(raw)
            present.insert(raw)
        }

        try assertRequiredPresent(present)
    }

    /// Apply the §2 *name* rules (path traversal + allowed-set classification) to
    /// a single regular-file member path. Shared by both `assertSafeLayout`
    /// overloads. Does not check presence/completeness.
    private static func assertSafeName(_ raw: String) throws {
        // Reject absolute / leading-slash members.
        if raw.hasPrefix("/") {
            throw VGError.bundleLayout("member has a leading '/': \(raw)")
        }
        // Reject path traversal: any "." or ".." component, or empty
        // components (which imply "//", a leading "/", or a trailing "/").
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component == ".." {
                throw VGError.bundleLayout("member contains a '..' component: \(raw)")
            }
            if component == "." {
                throw VGError.bundleLayout("member contains a '.' component: \(raw)")
            }
            if component.isEmpty {
                throw VGError.bundleLayout("member has an empty path component: \(raw)")
            }
        }
        // Reject anything that still parses as an absolute file URL path.
        if (raw as NSString).isAbsolutePath {
            throw VGError.bundleLayout("member is an absolute path: \(raw)")
        }

        // Classify against the §2 allowed set.
        if raw.hasPrefix("signatures/") {
            // Exactly one path component below "signatures/" is allowed
            // (no nested subdirectories under signatures/).
            let tail = raw.dropFirst("signatures/".count)
            if tail.contains("/") {
                throw VGError.bundleLayout("unexpected nested member under signatures/: \(raw)")
            }
            guard requiredSignatureMembers.contains(raw) || optionalSignatureMembers.contains(raw) else {
                throw VGError.bundleLayout("unknown member under signatures/: \(raw)")
            }
        } else {
            // Top-level member: no subdirectories permitted outside signatures/.
            if raw.contains("/") {
                throw VGError.bundleLayout("unexpected nested member outside signatures/: \(raw)")
            }
            guard requiredTopLevel.contains(raw) || optionalTopLevel.contains(raw) else {
                throw VGError.bundleLayout("unknown top-level member: \(raw)")
            }
        }
    }

    /// Require all mandatory top-level and `signatures/` members are present.
    private static func assertRequiredPresent(_ present: Set<String>) throws {
        for required in requiredTopLevel where !present.contains(required) {
            throw VGError.bundleLayout("missing required member: \(required)")
        }
        for required in requiredSignatureMembers where !present.contains(required) {
            throw VGError.bundleLayout("missing required member: \(required)")
        }
    }

    // MARK: - Process plumbing

    /// Run `/usr/bin/tar` with the given arguments, capturing stdout (returned)
    /// and stderr (surfaced in the thrown error). Throws `VGError.archive` on a
    /// non-zero exit or on failure to launch the process.
    @discardableResult
    private static func run(arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tarPath)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw VGError.archive("could not launch tar: \(error.localizedDescription)")
        }

        // Drain stdout and stderr concurrently. Reading them serially can
        // deadlock: if tar fills the pipe we are NOT currently draining (the
        // ~64 KB kernel buffer), it blocks on write while we block reading the
        // other pipe, and neither side progresses. Read stderr on a background
        // queue while we read stdout here, then join before waiting.
        //
        // The background read writes into a reference-type box rather than a
        // captured stack `var`, so there is no mutation of a captured stack slot
        // across the queue boundary. `group.wait()` happens-before we read
        // `box.data`, establishing the ordering that makes the single write
        // visible here without a data race.
        let errHandle = errPipe.fileHandleForReading
        let box = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            box.data = errHandle.readDataToEndOfFile()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let stderr = String(data: box.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VGError.archive("tar exit \(proc.terminationStatus): \(stderr)")
        }

        return String(data: outData, encoding: .utf8) ?? ""
    }
}

/// A minimal reference holder for the concurrently-drained stderr bytes.
///
/// Using a reference type (rather than capturing and mutating a stack `var`)
/// makes the cross-queue handoff in `Archive.run` unambiguously clean: the
/// background drain assigns `data` exactly once, and the caller reads it only
/// after `group.wait()` — a happens-before edge that publishes the write.
private final class DataBox {
    var data = Data()
}
