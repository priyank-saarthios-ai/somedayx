// somedayx-ocr: read the text in images with Apple Vision, on this Mac.
//
//   somedayx-ocr a.jpg b.png …   prints one JSON line per image: {"path": …, "text": …}
//
// Used by the indexer so text in screenshots and memes is searchable.

import Foundation
import Vision

for path in CommandLine.arguments.dropFirst() {
    var lines: [String] = []
    let request = VNRecognizeTextRequest { request, _ in
        lines = (request.results as? [VNRecognizedTextObservation] ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    try? VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
    let json = try! JSONSerialization.data(withJSONObject: ["path": path, "text": lines.joined(separator: "\n")])
    FileHandle.standardOutput.write(json + Data("\n".utf8))
}
