// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureWorkerFramePayload: Codable, Sendable, Equatable {
  let timestamp: Date
  let displayId: UInt32
  let displayScale: Double?
  let mainDisplay: Bool
  let jpegBase64: String
}

enum CaptureWorkerProtocolError: Error, LocalizedError, Equatable {
  case imageEncodeFailed
  case imageDecodeFailed

  var errorDescription: String? {
    switch self {
    case .imageEncodeFailed:
      return "capture worker could not encode frame image"
    case .imageDecodeFailed:
      return "capture worker could not decode frame image"
    }
  }
}

enum CaptureWorkerFrameCodec {
  static func payload(for frame: CapturedFrame) throws -> CaptureWorkerFramePayload {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw CaptureWorkerProtocolError.imageEncodeFailed
    }
    CGImageDestinationAddImage(destination, frame.cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CaptureWorkerProtocolError.imageEncodeFailed
    }
    return CaptureWorkerFramePayload(
      timestamp: frame.timestamp,
      displayId: frame.displayId,
      displayScale: frame.displayScale,
      mainDisplay: frame.mainDisplay,
      jpegBase64: (data as Data).base64EncodedString()
    )
  }

  static func frame(from payload: CaptureWorkerFramePayload) throws -> CapturedFrame {
    guard
      let data = Data(base64Encoded: payload.jpegBase64),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw CaptureWorkerProtocolError.imageDecodeFailed
    }
    return CapturedFrame(
      timestamp: payload.timestamp,
      cgImage: image,
      displayId: payload.displayId,
      displayScale: payload.displayScale,
      mainDisplay: payload.mainDisplay
    )
  }

  static func encodePayload(_ payload: CaptureWorkerFramePayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(payload) + Data([0x0A])
  }

  static func decodePayload(_ data: Data) throws -> CaptureWorkerFramePayload {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CaptureWorkerFramePayload.self, from: data)
  }
}
