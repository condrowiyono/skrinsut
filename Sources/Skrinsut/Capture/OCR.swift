import AppKit
import Vision

/// Text and QR/barcode recognition via Vision ("Instant Text/QR Recognition").
enum OCR {
    struct Result {
        var text: String
        var isBarcode: Bool
    }

    static func recognize(_ image: CGImage, completion: @escaping (Result?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let barcodes = VNDetectBarcodesRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            try? handler.perform([barcodes, text])

            let result: Result?
            if let payload = barcodes.results?.compactMap(\.payloadStringValue).first, !payload.isEmpty {
                result = Result(text: payload, isBarcode: true)
            } else {
                let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: Settings.ocrRemoveBreaks ? " " : "\n")
                result = joined.isEmpty ? nil : Result(text: joined, isBarcode: false)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
