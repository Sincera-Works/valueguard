import Foundation

/// Baked-in manifest of the model artifacts the app needs to download.
/// The URL and SHA256 are the canonical contract — change them when you cut
/// a new model release, and the downloader will refuse to install anything
/// whose contents don't hash to the expected value.
///
/// The expected on-disk shape after download + extraction is a single
/// `SigLIP2Text.mlpackage` directory inside `AppSupport.modelsURL`.
enum ModelManifest {
    /// HTTPS URL of a gzip-compressed tarball containing `SigLIP2Text.mlpackage/`.
    /// TODO(B5): replace with the real GitHub release URL once the asset is published.
    static let textEncoderURL = URL(string: "https://github.com/PLACEHOLDER/valueguard/releases/download/v0.1.0-models/SigLIP2Text.mlpackage.tar.gz")!

    /// SHA256 of the tarball — verified after download, before extraction.
    /// TODO(B5): paste the actual `shasum -a 256 SigLIP2Text.mlpackage.tar.gz` output here.
    static let textEncoderSHA256 = "PLACEHOLDER_SHA256_64_HEX_CHARS_PLACEHOLDER_SHA256_64_HEX_CHARS_X"

    /// Approximate compressed size, for UI progress bars when Content-Length is absent.
    static let textEncoderBytes: Int64 = 560_000_000
}
