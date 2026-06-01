import Foundation
import Darwin
import ArgumentParser
import ValueGuardMarketplace

/// `vg` — the ValueGuard config-bundle CLI.
///
/// A thin ArgumentParser front-end over `ValueGuardMarketplace`. Each subcommand
/// parses its arguments, calls into the library, prints human-readable output,
/// and maps thrown ``VGError`` values to a stderr message plus a non-zero exit
/// code. No business logic lives here — the library owns verification, install
/// layout, the lockfile, TOFU, and the atomic activate swap.
@main
struct VG: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vg",
        abstract: "ValueGuard config bundles",
        subcommands: [
            Keygen.self,
            Pack.self,
            Verify.self,
            Install.self,
            List.self,
            Activate.self,
            Uninstall.self,
            Reindex.self,
            Search.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - Shared output helpers

/// Print a line to standard error.
private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Render one `VerifyReport.Check` as a §4-style aligned `label  ok/FAIL` line,
/// appending the failure detail (if any) on the following indented line.
private func formatCheckLine(_ check: VerifyReport.Check) -> String {
    // §4 aligns the status in a column; pad the label out to a fixed width so
    // the `ok`/`FAIL` markers line up. Labels longer than the column still get
    // a single separating space.
    let column = 42
    let padded: String
    if check.label.count < column {
        padded = check.label + String(repeating: " ", count: column - check.label.count)
    } else {
        padded = check.label + " "
    }
    let status = check.ok ? "ok" : "FAIL"
    var line = padded + status
    if let detail = check.detail, !detail.isEmpty {
        line += "\n    " + detail
    }
    return line
}

// MARK: - Registry base resolution

/// Resolve the registry base URL the `author/slug` install / `search` flows run
/// against, with the documented precedence:
///
///   `--registry <url>` flag  >  `VALUEGUARD_REGISTRY` env var  >
///   the prototype default (``RegistryClient/defaultRegistryBase``).
///
/// The single source of truth for the default is the library constant — the CLI
/// never hard-codes a second copy. The env var name is also defined once here.
///
/// - Returns: the resolved base `URL`. A bare path (no scheme) is treated as a
///   local filesystem directory (`file://`), so a developer can point at a
///   generated registry dir without typing the `file://` prefix.
private enum RegistryBase {
    /// The environment variable that overrides the registry base when no
    /// `--registry` flag is given.
    static let envVar = "VALUEGUARD_REGISTRY"

    /// Resolve the base URL from the `--registry` flag, the env var, or the
    /// prototype default — in that order.
    static func resolve(flag: String?) -> URL {
        if let flag, !flag.isEmpty {
            return parse(flag)
        }
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            return parse(env)
        }
        return parse(RegistryClient.defaultRegistryBase)
    }

    /// Parse a base string into a URL. A string with a scheme (`https://`,
    /// `file://`) is parsed as-is; a bare path becomes a local directory URL.
    private static func parse(_ s: String) -> URL {
        if s.contains("://"), let url = URL(string: s) {
            return url
        }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }
}

// MARK: - keygen

