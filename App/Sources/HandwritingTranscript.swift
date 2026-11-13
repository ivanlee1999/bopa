import CryptoKit
import ImageIO
import NotableKit
import PencilKit
import UIKit
import Vision

struct HandwritingTranscript: Codable, Equatable {
    var fingerprint: String
    var text: String

    static func fingerprint(_ strokes: [StrokeDTO]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(strokes)) ?? Data()
        let configuration = Data(("vision3:" + Locale.preferredLanguages.joined(separator: ",")).utf8)
        return SHA256.hash(data: data + configuration).map { String(format: "%02x", $0) }.joined()
    }
}

/// Vision owns its request on a serial executor. Only encoded images and text cross actors.
actor HandwritingTextReader {
    static let shared = HandwritingTextReader()

    func recognize(_ image: Data) throws -> String {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        var preferred: [String] = []
        for language in Locale.preferredLanguages {
            let match =
            supported.first { $0 == language } ?? supported.first { $0.hasPrefix(String(language.prefix(2))) }
            if let match, !preferred.contains(match) { preferred.append(match) }
        }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            return a.minY == b.minY ? a.minX < b.minX : a.minY > b.minY
        }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

@MainActor
enum HandwritingImage {
    static func png(_ drawing: PKDrawing) -> Data? {
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard !drawing.strokes.isEmpty, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, 1600 / bounds.width, sqrt(8_000_000 / (bounds.width * bounds.height)))
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let ink = drawing.image(from: bounds, scale: scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}

/// A disposable local projection, outside synced notebooks. Recognition never writes a page.
@MainActor
final class HandwritingTranscriptIndex: ObservableObject {
    typealias Recognizer = @Sendable (Data) async throws -> String
    @Published private(set) var records: [String: HandwritingTranscript] = [:]
    private struct Pending { var token: UUID; var task: Task<Void, Never> }
    private var pending: [String: Pending] = [:]
    private var activeDrawing: [UUID: String] = [:]
    private struct Request { var notebookID: String; var pageID: String; var store: NotebookStore; var delay: Duration }
    private var requested: [String: Request] = [:]
    private let recognize: Recognizer

    init(recognize: @escaping Recognizer = { try await HandwritingTextReader.shared.recognize($0) }) {
        self.recognize = recognize
    }

    static func key(_ notebookID: String, _ pageID: String) -> String { "\(notebookID)/\(pageID)" }

    func setDrawing(_ drawing: Bool, owner: UUID, notebookID: String, pageID: String?, store: NotebookStore? = nil) {
        store?.setAutomaticTagDrawing(drawing, owner: owner)
        guard drawing, let pageID else {
            guard activeDrawing.removeValue(forKey: owner) != nil, activeDrawing.isEmpty else { return }
            for request in Array(requested.values) { self.request(notebookID: request.notebookID, pageID: request.pageID, store: request.store, delay: request.delay) }
            return
        }
        let key = Self.key(notebookID, pageID)
        activeDrawing[owner] = key
        for job in pending.values { job.task.cancel() }
        pending.removeAll()
    }

    func text(notebookID: String, pageID: String, fingerprint: String) -> String? {
        guard let value = records[Self.key(notebookID, pageID)], value.fingerprint == fingerprint else { return nil }
        return value.text.isEmpty ? nil : value.text
    }

    @discardableResult
    func request(notebookID: String, pageID: String, store: NotebookStore, delay: Duration = .milliseconds(1200)) -> Task<Void, Never> {
        let key = Self.key(notebookID, pageID), token = UUID()
        requested[key] = Request(notebookID: notebookID, pageID: pageID, store: store, delay: delay)
        pending[key]?.task.cancel()
        guard activeDrawing.isEmpty else { pending[key] = nil; return Task {} }
        let task = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            defer { if self.pending[key]?.token == token { self.pending[key] = nil; self.requested[key] = nil } }
            guard !Task.isCancelled, self.activeDrawing.isEmpty,
                  let page = try? store.loadPage(notebookId: notebookID, pageId: pageID),
                  store.manifest(id: notebookID)?.pageIds.contains(pageID) == true else { return }
            let fingerprint = HandwritingTranscript.fingerprint(page.strokes)
            guard !page.strokes.isEmpty else {
                self.records[key] = HandwritingTranscript(fingerprint: fingerprint, text: ""); return
            }
            let url = store.rootURL.appendingPathComponent(".bopa-recognition/\(notebookID)/\(pageID).json")
            if let record = self.records[key], record.fingerprint == fingerprint {
                store.applyAutomaticTopics(notebookID: notebookID, pageID: pageID, recognizedText: record.text, inkFingerprint: fingerprint)
                return
            }
            if let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(HandwritingTranscript.self, from: data), cached.fingerprint == fingerprint {
                self.records[key] = cached
                store.applyAutomaticTopics(notebookID: notebookID, pageID: pageID, recognizedText: cached.text, inkFingerprint: fingerprint)
                return
            }
            let image = HandwritingImage.png(PencilKitBridge.drawing(from: page.strokes))
            do {
                let text: String
                if let image { text = try await self.recognize(image) } else { text = "" }
                guard !Task.isCancelled, self.pending[key]?.token == token,
                      store.manifest(id: notebookID)?.pageIds.contains(pageID) == true,
                      let latest = try? store.loadPage(notebookId: notebookID, pageId: pageID),
                      HandwritingTranscript.fingerprint(latest.strokes) == fingerprint else { return }
                let record = HandwritingTranscript(fingerprint: fingerprint, text: text)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: url, options: .atomic)
                self.records[key] = record
                store.applyAutomaticTopics(notebookID: notebookID, pageID: pageID, recognizedText: text, inkFingerprint: fingerprint)
            } catch { /* Ink stays visible; the next request can retry this disposable cache. */ }
        }
        pending[key] = Pending(token: token, task: task)
        return task
    }
}
