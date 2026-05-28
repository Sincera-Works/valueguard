import Foundation
import CoreGraphics
import CoreImage
import CoreVideo

/// Resize a CGImage to 256×256 and wrap it in a CVPixelBuffer suitable
/// for SigLIP-2's vision encoder. Renders via a CIContext that never
/// touches a display surface — pixels live in shared memory only long
/// enough for the ANE to read them.
enum PixelBufferBuilder {
    enum BuildError: LocalizedError {
        case bufferAllocFailed
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .bufferAllocFailed: return "Failed to allocate CVPixelBuffer."
            case .renderFailed: return "Failed to render image into pixel buffer."
            }
        }
    }

    private static let context: CIContext = {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .useSoftwareRenderer: false,
        ]
        return CIContext(options: opts)
    }()

    static func make(from cgImage: CGImage, size: Int = 256) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw BuildError.bufferAllocFailed
        }

        // Render the CGImage into the pixel buffer, doing a center-crop so we
        // don't distort. SigLIP-2 was trained on center-cropped 256×256.
        let ci = CIImage(cgImage: cgImage)
        let imageSize = ci.extent.size
        let scale = max(CGFloat(size) / imageSize.width, CGFloat(size) / imageSize.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tx = (scaled.extent.width - CGFloat(size)) / 2
        let ty = (scaled.extent.height - CGFloat(size)) / 2
        let cropped = scaled.transformed(by: CGAffineTransform(translationX: -tx, y: -ty))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        context.render(cropped, to: buffer)
        return buffer
    }
}
