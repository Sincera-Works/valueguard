import Foundation
import CoreVideo

/// Sample-based difference hash for fast change detection.
///
/// NOT a strong perceptual hash — sufficient for "did this window's content
/// meaningfully change since last frame." Point-samples a 9×8 grid from the
/// pixel buffer, compares each cell to its right neighbor, and packs the
/// 64 comparison bits into a UInt64.
///
/// Cost: ~72 reads + a few dozen ops per call — effectively free. Compare to
/// SigLIP-2 inference at ~15 ms; the gate pays off any time more than a few
/// percent of frames are static.
public func differenceHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
    let pixels = base.assumingMemoryBound(to: UInt8.self)

    @inline(__always)
    func gray(_ gx: Int, _ gy: Int) -> Int {
        // Map the 9×8 hash grid back to pixel coordinates.
        let px = min((gx * width) / 9, width - 1)
        let py = min((gy * height) / 8, height - 1)
        let off = py * stride + px * 4
        // BGRA byte order: bytes 0=B, 1=G, 2=R, 3=A.
        let b = Int(pixels[off + 0])
        let g = Int(pixels[off + 1])
        let r = Int(pixels[off + 2])
        return (b + g + r) / 3
    }

    var hash: UInt64 = 0
    for y in 0..<8 {
        for x in 0..<8 {
            if gray(x, y) > gray(x + 1, y) {
                hash |= UInt64(1) << (y * 8 + x)
            }
        }
    }
    return hash
}

/// Hamming distance between two difference-hash values. 0 = identical;
/// 64 = inverse. The reference Python spec treats `< 4` as "unchanged."
@inline(__always)
public func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
    return (a ^ b).nonzeroBitCount
}
