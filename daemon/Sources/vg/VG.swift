import Foundation
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
            Verify.self,
            Install.self,
            List.self,
            Activate.self,
            Uninstall.self,
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
        let url = RefParser.resolveSource(path)

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

/// `vg install <file://path | path>` — verify, then unpack into the local
/// install layout (§5).
///
/// Accepts a bare filesystem path or a `file://` URL. Network sources are out of
/// scope in P0. On success prints the §4-style install lines (where the bundle
/// landed and how to activate it). Verification failure, immutability violation
/// (same version already installed), or a TOFU key change refuse the install and
/// exit non-zero.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Verify and install a .vgconfig bundle into the local layout."
    )

    @Argument(help: "Path or file:// URL to the .vgconfig bundle.")
    var source: String

    func run() throws {
        let url = RefParser.resolveSource(source)

        let layout: InstallLayout
        let installer: Installer
        let coords: (author: String, slug: String, version: String)
        do {
            layout = try InstallLayout()
            installer = Installer(layout: layout)
            coords = try installer.install(bundleAt: url)
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
