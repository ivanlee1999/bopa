import NotableKit
import PencilKit
import UIKit
import Vision

/// The recognizer this engine wraps, as recorded in `pagetext` documents.
let visionEngine = "vision"

/// What one page's handwriting came out as.
struct RecognizedPageText: Sendable, Equatable {
    var text: String
    var engine: String
    var language: String?
}

/// Reading a page's handwriting. A protocol so the controller can be tested without Vision, whose
/// output legitimately varies between OS versions and would make every assertion a guess.
protocol TextRecognizing: Sendable {
    func recognize(_ page: PageFile) async throws -> RecognizedPageText
}

/// Reads a page's handwriting with Vision, entirely on the device.
///
/// Vision reads images, not strokes, so the ink is rendered first — and rendered *alone*, on
/// white. The template underneath it is the reason: ruled and dotted paper is precisely the input
/// that degrades handwriting recognition, and none of it is the user's writing. Placed images are
/// left out for the same reason, plus one more — a photograph of a page of printed text would
/// otherwise be read as if the user had written it.
struct VisionPageTextRecognizer: TextRecognizing {

    func recognize(_ page: PageFile) async throws -> RecognizedPageText {
        let drawing = PencilKitBridge.drawing(from: page.strokes)
        guard !drawing.strokes.isEmpty else {
            return RecognizedPageText(text: "", engine: visionEngine, language: nil)
        }

        let size = CGSize(width: CGFloat(page.pageSize.width), height: CGFloat(page.pageSize.height))
        guard let image = await render(drawing: drawing, size: size) else {
            throw RecognitionError.couldNotRender
        }
        return try read(image)
    }

    /// The ink as a bitmap Vision can read.
    ///
    /// The scale trades legibility against memory. Vision wants an x-height of a few dozen pixels,
    /// and handwriting on an A4-shaped page runs about 40 units tall, so 2x-3x puts it comfortably
    /// clear of the floor; the 4000-pixel cap is what stops a very tall continuous-scroll page
    /// from asking for a bitmap the size of the app's whole memory budget.
    @MainActor
    private func render(drawing: PKDrawing, size: CGSize) async -> CGImage? {
        let longest = max(size.width, size.height)
        let scale = min(3.0, longest > 0 ? 4000 / longest : 1)
        let pageRect = CGRect(origin: .zero, size: size)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(pageRect)
            drawing.image(from: pageRect, scale: scale).draw(in: pageRect)
        }
        return image.cgImage
    }

    private func read(_ image: CGImage) throws -> RecognizedPageText {
        let request = VNRecognizeTextRequest()
        // `.fast` cannot read handwriting at all — it is a printed-text path. This is not a
        // speed/quality trade so much as the difference between working and not.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []

        // Vision reports in confidence order, and its coordinates are normalized with the origin
        // at the bottom left — so reading order is *descending* midY, then ascending minX. Lines
        // within a hair of each other are treated as one row, or a word whose box sits a pixel
        // higher than its neighbour's jumps a line.
        let sorted = observations.sorted { left, right in
            let dy = right.boundingBox.midY - left.boundingBox.midY
            if abs(dy) > sameLineTolerance { return dy < 0 }
            return left.boundingBox.minX < right.boundingBox.minX
        }

        var lines: [String] = []
        var currentLine: [String] = []
        var currentY: CGFloat?

        for observation in sorted {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let y = observation.boundingBox.midY
            if let previous = currentY, abs(previous - y) > sameLineTolerance {
                lines.append(currentLine.joined(separator: " "))
                currentLine = []
            }
            currentLine.append(candidate.string)
            currentY = y
        }
        if !currentLine.isEmpty { lines.append(currentLine.joined(separator: " ")) }

        return RecognizedPageText(
            text: lines.joined(separator: "\n"),
            engine: visionEngine,
            language: Locale.preferredLanguages.first)
    }

    /// How far apart two boxes' centres may be and still count as the same line, in normalized
    /// page height — about one line of handwriting on a page of twenty.
    private let sameLineTolerance: CGFloat = 0.01

    enum RecognitionError: Error {
        case couldNotRender
    }
}
