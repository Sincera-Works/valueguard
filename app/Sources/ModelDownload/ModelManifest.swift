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
    static let textEncoderURL = URL(string: "https://github.com/Sincera-Works/valueguard/releases/download/v0.1.0-models/SigLIP2Text.mlpackage.tar.gz")!

    /// SHA256 of the tarball — verified after download, before extraction.
    static let textEncoderSHA256 = "6f199574785a91071d266a1305276f54e5b99e5005a6cb2fea621ed447194e41"

    /// Approximate compressed size, for UI progress bars when Content-Length is absent.
    static let textEncoderBytes: Int64 = 506_000_000
}
