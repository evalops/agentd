// SPDX-License-Identifier: BUSL-1.1

import Accelerate
import CoreGraphics
import CoreImage
import Foundation

/// 64-bit perceptual hash via 8x8 mean-luma comparison (the cheap-and-correct one).
/// Hamming distance ≤ 5 = "near-duplicate frame, drop it" — typical kills 90% of
/// captured frames during steady scrolling or no-op time.
struct PerceptualHash: Sendable {
  let value: UInt64

  init(value: UInt64) {
    self.value = value
  }

  init?(cgImage: CGImage) {
    guard let small = PerceptualHash.downscale(cgImage, to: 8) else { return nil }
    guard let lumas = PerceptualHash.lumaSamples(small) else { return nil }
    let mean = lumas.reduce(0, +) / Double(lumas.count)
    var bits: UInt64 = 0
    for (i, l) in lumas.enumerated() {
      if l > mean { bits |= (1 << UInt64(i)) }
    }
    self.value = bits
  }

  static func distance(_ a: PerceptualHash, _ b: PerceptualHash) -> Int {
    (a.value ^ b.value).nonzeroBitCount
  }

  private static func downscale(_ image: CGImage, to size: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceGray()
    guard
      let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size, space: cs,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
  }

  private static func lumaSamples(_ image: CGImage) -> [Double]? {
    guard let data = image.dataProvider?.data,
      let ptr = CFDataGetBytePtr(data)
    else { return nil }
    let count = image.width * image.height
    return (0..<count).map { Double(ptr[$0]) / 255.0 }
  }
}
