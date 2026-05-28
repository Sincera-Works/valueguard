import Foundation
import ImageIO
import CoreGraphics

/// Fetches image URLs from Wikimedia Commons.
///
/// Wikimedia Commons is the right source for headless calibration because:
/// - No API key required.
/// - Public domain content — no copyright/usage friction.
/// - Heavily moderated, so we will never hit anything illegal (CSAM etc.).
/// - Has the diversity needed for sensitive categories (anatomical
///   photography, war photography, medical imagery) without the unmoderated
///   sketchiness of a general web image search.
///
/// We use the OpenSearch + ImageInfo API. Two-step:
///   1) Query the search API with `srnamespace=6` (file namespace) for image titles.
///   2) Resolve each title to a real image URL via imageinfo prop.
enum WikimediaImageFetcher {
    enum FetchError: LocalizedError {
        case badResponse(Int)
        case malformedJSON

        var errorDescription: String? {
            switch self {
            case .badResponse(let c): return "Wikimedia returned HTTP \(c)."
            case .malformedJSON: return "Wikimedia response was not the expected shape."
            }
        }
    }

    /// Search Wikimedia Commons for images matching `query`. Returns up to
    /// `limit` JPEG/PNG URLs, smaller variants where available to keep
    /// download cost bounded.
    static func searchImages(query: String, limit: Int = 5) async throws -> [URL] {
        let base = "https://commons.wikimedia.org/w/api.php"
        var components = URLComponents(string: base)!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"),
            .init(name: "gsrsearch", value: "\(query) filetype:bitmap"),
            .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrlimit", value: "\(limit)"),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|mime"),
            .init(name: "iiurlwidth", value: "512"),
        ]
        var request = URLRequest(url: components.url!)
        // Wikimedia asks for a descriptive UA.
        request.setValue("ValueGuard/0.1 (on-device content filter; calibration)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.badResponse(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else {
            return [] // Empty result is valid (no matches).
        }

        var urls: [URL] = []
        for (_, page) in pages {
            guard let page = page as? [String: Any],
                  let info = page["imageinfo"] as? [[String: Any]],
                  let first = info.first else { continue }
            // Prefer the thumbnail (iiurlwidth=512) over the full-resolution original.
            let candidate = (first["thumburl"] as? String) ?? (first["url"] as? String)
            guard let urlString = candidate,
                  let url = URL(string: urlString),
                  let mime = first["mime"] as? String,
                  mime.hasPrefix("image/") else { continue }
            // Skip SVGs — CIImage handles raster only and SVG would need NSImage roundtrip.
            if mime == "image/svg+xml" { continue }
            urls.append(url)
        }
        return urls
    }

    /// Download an image and decode straight to in-memory CGImage. We
    /// deliberately do NOT cache to disk: the bytes live in RAM only long
    /// enough to convert to a pixel buffer for the vision encoder.
    static func downloadImage(_ url: URL) async throws -> CGImage? {
        var request = URLRequest(url: url)
        request.setValue("ValueGuard/0.1 (on-device content filter; calibration)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
