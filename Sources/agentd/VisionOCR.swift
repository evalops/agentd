// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation
import Vision

struct OCRTextRegion: Sendable, Equatable {
  let normalizedBoundingBox: CGRect
}

struct OCRResult: Sendable {
  let text: String
  let confidence: Float
  let language: String?
  let regions: [OCRTextRegion]

  init(
    text: String,
    confidence: Float,
    language: String?,
    regions: [OCRTextRegion] = []
  ) {
    self.text = text
    self.confidence = confidence
    self.language = language
    self.regions = regions
  }
}

actor VisionOCR: OCRRecognizing {
  func recognize(cgImage: CGImage) async throws -> OCRResult {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
      let request = VNRecognizeTextRequest { req, err in
        if let err {
          cont.resume(throwing: err)
          return
        }
        let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
        var lines: [String] = []
        var regions: [OCRTextRegion] = []
        var confSum: Float = 0
        var confN: Int = 0
        for obs in observations {
          guard let candidate = obs.topCandidates(1).first else { continue }
          lines.append(candidate.string)
          regions.append(OCRTextRegion(normalizedBoundingBox: obs.boundingBox))
          confSum += candidate.confidence
          confN += 1
        }
        let conf = confN > 0 ? confSum / Float(confN) : 0
        let detectedLang = observations.first
          .flatMap { $0.topCandidates(1).first }
          .map { _ in "en" }  // language detection requires Sequence APIs; fine for v0
        cont.resume(
          returning: OCRResult(
            text: lines.joined(separator: "\n"),
            confidence: conf,
            language: detectedLang,
            regions: regions
          ))
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.revision = VNRecognizeTextRequestRevision3
      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do {
        try handler.perform([request])
      } catch {
        cont.resume(throwing: error)
      }
    }
  }
}