/// `vg keygen --handle <h> [--out <dir>] [--force]` — generate an author Ed25519
/// keypair and persist it.
///
/// Writes two text files: `<handle>.key` (the raw 32-byte private seed,
/// base64-encoded, mode 0600) and `<handle>.pub` (the raw 32-byte public key,
/// base64-encoded). Both use the same base64 wire form the rest of the marketplace
/// uses (`author.pub` inside a bundle, `author.public_key` in the manifest), so the
/// `.key` produced here feeds straight into `vg pack --key`. The fingerprint is
/// printed for TOFU comparison.
///
/// The default location is
/// `~/Library/Application Support/ValueGuard/keys/`. The command refuses to clobber
/// an existing private key unless `--force` is passed, so an author's identity is
/// not silently overwritten.
struct Keygen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keygen",
        abstract: "Generate an author Ed25519 keypair and write it to disk."
    )

    @Option(name: .long, help: "Author handle; names the key files (<handle>.key/.pub).")
    var handle: String

    @Option(name: .long, help: "Directory to write the keypair into (default: ~/Library/Application Support/ValueGuard/keys).")
    var out: String?

    @Flag(name: .long, help: "Overwrite an existing key with the same handle.")
    var force = false

    func run() throws {
        let fm = FileManager.default

        // Resolve the keys directory (override or the default Application Support
        // location), creating it if needed.
        let keysDir: URL
        do {
            keysDir = try Self.resolveKeysDir(out)
            try fm.createDirectory(at: keysDir, withIntermediateDirectories: true)
        } catch let error as VGError {
            printError("vg: keygen failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        let privateURL = keysDir.appendingPathComponent("\(handle).key")
        let publicURL = keysDir.appendingPathComponent("\(handle).pub")

        // Refuse to clobber an existing identity unless --force.
        if fm.fileExists(atPath: privateURL.path) && !force {
            printError("vg: keygen failed: a key already exists at \(privateURL.path) (pass --force to overwrite)")
            throw ExitCode(1)
        }

        let keypair = Ed25519.generateKeypair()
        let privateBase64 = keypair.privateRaw.base64EncodedString()
        let publicBase64 = keypair.publicRaw.base64EncodedString()

        do {
            // Write the public key world-readable.
            try Data((publicBase64 + "\n").utf8).write(to: publicURL, options: .atomic)
            // Write the PRIVATE key through a freshly-created 0600 file descriptor.
            // A `Data.write(.atomic)` + later `chmod 0600` leaves a window where
            // the seed exists at 0644 (umask) and another process could read it;
            // creating the fd with mode 0600 up front closes that window.
            try Self.writePrivateKey(Data((privateBase64 + "\n").utf8), to: privateURL, force: force)
        } catch let error as VGError {
            printError("vg: keygen failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        } catch {
            printError("vg: keygen failed: could not write key files: \(error)")
            throw ExitCode(1)
        }

        let fingerprint = Ed25519.fingerprint(publicKeyRaw: keypair.publicRaw)
        print("wrote private key   \(privateURL.path)")
        print("wrote public key    \(publicURL.path)")
        print("handle              \(handle)")
        print("fingerprint         \(fingerprint)")
    }

    /// Write the private-key bytes to `url` through a file descriptor created with
    /// mode `0600`, so the secret is never momentarily world-readable.
    ///
    /// Uses `open(2)` with `O_CREAT | O_WRONLY | O_TRUNC` and an explicit `0o600`
    /// creation mode (the kernel applies the umask, but 0600 & ~umask is still
    /// 0600 for any normal umask, so the file is owner-only from the instant it
    /// exists). `O_EXCL` is intentionally NOT used — the caller's `--force` /
    /// pre-existence check already governs overwrite — but when the file already
    /// exists we first ensure its mode is tightened. This avoids the
    /// `Data.write(.atomic)` + later `chmod` window where the seed sits at 0644.
    static func writePrivateKey(_ data: Data, to url: URL, force: Bool) throws {
        let path = url.path
        // If overwriting an existing key, tighten its mode first so the truncate
        // below never momentarily exposes new bytes under a stale loose mode.
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o600) }
        guard fd >= 0 else {
            throw VGError.io("could not create private key at \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        // Belt-and-suspenders: enforce 0600 on the open fd regardless of umask.
        _ = fchmod(fd, 0o600)
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            let total = buf.count
            let base = buf.baseAddress
            while off < total {
                let n = write(fd, base?.advanced(by: off), total - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VGError.io("could not write private key at \(path): \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }

    /// Resolve the directory the keypair is written into: the `--out` override when
    /// supplied (tilde-expanded), otherwise `~/Library/Application Support/ValueGuard/keys`.
    static func resolveKeysDir(_ out: String?) throws -> URL {
        if let out, !out.isEmpty {
            return URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VGError.io("could not resolve Application Support directory")
        }
        return appSupport
            .appendingPathComponent("ValueGuard", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
    }
}

// MARK: - pack

/// `vg pack --dir <path> --key <path.key> --handle <h> --name <n> --version <v> …`
/// — assemble a signed `.vgconfig` from a directory of policy artifacts.
///
/// Reads `policy.bin` / `policy.json` (and an optional `calibration.json`) from
/// `--dir`, loads the author signing key written by `vg keygen`, builds and signs
/// the bundle via ``Packer``, writes it to `--out`, and then re-runs
/// ``BundleVerifier/verify(bundleAt:)`` on its own output so the author sees the
/// §4 check lines proving the bundle is valid before they ship it.
///
/// The model-reference digests are shape-validated only in P0; pass real digests
/// with `--weights-sha256` / `--coreml-sha256` or accept the clearly-marked
/// placeholder (a warning is printed when the placeholder is used).
struct Pack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Assemble and sign a .vgconfig bundle from policy artifacts."
    )

    @Option(name: .long, help: "Directory containing policy.bin / policy.json (and optional calibration.json).")
    var dir: String

    @Option(name: .long, help: "Path to the author private key (.key written by 'vg keygen').")
    var key: String

    @Option(name: .long, help: "Author handle (must match the key owner).")
    var handle: String

    @Option(name: .long, help: "Human-readable config name (1–80 chars).")
    var name: String

    @Option(name: .long, help: "SemVer version, e.g. 1.0.0.")
    var version: String

    @Option(name: .long, help: "config_id (^[a-z][a-z0-9-]{1,38}[a-z0-9]$). Defaults to the --name slugified.")
    var configId: String?

    @Option(name: .long, help: "Author display name (defaults to the handle).")
    var displayName: String?

    @Option(name: .long, help: "Config description (1–2000 chars).")
    var description: String?

    @Option(name: .long, help: "SPDX license identifier (default: MIT).")
    var license: String = "MIT"

    @Option(name: .long, parsing: .singleValue, help: "A tag (^[a-z0-9-]{1,24}$); repeat for multiple, max 8.")
    var tag: [String] = []

    @Option(name: .long, help: "model_ref.weights_sha256 (64-char lowercase hex). Placeholder used if omitted.")
    var weightsSha256: String?

    @Option(name: .long, help: "model_ref.coreml_package_sha256 (64-char lowercase hex). Placeholder used if omitted.")
    var coremlSha256: String?

    @Option(name: .long, help: "Output .vgconfig path.")
    var out: String

    func run() throws {
        let fm = FileManager.default

        let inputDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        let outputURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)

        // Derive defaults: config_id from --name if not given, display name from
        // the handle. The validator enforces the precise patterns downstream.
        let resolvedConfigId = configId ?? Self.slugify(name)
        let resolvedDisplayName = displayName ?? handle
        let resolvedDescription = description
            ?? "\(name) — packed from \(inputDir.lastPathComponent)."

        do {
            // Load and decode the author private seed.
            let privateKeyRaw = try Self.loadPrivateKey(at: key)
            // Derive the public key from the private seed so author.pub / the
            // manifest public_key always match the signer (no separate .pub needed).
            let publicKeyRaw = try Ed25519.publicKey(forPrivateKeyRaw: privateKeyRaw)

            // Ensure the output directory exists.
            try fm.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let metadata = Packer.ConfigMetadata(
                configId: resolvedConfigId,
                name: name,
                description: resolvedDescription,
                version: version,
                license: license,
                tags: tag,
                modelRef: Packer.ModelRefDigests(
                    weightsSha256: weightsSha256,
                    coremlPackageSha256: coremlSha256
                )
            )

            let result = try Packer.pack(
                inputDir: inputDir,
                author: Packer.Author(handle: handle, displayName: resolvedDisplayName),
                privateKeyRaw: privateKeyRaw,
                publicKeyRaw: publicKeyRaw,
                metadata: metadata,
                outputBundle: outputURL
            )

            for warning in result.warnings {
                printError("vg: warning: " + warning.message)
            }
            print("packed \(handle)/\(resolvedConfigId) @ \(version)")
            print("wrote \(result.bundle.path)")

            // Self-check: run the verifier over our own output and print §4 lines.
            print("verifying produced bundle")
            let (report, extractedDir) = try BundleVerifier.verify(bundleAt: result.bundle)
            defer { try? fm.removeItem(at: extractedDir) }
            for check in report.checks {
                print(formatCheckLine(check))
            }
            guard report.allPassed else {
                printError("vg: pack produced a bundle that failed self-verification")
                throw ExitCode(1)
            }
        } catch let error as VGError {
            printError("vg: pack failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }
    }

    /// Read a `.key` file and decode the base64-encoded 32-byte private seed.
    static func loadPrivateKey(at path: String) throws -> Data {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VGError.io("could not read key file '\(url.path)': \(error)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed) else {
            throw VGError.io("key file '\(url.path)' is not valid base64")
        }
        guard raw.count == 32 else {
            throw VGError.io("key file '\(url.path)' must decode to 32 bytes, got \(raw.count)")
        }
        return raw
    }

    /// Best-effort slugify of a human name into a `config_id` candidate: lowercase,
    /// non-alphanumerics collapsed to single hyphens, trimmed. The manifest
    /// validator still has the final say on the resulting pattern.
    static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - verify

/// `vg verify <path.vgconfig>` — offline structural + hash + signature check.
///
/// Prints one `label  ok/FAIL` line per verification step and exits `0` iff every
/// check passed. A hard failure (bad archive, illegal layout, undecodable or
/// schema-invalid manifest) is thrown by the library before a report exists; it
/// is reported on stderr with exit code `1`.
struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a .vgconfig bundle offline (structure, hashes, signature)."
    )

    @Argument(help: "Path to the .vgconfig bundle (bare path or file:// URL).")
    var path: String

    func run() throws {
        // verify is strictly offline/local: reject any non-file URL so an
        // `https://…` argument can't be handed to Data(contentsOf:) (a network
        // fetch). Network/registry sources go through `vg install`.
        let url: URL
        do {
            url = try RefParser.resolveLocalSource(path)
        } catch let error as VGError {
            printError("vg: verify failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        let report: VerifyReport
        let extractedDir: URL
        do {
            (report, extractedDir) = try BundleVerifier.verify(bundleAt: url)
        } catch let error as VGError {
            // Hard failure before any report could be assembled.
            printError("vg: verify failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }
        // The verifier hands us ownership of the temp extraction; verify only
        // needs the report, so clean it up regardless of outcome.
        defer { try? FileManager.default.removeItem(at: extractedDir) }

        for check in report.checks {
            print(formatCheckLine(check))
        }

        guard report.allPassed else {
            throw ExitCode(1)
        }
    }
}

// MARK: - install

/// `vg install <author/slug[@version] | http(s)://… | file://path | path>` —
/// resolve + fetch (if remote), verify, then unpack into the local install
/// layout (§5).
///
/// Three source forms, selected by inspecting the argument (``RefParser``):
///   - **`author/slug[@version]`** — resolved against the static registry's
///     `index.json` (base URL from `--registry` > `VALUEGUARD_REGISTRY` > the
///     prototype default), the named bundle downloaded over HTTPS, its bytes
///     content-checked against the index's `bundle_sha256`, then installed.
///   - **`http(s)://…`** — a direct bundle URL, downloaded then installed.
///   - **bare path / `file://`** — a local bundle, installed in place (unchanged
///     existing behavior).
///
/// Every path converges on the **same** offline verify+install pipeline
/// (`Installer.install` → `BundleVerifier.verify`): the registry/index is trusted
/// only to *locate* bytes, never for trust — the per-bundle signature and the
/// nine verify steps are what gate the install. On success prints the §4-style
/// install lines (where the bundle landed and how to activate it). Verification
/// failure, a sha mismatch on a download, an immutability violation (same version
/// already installed), or a TOFU key change refuse the install and exit non-zero.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Resolve/fetch (if remote), verify, and install a .vgconfig bundle."
    )

    @Argument(help: "author/slug[@version], an http(s):// or file:// URL, or a local .vgconfig path.")
    var source: String

    @Option(name: .long, help: "Registry base URL (overrides $VALUEGUARD_REGISTRY and the default).")
    var registry: String?

    func run() throws {
        let layout: InstallLayout
        let installer: Installer
        let coords: (author: String, slug: String, version: String)

        // Track a temp download to remove after install (success or failure).
        var downloadedTemp: URL?
        defer { downloadedTemp.map { try? FileManager.default.removeItem(at: $0) } }

        do {
            layout = try InstallLayout()
            installer = Installer(layout: layout)

            let bundleURL: URL
            switch try RefParser.classifyInstallSource(source) {
            case .registryRef(let author, let slug, let version):
                // Resolve against the static registry, download + sha-check.
                let base = RegistryBase.resolve(flag: registry)
                print("using registry \(base.absoluteString)")
                let client = RegistryClient(baseURL: base)
                let (bundle, resolved) = try client.resolveAndDownload(
                    author: author, slug: slug, version: version
                )
                downloadedTemp = bundle
                bundleURL = bundle
                print("resolved \(author)/\(slug) -> \(resolved.version.version) (\(resolved.version.bundleSha256))")

            case .url(let url):
                // Direct bundle URL: download (sha unknown — verify is the gate).
                // No registry base is involved; use the static entry point so we
                // don't construct a client around a misleading bundle-as-base.
                print("downloading \(url.absoluteString)")
                let bundle = try RegistryClient.downloadDirect(from: url)
                downloadedTemp = bundle
                bundleURL = bundle

            case .local(let url):
                // Unchanged local path / file:// behavior.
                bundleURL = url
            }

            coords = try installer.install(bundleAt: bundleURL)
        } catch let error as VGError {
            printError("vg: install failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        // §4-style success output.
        let versionDir = layout.versionDir(
            author: coords.author,
            slug: coords.slug,
            version: coords.version
        )
        print("installing to \(versionDir.path)")
        print("done. activate with: vg activate \(coords.author)/\(coords.slug)")
    }
}

// MARK: - list

/// `vg list [--json]` — read the lockfile and list installed configs/versions.
///
/// Human output marks the active config with a leading `*`. `--json` emits a
/// stable array of objects for scripting.
struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed config bundles from the lockfile."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let configs: [InstalledConfig]
        do {
            let installer = Installer(layout: try InstallLayout())
            configs = try installer.list()
        } catch let error as VGError {
            printError("vg: list failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        if json {
            printJSON(configs)
            return
        }

        if configs.isEmpty {
            print("no configs installed")
            return
        }

        for config in configs {
            let marker = config.active ? "*" : " "
            let ref = "\(config.author)/\(config.slug)"
            print("\(marker) \(ref)  \(config.version)  installed \(config.installedAt)")
        }
    }

    /// Emit the installed configs as a stable JSON array. Built by hand (rather
    /// than encoding `InstalledConfig`, which is not `Codable`) so the field
    /// names are explicit and snake_case for scripting consumers.
    private func printJSON(_ configs: [InstalledConfig]) {
        var objects: [[String: Any]] = []
        for config in configs {
            objects.append([
                "author": config.author,
                "slug": config.slug,
                "version": config.version,
                "active": config.active,
                "pin": config.pin as Any,
                "installed_at": config.installedAt,
                "fingerprint": config.fingerprint,
            ])
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: objects,
                options: [.sortedKeys, .prettyPrinted]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            print("[]")
            return
        }
        print(text)
    }
}

// MARK: - activate

/// `vg activate <author>/<slug>` — atomic symlink swap of `configs/active`.
struct Activate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Make an installed config active (atomic symlink swap)."
    )

    @Argument(help: "Config reference as 'author/slug'.")
    var ref: String

    func run() throws {
        do {
            let parsed = try RefParser.parseSlugRef(ref)
            let installer = Installer(layout: try InstallLayout())
            try installer.activate(author: parsed.author, slug: parsed.slug)
        } catch let error as VGError {
            printError("vg: activate failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }
        print("activated \(ref)")
    }
}

// MARK: - uninstall

/// `vg uninstall <author>/<slug>` — remove from disk and from the lockfile.
struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove an installed config from disk and the lockfile."
    )

    @Argument(help: "Config reference as 'author/slug'.")
    var ref: String

    func run() throws {
        do {
            let parsed = try RefParser.parseSlugRef(ref)
            let installer = Installer(layout: try InstallLayout())
            try installer.uninstall(author: parsed.author, slug: parsed.slug)
        } catch let error as VGError {
            printError("vg: uninstall failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }
        print("uninstalled \(ref)")
    }
}

// MARK: - reindex

/// `vg reindex --bundles <dir> --out <registry-dir>` — generate the static
/// registry tree (§6) from a directory of `.vgconfig` bundles.
///
/// Scans `--bundles` for `*.vgconfig`, runs each through the SAME offline
/// verifier the client uses, copies verifying bundles content-addressed into
/// `<out>/bundles/<sha256>.vgconfig`, extracts each `manifest.json` +
/// `calibration.json` into `<out>/configs/<author>/<slug>/<version>/`, and writes
/// `<out>/index.json` grouping versions by `author/slug` (newest-first,
/// `latest_version` = highest non-prerelease SemVer). A bundle that fails to
/// verify is SKIPPED with a warning rather than aborting the run; the command is
/// idempotent (safe to re-run over the same inputs). All metadata is taken from
/// the manifest the verifier already decoded. Prints a summary (N indexed, M
/// skipped).
struct Reindex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Generate the static registry tree from a directory of .vgconfig bundles."
    )

    @Option(name: .long, help: "Directory to scan for *.vgconfig bundles.")
    var bundles: String

    @Option(name: .long, help: "Registry output directory (index.json + bundles/ + configs/).")
    var out: String

    @Option(name: .long, help: "Registry display name recorded in index.json.")
    var name: String = "ValueGuard Configs"

    func run() throws {
        let bundlesDir = URL(fileURLWithPath: (bundles as NSString).expandingTildeInPath, isDirectory: true)
        let outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)

        let result: Reindexer.Result
        do {
            result = try Reindexer.reindex(bundlesDir: bundlesDir, outDir: outDir, registryName: name)
        } catch let error as VGError {
            printError("vg: reindex failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        // Per-skip warnings, then the summary line.
        for skip in result.skipped {
            printError("vg: warning: skipped \(skip.bundle.lastPathComponent): \(skip.reason)")
        }
        print("wrote \(outDir.appendingPathComponent("index.json").path)")
        print("\(result.indexedCount) bundle(s) indexed, \(result.skipped.count) skipped")
        print("\(result.index.configs.count) config(s) in registry")
    }
}

// MARK: - search

/// `vg search [<query>] [--registry <url>] [--tag <t>]` — fetch the registry's
/// `index.json` and list matching configs.
///
/// Filters by a case-insensitive substring match on name / description / slug /
/// author, plus an optional `--tag` exact match. With no query and no tag, every
/// config is listed. Registry base precedence is `--registry` >
/// `VALUEGUARD_REGISTRY` > the prototype default. Output is one aligned row per
/// config: `author/slug  version  [verified]  tags…`.
struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the static registry's index.json for configs."
    )

    @Argument(help: "Optional substring to match on name/description/slug/author.")
    var query: String?

    @Option(name: .long, help: "Registry base URL (overrides $VALUEGUARD_REGISTRY and the default).")
    var registry: String?

    @Option(name: .long, help: "Filter to configs carrying this tag.")
    var tag: String?

    func run() throws {
        let base = RegistryBase.resolve(flag: registry)
        print("using registry \(base.absoluteString)")

        let index: RegistryIndex
        do {
            index = try RegistryClient(baseURL: base).fetchIndex()
        } catch let error as VGError {
            printError("vg: search failed: " + (error.errorDescription ?? "\(error)"))
            throw ExitCode(1)
        }

        let needle = query?.lowercased()
        let matches = index.configs.filter { config in
            // Substring match across name/description/slug/author.
            let textOK: Bool
            if let needle, !needle.isEmpty {
                textOK = config.name.lowercased().contains(needle)
                    || config.description.lowercased().contains(needle)
                    || config.slug.lowercased().contains(needle)
                    || config.author.lowercased().contains(needle)
            } else {
                textOK = true
            }
            // Optional tag filter.
            let tagOK = tag.map { config.tags.contains($0) } ?? true
            return textOK && tagOK
        }

        if matches.isEmpty {
            print("no matching configs")
            return
        }

        // Align the "author/slug" column so versions / badges / tags line up.
        let refs = matches.map { "\($0.author)/\($0.slug)" }
        let column = max((refs.map(\.count).max() ?? 0) + 2, 24)
        for config in matches {
            let ref = "\(config.author)/\(config.slug)"
            let padded = ref.count < column
                ? ref + String(repeating: " ", count: column - ref.count)
                : ref + " "
            let badge = config.verified ? "[verified]" : "          "
            let tags = config.tags.isEmpty ? "" : config.tags.joined(separator: ", ")
            // version padded to a small fixed width for tidy columns.
            let version = config.latestVersion
            let versionPadded = version.count < 10
                ? version + String(repeating: " ", count: 10 - version.count)
                : version + " "
            print("\(padded)\(versionPadded) \(badge)  \(tags)".trimmingTrailingSpaces())
        }
    }
}

/// Trim trailing spaces from a line so rows with no tags don't carry padding.
private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
