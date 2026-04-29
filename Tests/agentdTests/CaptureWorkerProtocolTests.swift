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

  func testStreamLineReaderDecodesChunkedPayloads() throws {
    let frame = CapturedFrame(
      timestamp: Date(timeIntervalSince1970: 456),
      cgImage: try Self.image(),
      displayId: 99,
      displayScale: 1,
      mainDisplay: false
    )
    let payload = try CaptureWorkerFrameCodec.payload(for: frame)
    let data = try CaptureWorkerFrameCodec.encodePayload(payload)
    let split = data.index(data.startIndex, offsetBy: data.count / 2)
    let recorder = PayloadRecorder()
    let reader = CaptureWorkerStreamLineReader { payload in
      recorder.append(payload)
    } onDecodeError: { error in
      recorder.fail(error)
    }

    reader.append(data[..<split])
    XCTAssertEqual(recorder.payloads().count, 0)
    reader.append(data[split...])

    let payloads = recorder.payloads()
    XCTAssertEqual(payloads.count, 1)
    XCTAssertEqual(payloads.first?.displayId, 99)
    XCTAssertEqual(recorder.errors(), [])
  }

  func testStreamLineReaderReportsMalformedLines() {
    let recorder = PayloadRecorder()
    let reader = CaptureWorkerStreamLineReader { payload in
      recorder.append(payload)
    } onDecodeError: { error in
      recorder.fail(error)
    }

    reader.append(Data("not-json\n".utf8))

    XCTAssertEqual(recorder.payloads().count, 0)
    XCTAssertEqual(recorder.errors().count, 1)
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

private final class PayloadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var seenPayloads: [CaptureWorkerFramePayload] = []
  private var seenErrors: [String] = []

  func append(_ payload: CaptureWorkerFramePayload) {
    lock.lock()
    seenPayloads.append(payload)
    lock.unlock()
  }

  func fail(_ error: String) {
    lock.lock()
    seenErrors.append(error)
    lock.unlock()
  }

  func payloads() -> [CaptureWorkerFramePayload] {
    lock.lock()
    defer { lock.unlock() }
    return seenPayloads
  }

  func errors() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return seenErrors
  }
}
