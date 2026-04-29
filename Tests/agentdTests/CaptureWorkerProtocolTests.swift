// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation
import XCTest

@testable import agentd

final class CaptureWorkerProtocolTests: XCTestCase {
  func testFramePayloadRoundTripsThroughJpegJson() throws {
    let frame = CapturedFrame(
      timestamp: Date(timeIntervalSince1970: 123),
      cgImage: try Self.image(),
      displayId: 42,
      displayScale: 2,
      mainDisplay: true
    )

    let payload = try CaptureWorkerFrameCodec.payload(for: frame)
    let data = try CaptureWorkerFrameCodec.encodePayload(payload)
    let decodedPayload = try CaptureWorkerFrameCodec.decodePayload(data)
    let decodedFrame = try CaptureWorkerFrameCodec.frame(from: decodedPayload)

    XCTAssertEqual(decodedFrame.timestamp, frame.timestamp)
    XCTAssertEqual(decodedFrame.displayId, 42)
    XCTAssertEqual(decodedFrame.displayScale, 2)
    XCTAssertEqual(decodedFrame.mainDisplay, true)
    XCTAssertEqual(decodedFrame.cgImage.width, frame.cgImage.width)
    XCTAssertEqual(decodedFrame.cgImage.height, frame.cgImage.height)
  }

  func testCaptureWorkerClientSurfacesNonZeroExit() async {
    do {
      _ = try await CaptureWorkerClient.captureOneFrame(
        executable: URL(fileURLWithPath: "/usr/bin/false"),
        displayId: nil,
        timeoutSeconds: 0.5
      )
      XCTFail("expected worker failure")
    } catch let error as DiagnosticCLIError {
      XCTAssertTrue(error.localizedDescription.contains("exited with status"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private static func image() throws -> CGImage {
    let width = 4
    let height = 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw CaptureWorkerProtocolError.imageEncodeFailed
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw CaptureWorkerProtocolError.imageEncodeFailed
    }
    return image
  }
}
