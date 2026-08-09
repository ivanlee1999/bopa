import CoreGraphics
import Foundation
import ImageIO

enum PDFSupport {
    static func document(at url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw TemplateError.invalidPDF(url)
        }
        return document
    }

    /// `CGPDFDocument` pages are 1-based; templates and the `pdf<N>` wire key are 0-based.
    static func page(_ document: CGPDFDocument, at index: Int) throws -> CGPDFPage {
        guard index >= 0, index < document.numberOfPages, let page = document.page(at: index + 1) else {
            throw TemplateError.pageOutOfRange(index: index, pageCount: document.numberOfPages)
        }
        return page
    }

    /// The page's crop box, falling back to its media box.
    static func box(of page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        return crop.isEmpty ? page.getBoxRect(.mediaBox) : crop
    }

    /// `/Rotate` normalized to 0, 90, 180 or 270 degrees clockwise.
    static func rotation(of page: CGPDFPage) -> Int {
        let degrees = Int(page.rotationAngle) % 360
        let normalized = degrees < 0 ? degrees + 360 : degrees
        return (normalized / 90) * 90
    }

    /// Visible page size in points, honouring `/Rotate`.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = box(of: page)
        return rotation(of: page) % 180 == 90
            ? CGSize(width: box.height, height: box.width)
            : box.size
    }
}

enum ImageSupport {
    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }
}
