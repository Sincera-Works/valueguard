import Foundation

/// A parsed SemVer 2.0 version, just enough to *order* versions for the registry
/// index (newest-first) and to pick the highest **non-prerelease** as
/// `latest_version`.
///
/// This is deliberately minimal: the §2 manifest schema is what *validates* a
/// version string (`ManifestValidator`); this type only needs to compare two
/// already-valid versions and tell whether a version is a prerelease. Build
/// metadata (`+...`) is ignored for ordering, per SemVer §10.
///
/// Precedence follows SemVer §11:
/// - major, then minor, then patch compared numerically;
/// - a version *with* a prerelease has lower precedence than the same
///   major.minor.patch *without* one;
/// - prerelease identifiers are compared left-to-right, numeric identifiers
///   ordering below alphanumeric ones and numeric compared as integers.
public struct SemVer: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The dot-separated prerelease identifiers (empty for a release version).
    public let prerelease: [String]
    /// The original string (used as the final tie-break and for round-tripping).
    public let raw: String

    /// `true` iff this version carries a prerelease tag (e.g. `1.0.0-rc.1`).
    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// Parse a SemVer string. Returns `nil` if the `major.minor.patch` core is
    /// not three dot-separated non-negative integers. Build metadata after `+`
    /// is accepted and discarded.
    public init?(_ string: String) {
        self.raw = string

        // Split off build metadata (ignored for precedence).
        let noBuild = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]

        // Split off the prerelease tag.
        let coreAndPre = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = coreAndPre[0]
        let pre = coreAndPre.count > 1 ? String(coreAndPre[1]) : ""

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre.isEmpty ? [] : pre.split(separator: ".").map(String.init)
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // SemVer §11: a release (no prerelease) outranks any prerelease of the
        // same core version.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false          // equal cores, both releases
        case (true, false): return false         // lhs release > rhs prerelease
        case (false, true): return true          // lhs prerelease < rhs release
        case (false, false): break               // compare identifiers below
        }

        // Compare prerelease identifiers left to right.
        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let a = lhs.prerelease[i]
            let b = rhs.prerelease[i]
            let an = Int(a)
            let bn = Int(b)
            switch (an, bn) {
            case let (a?, b?):
                if a != b { return a < b }       // both numeric: compare ints
            case (_?, nil):
                return true                       // numeric < alphanumeric
            case (nil, _?):
                return false                      // alphanumeric > numeric
            case (nil, nil):
                if a != b { return a < b }        // both strings: ASCII compare
            }
        }
        // All shared identifiers equal: the one with fewer identifiers is lower.
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }
}
