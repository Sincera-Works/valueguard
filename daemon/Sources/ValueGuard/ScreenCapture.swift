import Foundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

public actor ScreenCapture {
    private var stream: SCStream?
    private var continuation: AsyncStream<CVPixelBuffer>.Continuation?

    public init() {}

    public func requestPermission() async throws {
        do {
            _ = try await SCShareableContent.current
        } catch {
            FileHandle.standardError.write(Data(
                "valueguard: Screen Recording permission required. Grant in System Settings → Privacy & Security → Screen Recording, then re-run.\n".utf8
            ))
            throw error
        }
    }

    /// Capture a single frame from the main display.
    /// This is the simplest possible implementation — for production we want
    /// a persistent SCStream feeding a frame buffer the daemon polls. Good
    /// enough for the v1 scaffold.
    public func captureFrame() async throws -> CVPixelBuffer? {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 256
        config.height = 256
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 2

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return Self.pixelBuffer(from: image)
    }

    private static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
