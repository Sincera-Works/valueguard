import XCTest
@testable import ValueGuardMarketplace

/// Unit tests for `InstallLayout.assertSafeComponents` — the defense-in-depth
/// path-traversal guard over the `author` / `slug` / `version` values that become
/// directory names under `configs/`.
///
/// `ManifestValidator` already constrains these via strict regexes and `Installer`
/// only builds paths from a verified manifest, so a traversal component cannot
/// reach the layout through the normal path. This guard is the last line of
/// defence; these tests pin its behavior directly so a validator regression can't
/// silently re-open the hole.
final class InstallLayoutGuardTests: XCTestCase {

    /// Well-formed components (matching the validator's accepted shapes) pass.
    func testAcceptsWellFormedComponents() {
        XCTAssertNoThrow(
            try InstallLayout.assertSafeComponents(
                author: "acme", slug: "strict-personal", version: "1.4.0"))
        XCTAssertNoThrow(
            try InstallLayout.assertSafeComponents(
                author: "a1", slug: "desk-mode", version: "2.0.0-rc.1"))
    }

    /// Every traversal / separator / empty shape is rejected, on whichever field
    /// carries it, as `VGError.bundleLayout`.
    func testRejectsTraversalAndSeparators() {
        let bad: [(author: String, slug: String, version: String)] = [
            ("..", "slug", "1.0.0"),
            (".", "slug", "1.0.0"),
            ("author", "..", "1.0.0"),
            ("author", "a/b", "1.0.0"),
            ("../../Library/Preferences", "slug", "1.0.0"),
            ("author", "slug", "../evil"),
            ("author", "slug", "1.0.0/.."),
            ("", "slug", "1.0.0"),
            ("author", "", "1.0.0"),
            ("author", "slug", ""),
            ("/abs", "slug", "1.0.0"),
        ]
        for c in bad {
            XCTAssertThrowsError(
                try InstallLayout.assertSafeComponents(author: c.author, slug: c.slug, version: c.version),
                "expected rejection for \(c)"
            ) { error in
                guard case VGError.bundleLayout = error else {
                    XCTFail("expected VGError.bundleLayout for \(c), got \(error)")
                    return
                }
            }
        }
    }
}
